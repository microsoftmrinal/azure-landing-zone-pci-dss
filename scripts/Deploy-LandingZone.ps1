<#
.SYNOPSIS
    Deploys and operates the Payment24 PCI-DSS landing zone (Windows IIS VMs in North Europe and West Europe).

.DESCRIPTION
    One script for the common tasks, run in this order:

      Check             Verify PowerShell, Azure CLI sign-in, Terraform version and the tfvars file.
      Init              terraform init for the chosen environment (prod = North Europe, dr = West Europe).
      Validate          terraform fmt -check and terraform validate (no Azure calls, no state).
      Plan              terraform plan, saved to a plan file.
      Apply             terraform apply of the saved plan (asks for confirmation).
      ApproveFrontDoor  Approve the pending Front Door private endpoint connections on the
                        North Europe and West Europe Private Link Services.
      ShowClientIPs     List the firewall egress public IPs that Client A must allow-list.
      Test              Call the public Front Door endpoint and report the HTTP status.

    Secrets are never written to disk by this script. The VM admin password (and optional VPN shared key)
    is requested securely, passed to Terraform through process environment variables, and cleared afterwards.
    Do not put either value in terraform.tfvars. The plan file contains them, so the script deletes it after Apply.

    Recommended order for a first deployment:
      1. Copy environments\prod\terraform.tfvars.example to terraform.tfvars and fill it in.
      2. .\Deploy-LandingZone.ps1 -Action Check
      3. .\Deploy-LandingZone.ps1 -Action Plan   ;  .\Deploy-LandingZone.ps1 -Action Apply
      4. Repeat Plan/Apply with -Environment dr (copy environments\dr\terraform.tfvars.example first).
      5. Set deploy_front_door = true and dr_private_link_service_id in the prod tfvars, then Plan/Apply prod again.
      6. .\Deploy-LandingZone.ps1 -Action ApproveFrontDoor
      7. .\Deploy-LandingZone.ps1 -Action ShowClientIPs   (send the list to Client A)
      8. .\Deploy-LandingZone.ps1 -Action Test

.PARAMETER Action
    The task to run. Default: Check.

.PARAMETER Environment
    prod (North Europe, hub/spoke, Front Door) or dr (West Europe warm standby). Default: prod.

.PARAMETER VarFile
    Path to a tfvars file. Default: environments\<Environment>\terraform.tfvars.

.PARAMETER VmAdminPassword
    Local administrator password for the IIS VM. Prompted for securely if not supplied and not already in
    the TF_VAR_vm_admin_password environment variable. Must be 12 or more characters with 3 of 4 character classes.

.PARAMETER VpnSharedKey
    Optional pre-shared key for the site-to-site VPN tunnel. Prompted for only when -PromptForVpnKey is used.

.PARAMETER PromptForVpnKey
    Ask for the VPN pre-shared key securely.

.PARAMETER TerraformPath
    Terraform executable. Default: terraform (from PATH).

.PARAMETER UpdateLockFile
    With Init, regenerate the provider lock file hashes for Windows, Linux and macOS. Use this if Init reports a
    checksum mismatch.

.PARAMETER Hostname
    Host name for the Test action. Default: the Front Door endpoint from the production stack outputs.

.PARAMETER HealthPath
    Path called by the Test action. Default: /health.

.EXAMPLE
    .\Deploy-LandingZone.ps1 -Action Check

.EXAMPLE
    .\Deploy-LandingZone.ps1 -Action Plan -Environment prod

.EXAMPLE
    .\Deploy-LandingZone.ps1 -Action Apply -Environment dr

.EXAMPLE
    .\Deploy-LandingZone.ps1 -Action ApproveFrontDoor -WhatIf

.NOTES
    Requires: PowerShell 5.1 or later, Azure CLI (az), Terraform 1.5 or later, and an Azure account with rights
    on the connectivity, management and CDE subscriptions. Run 'az login' first.
    Apply and ApproveFrontDoor change Azure resources and ask for confirmation. Use -WhatIf to preview or
    -Confirm:$false to run unattended.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Init', 'Validate', 'Plan', 'Apply', 'ApproveFrontDoor', 'ShowClientIPs', 'Test')]
    [string]$Action = 'Check',

    [ValidateSet('prod', 'dr')]
    [string]$Environment = 'prod',

    [string]$VarFile,

    [System.Security.SecureString]$VmAdminPassword,

    [System.Security.SecureString]$VpnSharedKey,

    [switch]$PromptForVpnKey,

    [string]$TerraformPath = 'terraform',

    [switch]$UpdateLockFile,

    [string]$Hostname,

    [string]$HealthPath = '/health'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:EnvRoot = Join-Path $script:RepoRoot 'environments'
$script:EnvDir = Join-Path $script:EnvRoot $Environment
$script:PlanFile = 'landing-zone.tfplan'

# ---------- helpers ----------

function Write-Step { param([string]$Message) Write-Host "`n== $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

function Test-Command { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Invoke-Terraform {
    # Runs terraform in a directory; throws on a non-zero exit code.
    param(
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string[]]$Arguments
    )
    Push-Location $WorkingDirectory
    try {
        & $TerraformPath @Arguments
        if ($LASTEXITCODE -ne 0) { throw "terraform $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
    }
    finally { Pop-Location }
}

function Get-TerraformOutput {
    # Returns a string output, or $null if the stack has no state or the output is null.
    param([string]$Directory, [string]$Name)
    if (-not (Test-Path $Directory)) { return $null }
    Push-Location $Directory
    try {
        $value = & $TerraformPath output -raw $Name 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { return $null }
        return ([string]$value).Trim()
    }
    catch { return $null }
    finally { Pop-Location }
}

function ConvertTo-PlainText {
    param([System.Security.SecureString]$Secure)
    [System.Net.NetworkCredential]::new('', $Secure).Password
}

function Test-VmPasswordComplexity {
    param([string]$Password)
    if ($Password.Length -lt 12 -or $Password.Length -gt 123) { return $false }
    $classes = 0
    if ($Password -cmatch '[a-z]') { $classes++ }
    if ($Password -cmatch '[A-Z]') { $classes++ }
    if ($Password -match '\d') { $classes++ }
    if ($Password -match '[^a-zA-Z0-9]') { $classes++ }
    return ($classes -ge 3)
}

function Get-VarFilePath {
    if ($VarFile) { $path = $VarFile } else { $path = Join-Path $script:EnvDir 'terraform.tfvars' }
    if (-not (Test-Path $path)) {
        $example = Join-Path $script:EnvDir 'terraform.tfvars.example'
        throw "tfvars file not found: $path. Copy '$example' to 'terraform.tfvars' and fill it in."
    }
    return (Resolve-Path $path).Path
}

function Get-TfVarValue {
    # Reads a simple string value (name = "value") from a tfvars file; returns $null if absent or commented out.
    param([string]$Path, [string]$Name)
    $match = Select-String -Path $Path -Pattern ('^\s*' + [regex]::Escape($Name) + '\s*=\s*"([^"]+)"') | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return $null
}

function Set-SecretEnvironment {
    # Passes secrets to Terraform via process environment variables only (never written to disk).
    $set = @()
    $existing = [Environment]::GetEnvironmentVariable('TF_VAR_vm_admin_password', 'Process')
    if (-not $VmAdminPassword -and [string]::IsNullOrEmpty($existing)) {
        $VmAdminPassword = Read-Host -Prompt 'IIS VM local administrator password (Enter to skip if no VM is deployed)' -AsSecureString
    }
    if ($VmAdminPassword) {
        $plain = ConvertTo-PlainText $VmAdminPassword
        if (-not [string]::IsNullOrEmpty($plain)) {
            if (-not (Test-VmPasswordComplexity $plain)) {
                throw 'The VM password must be 12-123 characters and use at least 3 of: lowercase, uppercase, digit, symbol.'
            }
            [Environment]::SetEnvironmentVariable('TF_VAR_vm_admin_password', $plain, 'Process')
            $set += 'TF_VAR_vm_admin_password'
        }
    }
    if ($PromptForVpnKey -or $VpnSharedKey) {
        if (-not $VpnSharedKey) { $VpnSharedKey = Read-Host -Prompt 'VPN pre-shared key' -AsSecureString }
        $plainKey = ConvertTo-PlainText $VpnSharedKey
        if (-not [string]::IsNullOrEmpty($plainKey)) {
            [Environment]::SetEnvironmentVariable('TF_VAR_vpn_shared_key', $plainKey, 'Process')
            $set += 'TF_VAR_vpn_shared_key'
        }
    }
    return , $set
}

function Clear-SecretEnvironment {
    param([string[]]$Names)
    foreach ($n in $Names) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
}

function Get-PendingConnections {
    param([string]$PlsId)
    $json = az network private-endpoint-connection list --id $PlsId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return @() }
    return @(($json | ConvertFrom-Json) | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -eq 'Pending'
        })
}

# ---------- actions ----------

function Invoke-Check {
    Write-Step 'Prerequisite check'
    $failed = 0

    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    if (Test-Command 'az') {
        Write-Ok 'Azure CLI found'
        $account = az account show -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $account) {
            $a = $account | ConvertFrom-Json
            Write-Ok "Signed in: $($a.user.name) / subscription '$($a.name)'"
        }
        else { Write-Bad "Not signed in. Run 'az login'."; $failed++ }
    }
    else { Write-Bad 'Azure CLI (az) not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli'; $failed++ }

    if (Test-Command $TerraformPath) {
        try {
            $version = [version](((& $TerraformPath version -json) | ConvertFrom-Json).terraform_version -replace '-.*$', '')
            if ($version -ge [version]'1.5.0') { Write-Ok "Terraform $version" }
            else { Write-Bad "Terraform $version found; 1.5.0 or later is required."; $failed++ }
        }
        catch { Write-Warn "Terraform found but its version could not be read: $($_.Exception.Message)" }
    }
    else { Write-Bad "Terraform not found ('$TerraformPath'). Install from https://developer.hashicorp.com/terraform/install"; $failed++ }

    if (Test-Path $script:EnvDir) { Write-Ok "Environment folder: $script:EnvDir" }
    else { Write-Bad "Environment folder not found: $script:EnvDir"; $failed++ }

    try {
        $path = Get-VarFilePath
        Write-Ok "tfvars file: $path"
        if (Select-String -Path $path -Pattern '00000000-0000-0000-0000-000000000000' -Quiet) {
            Write-Warn 'tfvars still contains the placeholder GUID 00000000-0000-0000-0000-000000000000.'
        }
        if (Select-String -Path $path -Pattern '^\s*(vm_admin_password|vpn_shared_key)\s*=' -Quiet) {
            Write-Warn 'tfvars sets a secret value. Remove it: secrets are supplied at run time and a value here overrides them.'
        }
    }
    catch { Write-Bad $_.Exception.Message; $failed++ }

    if ($failed -gt 0) { throw "$failed prerequisite check(s) failed." }
    Write-Host "`nAll prerequisite checks passed." -ForegroundColor Green
}

function Invoke-Init {
    Write-Step "terraform init ($Environment)"
    if ($UpdateLockFile) {
        Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @(
            'providers', 'lock', '-platform=windows_amd64', '-platform=linux_amd64', '-platform=darwin_amd64', '-platform=darwin_arm64')
    }
    Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @('init', '-input=false', '-reconfigure')
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check (whole repository)'
    Invoke-Terraform -WorkingDirectory $script:RepoRoot -Arguments @('fmt', '-check', '-recursive')
    Write-Ok 'Formatting is clean'

    Write-Step "terraform validate ($Environment)"
    Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @('init', '-backend=false', '-input=false', '-reconfigure')
    Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @('validate')
    Write-Ok 'Configuration is valid'
    Write-Warn "Validate used '-backend=false'. Run -Action Init before Plan to reconnect to the remote state."
}

function Invoke-Plan {
    $varFilePath = Get-VarFilePath
    Write-Step "terraform plan ($Environment)"
    $secretNames = Set-SecretEnvironment
    try {
        Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @('init', '-input=false', '-reconfigure')
        Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @(
            'plan', '-input=false', "-var-file=$varFilePath", "-out=$script:PlanFile")
        Write-Ok "Plan saved to $(Join-Path $script:EnvDir $script:PlanFile)"
        Write-Warn 'The plan file contains secret values. It is deleted after Apply. Do not share or commit it.'
    }
    finally { Clear-SecretEnvironment $secretNames }
}

function Invoke-Apply {
    $planPath = Join-Path $script:EnvDir $script:PlanFile
    if (-not (Test-Path $planPath)) { throw "No saved plan found. Run -Action Plan -Environment $Environment first." }
    Write-Step "terraform apply ($Environment)"
    Write-Warn 'The VPN gateway can take 30 to 45 minutes to provision on the first apply.'
    if ($PSCmdlet.ShouldProcess("environment '$Environment'", 'terraform apply of the saved plan')) {
        try {
            Invoke-Terraform -WorkingDirectory $script:EnvDir -Arguments @('apply', '-input=false', $script:PlanFile)
        }
        finally {
            Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        }
        Write-Host "`nApply complete. Next steps:" -ForegroundColor Green
        if ($Environment -eq 'prod') {
            Write-Host '  1. Apply the dr environment, then set deploy_front_door = true and dr_private_link_service_id in the prod tfvars.'
        }
        else {
            Write-Host '  1. Pass the private_link_service_id output to the prod stack as dr_private_link_service_id.'
        }
        Write-Host '  2. Run -Action ApproveFrontDoor, then -Action ShowClientIPs and send the list to Client A.'
        Write-Host '  3. Deploy the IIS site, the HTTPS binding on port 8082 and the certificate for the application FQDN.'
    }
    elseif ($WhatIfPreference) {
        Write-Warn 'WhatIf: nothing was applied and the saved plan was left in place.'
    }
    else {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue -Confirm:$false
        Write-Warn 'Apply skipped; the saved plan was deleted because it contains secret values.'
    }
}

function Invoke-ApproveFrontDoor {
    Write-Step 'Approve Front Door private endpoint connections'
    if (-not (Test-Command 'az')) { throw 'Azure CLI (az) is required.' }
    $stacks = @(
        @{ Name = 'North Europe (prod)'; Dir = Join-Path $script:EnvRoot 'prod' },
        @{ Name = 'West Europe (dr)'; Dir = Join-Path $script:EnvRoot 'dr' }
    )
    $found = 0
    foreach ($stack in $stacks) {
        $plsId = Get-TerraformOutput -Directory $stack.Dir -Name 'private_link_service_id'
        if (-not $plsId) { Write-Warn "$($stack.Name): no private_link_service_id output (stack not applied, or VM not deployed)."; continue }
        $found++
        $pending = Get-PendingConnections -PlsId $plsId
        if ($pending.Count -eq 0) { Write-Ok "$($stack.Name): no pending connections"; continue }
        foreach ($connection in $pending) {
            if ($PSCmdlet.ShouldProcess($connection.name, "Approve Front Door connection on $($stack.Name)")) {
                az network private-endpoint-connection approve --id $connection.id --description 'Approved: Azure Front Door origin' -o none
                if ($LASTEXITCODE -ne 0) { throw "Approval failed for $($connection.name)." }
                Write-Ok "$($stack.Name): approved $($connection.name)"
            }
        }
    }
    if ($found -eq 0) { throw 'No Private Link Service outputs found. Apply the prod and dr stacks first.' }
    Write-Host "`nAllow a few minutes for Front Door to show the origins as healthy." -ForegroundColor Green
}

function Invoke-ShowClientIPs {
    Write-Step 'Firewall egress IPs for Client A to allow-list'
    $rows = @()
    foreach ($e in @('prod', 'dr')) {
        $dir = Join-Path $script:EnvRoot $e
        $region = if ($e -eq 'prod') { 'North Europe' } else { 'West Europe' }
        $ip = Get-TerraformOutput -Directory $dir -Name 'firewall_public_ip'
        if ($ip) { $rows += [pscustomobject]@{ Region = $region; Address = $ip; Source = 'Azure Firewall primary public IP' } }
        $tfvars = Join-Path $dir 'terraform.tfvars'
        if ((Test-Path $tfvars) -and (Test-Command 'az')) {
            $extraId = Get-TfVarValue -Path $tfvars -Name 'client_a_egress_public_ip_id'
            if ($extraId) {
                $extraIp = az network public-ip show --ids $extraId --query ipAddress -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and $extraIp) {
                    $rows += [pscustomobject]@{ Region = $region; Address = $extraIp.Trim(); Source = 'Reserved IP added to the firewall (client_a_egress_public_ip_id)' }
                }
            }
        }
    }
    if ($rows.Count -eq 0) { throw 'No firewall IPs found. Apply the prod (and dr) stacks first.' }
    $rows | Format-Table -AutoSize
    Write-Warn 'Azure Firewall chooses among its public IPs, so Client A must allow-list EVERY address above (both regions).'
    Write-Warn 'This does not pin Client A traffic to the reserved IP. A single fixed source IP needs a separately approved NAT Gateway design.'
}

function Invoke-Test {
    Write-Step 'Public endpoint test'
    $target = $Hostname
    if (-not $target) { $target = Get-TerraformOutput -Directory (Join-Path $script:EnvRoot 'prod') -Name 'front_door_endpoint' }
    if (-not $target) { throw 'No host name. Pass -Hostname, or deploy Front Door (deploy_front_door = true) in the prod stack.' }
    $uri = "https://$target$HealthPath"
    Write-Host "  GET $uri"
    try {
        [void][System.Net.Dns]::GetHostAddresses($target)
        Write-Ok "DNS resolves for $target"
    }
    catch { Write-Bad "DNS lookup failed for ${target}: $($_.Exception.Message)"; throw }
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30
        Write-Ok "HTTP $($response.StatusCode) from $target"
        if ($response.Headers['X-Azure-Ref']) { Write-Host "  X-Azure-Ref: $($response.Headers['X-Azure-Ref'])" }
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status) {
            Write-Bad "HTTP $status from $target"
            if ($status -in 502, 503, 504) {
                Write-Host '  Likely causes: the Front Door private endpoint connection is not approved yet, IIS is not serving /health on 8082, or the certificate name does not match the FQDN.'
            }
        }
        else { Write-Bad "Request failed: $($_.Exception.Message)" }
        throw 'Endpoint test failed.'
    }
}

# ---------- main ----------

try {
    switch ($Action) {
        'Check' { Invoke-Check }
        'Init' { Invoke-Init }
        'Validate' { Invoke-Validate }
        'Plan' { Invoke-Plan }
        'Apply' { Invoke-Apply }
        'ApproveFrontDoor' { Invoke-ApproveFrontDoor }
        'ShowClientIPs' { Invoke-ShowClientIPs }
        'Test' { Invoke-Test }
    }
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
