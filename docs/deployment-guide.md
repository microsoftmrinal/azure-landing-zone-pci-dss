# Deployment Guide

## Prerequisites

### Azure Tenant
- A new or dedicated Azure tenant for the PCI CDE
- Global Administrator access (for initial management group creation)
- At least 3 subscriptions:
  - **Connectivity** - Hub networking, Firewall, Bastion, VPN
  - **Management** - Log Analytics, Sentinel, Defender
  - **CDE** - Cardholder Data Environment workload

### Tooling
- [Terraform >= 1.5](https://www.terraform.io/downloads)
- [Azure CLI >= 2.50](https://docs.microsoft.com/cli/azure/install-azure-cli)
- [GitHub CLI](https://cli.github.com/) (for repository operations)

### Identity
- Workload Identity Federation (OIDC) configured for GitHub Actions
- Service principal with the following roles:
  - Management Group Contributor (at tenant root)
  - Owner on each subscription (for initial deployment; reduce post-deploy)

## Deployment Order

### Guided deployment with the PowerShell script

[`scripts/Deploy-LandingZone.ps1`](../scripts/Deploy-LandingZone.ps1) wraps the steps below. It checks prerequisites, validates, plans and applies, approves the Front Door private endpoint connections, lists the firewall egress IPs Client A must allow-list, and tests the public endpoint. Secrets (the VM administrator password and optional VPN key) are requested securely and passed to Terraform through process environment variables only.

```powershell
az login
.\scripts\Deploy-LandingZone.ps1 -Action Check
.\scripts\Deploy-LandingZone.ps1 -Action Plan  -Environment prod
.\scripts\Deploy-LandingZone.ps1 -Action Apply -Environment prod
.\scripts\Deploy-LandingZone.ps1 -Action Plan  -Environment dr
.\scripts\Deploy-LandingZone.ps1 -Action Apply -Environment dr
.\scripts\Deploy-LandingZone.ps1 -Action ApproveFrontDoor
.\scripts\Deploy-LandingZone.ps1 -Action ShowClientIPs
.\scripts\Deploy-LandingZone.ps1 -Action Test
```

Use `-WhatIf` to preview Apply and ApproveFrontDoor, and `Get-Help .\scripts\Deploy-LandingZone.ps1 -Full` for all options. The phase-by-phase commands follow for teams that prefer to run Terraform directly.

### Phase 0: Foundation & Governance

```bash
cd environments/prod
terraform init
terraform apply -target=module.management_groups
terraform apply -target=module.policy
terraform apply -target=module.sentinel
terraform apply -target=module.defender
```

**Exit Criteria:**
- [ ] Defender PCI DSS v4 dashboard is live
- [ ] Azure Policy denies a non-compliant test deployment
- [ ] No standing Owner access remains

### Phase 1: Connectivity & Security

```bash
terraform apply -target=module.hub_primary
terraform apply -target=module.firewall_primary
terraform apply -target=module.spoke_cde_primary
terraform apply -target=module.dns
```

**Exit Criteria:**
- [ ] No public IPs in CDE subscription
- [ ] All spoke egress routes through firewall (traceroute verification)
- [ ] Hub-to-hub routing works NEU↔WEU

### Phase 2: Key Platform (and optional data platform)

```bash
terraform apply -target=module.hsm
# Optional - only if the application needs Azure SQL / audit storage (deploy_data_platform = true):
terraform apply -target=module.sql
terraform apply -target=module.storage
```

**Exit Criteria:**
- [ ] All keys are HSM-held (no software keys)
- [ ] Key plane is 100% private (private endpoints only)
- [ ] Managed HSM activated and security domain stored securely
- [ ] SQL failover group is healthy (only if the data platform is deployed)

### Phase 3: Application Platform (IIS VMs + Front Door)

Inputs (see `environments/prod/terraform.tfvars.example`):

- `vm_admin_password`: retrieve from Key Vault in the pipeline; never commit.
- `app_port` (default `8082`) and `app_origin_hostname`: the FQDN on the IIS certificate. The certificate must cover both regions.
- `client_b_inbound_prefixes`: Client B source ranges allowed to reach IIS over the VPN.
- `client_a_destination_prefixes` / `client_a_destination_ports`: the Client A server the custom app connects out to.
- `client_a_egress_public_ip_id` (optional): the reserved `pip-clientA-nat-egress`, added to the firewall as an additional public IP.

```bash
# 1. North Europe: IIS VM, internal load balancer, Private Link Service
terraform apply -target=module.compute_cde

# 2. West Europe (separate stack): hub, VPN, firewall, spoke, key platform, IIS VM + PLS
cd ../dr && terraform init && terraform apply
# note the private_link_service_id output

# 3. North Europe: Front Door with both private origins (set deploy_front_door = true
#    and dr_private_link_service_id in terraform.tfvars)
cd ../prod && terraform apply -target=module.front_door
```

After apply:

1. Approve the pending Front Door private endpoint connection on each Private Link Service (Private Link Center > Private link services > Private endpoint connections).
2. Deploy the IIS site, the HTTPS binding on port 8082 and the certificate, and a readiness endpoint (default `/health`) that reflects dependency health.
3. Ask Client A to allow-list **all** firewall egress public IPs (`firewall_public_ip` output in each stack, plus the reserved IP if attached). Azure Firewall does not pin a destination to one of its public IPs; a deterministic single source IP needs a separately approved NAT Gateway design.
4. Confirm the VPN tunnels and BGP/static routes for both regional gateways with the partner.

**Exit Criteria:**
- [ ] Front Door is the only public web entry; direct access to the VMs/origins fails
- [ ] Front Door private endpoint connections approved in both regions
- [ ] Client B reaches IIS on 8082 over VPN through the firewall, with symmetric return traffic
- [ ] Client A connection succeeds from each region from an allow-listed source IP
- [ ] WAF and firewall logs confirmed in Sentinel

### Phase 4: Validation & Go-live

1. Run Defender for Cloud PCI DSS v4 compliance assessment
2. Execute failover tests (see Acceptance tests in [architecture.md](architecture.md)): public origin, VPN, private DNS selection, worker promotion, state/key recovery
3. Complete penetration test
4. Assemble QSA evidence pack

## CI/CD Setup

### 1. Configure Workload Identity Federation

```bash
# Create app registration
az ad app create --display-name "sp-terraform-landing-zone"

# Create federated credential for GitHub Actions
az ad app federated-credential create \
  --id <app-object-id> \
  --parameters '{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:microsoftmrinal/azure-landing-zone-pci-dss:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 2. Set GitHub Secrets

| Secret | Description |
|--------|-------------|
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Default subscription ID |
| `AZURE_CLIENT_ID` | App registration client ID |

### 3. Create Terraform State Storage

```bash
az group create -n rg-tfstate-prod-neu -l northeurope
az storage account create \
  -n sttfstateprodneu001 \
  -g rg-tfstate-prod-neu \
  -l northeurope \
  --sku Standard_GRS \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage container create \
  -n tfstate \
  --account-name sttfstateprodneu001
```

## Naming Convention

```
<type>-<workload>-<env>-<region>-<instance>
```

| Component | Pattern | Example |
|-----------|---------|---------|
| Resource Group | `rg-<workload>-<env>-<region>` | `rg-cde-prod-neu` |
| Virtual Network | `vnet-<workload>-<env>-<region>` | `vnet-hub-prod-neu` |
| Firewall | `fw-<org>-<env>-<region>` | `fw-org-prod-neu` |
| Key Vault | `kv-<org>-<env>-<region>` | `kv-org-prod-neu` |
| SQL Server | `sql-<org>-<env>-<region>` | `sql-org-prod-neu` |
| IIS VM | `vm-<org>-cde-<env>-<region>-<nnn>` | `vm-org-cde-prod-neu-001` |
| Internal load balancer | `lbi-<org>-cde-<env>-<region>` | `lbi-org-cde-prod-neu` |
| Private Link Service | `pls-<org>-cde-<env>-<region>` | `pls-org-cde-prod-neu` |

## Tagging Standard

| Tag | Required | Values |
|-----|----------|--------|
| `Environment` | Yes | Production, DR |
| `PCIScope` | Yes | CDE, Supporting, OutOfScope |
| `DataClassification` | Yes | CardholderData, Confidential, Internal |
| `ManagedBy` | Yes | Terraform |
| `Owner` | Yes | Team/individual |
| `CostCentre` | Yes | Business cost centre code |
| `Workload` | Yes | Application/service name |
