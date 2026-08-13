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

### Phase 2: Data & Key Platform

```bash
terraform apply -target=module.hsm
terraform apply -target=module.sql
terraform apply -target=module.storage
```

**Exit Criteria:**
- [ ] All keys are HSM-held (no software keys)
- [ ] Data plane is 100% private (private endpoints only)
- [ ] SQL failover group is healthy

### Phase 3: Application Platform

```bash
terraform apply -target=module.app_service
terraform apply -target=module.front_door
```

**Exit Criteria:**
- [ ] Front Door is the only public entry
- [ ] App reaches data only via private endpoints
- [ ] WAF and IDPS confirmed in path

### Phase 4: Validation & Go-live

1. Run Defender for Cloud PCI DSS v4 compliance assessment
2. Execute DR failover test
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
| Firewall | `fw-<org>-<env>-<region>` | `fw-p24-prod-neu` |
| Key Vault | `kv-<org>-<env>-<region>` | `kv-p24-prod-neu` |
| SQL Server | `sql-<org>-<env>-<region>` | `sql-p24-prod-neu` |
| App Service | `app-<org>-<workload>-<env>-<region>` | `app-p24-cde-prod-neu` |

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
