# Azure Landing Zone for PCI-DSS v4.0

Production-ready Azure Landing Zone implementing a **PCI DSS v4.0 compliant Cardholder Data Environment (CDE)** using hub-spoke topology with defence-in-depth controls.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Front Door Premium + WAF                │
│                     (Single public entry point)                  │
└──────────────────────────────┬──────────────────────────────────┘
                               │ Private Link
┌──────────────────────────────┴──────────────────────────────────┐
│  Hub VNet (North Europe)          │  Hub VNet (West Europe)      │
│  ┌─────────────────────┐         │  ┌─────────────────────┐    │
│  │ Azure Firewall      │         │  │ Azure Firewall      │    │
│  │ Premium (IDPS+TLS)  │         │  │ Premium (IDPS+TLS)  │    │
│  └─────────────────────┘         │  └─────────────────────┘    │
│  ┌─────────────────────┐         │  ┌─────────────────────┐    │
│  │ VPN Gateway (BGP)   │         │  │ VPN Gateway (BGP)   │    │
│  └─────────────────────┘         │  └─────────────────────┘    │
│  ┌─────────────────────┐         │                              │
│  │ Azure Bastion       │         │                              │
│  └─────────────────────┘         │                              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ VNet Peering (non-transitive)
┌──────────────────────────────┴──────────────────────────────────┐
│  CDE Spoke (North Europe)         │  CDE Spoke (West Europe)    │
│  ┌──────────┐ ┌──────────┐       │  ┌──────────┐ ┌─────────┐  │
│  │App Service│ │ VMs (TL) │       │  │App Service│ │ VMs(TL) │  │
│  │(VNet Int.)│ │  JIT     │       │  │(VNet Int.)│ │  JIT    │  │
│  └──────────┘ └──────────┘       │  └──────────┘ └─────────┘  │
│  ┌──────────┐ ┌──────────┐       │  ┌──────────┐              │
│  │ SQL MI   │ │ Storage  │       │  │ SQL MI   │              │
│  │(Pvt EP)  │ │(Pvt EP)  │       │  │(Pvt EP)  │              │
│  └──────────┘ └──────────┘       │  └──────────┘              │
│  ┌──────────┐ ┌──────────┐       │                             │
│  │Key Vault │ │Payment   │       │                             │
│  │(Pvt EP)  │ │HSM       │       │                             │
│  └──────────┘ └──────────┘       │                             │
└─────────────────────────────────────────────────────────────────┘
```

## Design Principles

| Principle | Implementation |
|-----------|---------------|
| Single public entry | Front Door Premium + WAF; no other internet-facing surface |
| No public IPs in CDE | Enforced by Azure Policy deny |
| All egress through Firewall | UDR 0.0.0.0/0 → Firewall on every spoke |
| Private data plane | SQL, Storage, Key Vault, HSM via private endpoints only |
| HSM-held keys | Payment HSM / Managed HSM with CMK for TDE |
| Least privilege | PIM just-in-time, phishing-resistant MFA, no standing owners |
| Active DR | Front Door + SQL auto-failover across NEU ↔ WEU |
| Defence-in-depth | Five concentric security layers |

## Well-Architected Framework Alignment

- **Reliability**: Multi-region active-passive DR, zone-redundant services, auto-failover groups
- **Security**: Zero-trust network, HSM key management, IDPS inspection, WAF, policy-driven compliance
- **Cost Optimization**: Right-sized SKUs, reserved capacity for predictable workloads
- **Operational Excellence**: IaC-only deployment, CI/CD with OIDC, Sentinel + Defender monitoring
- **Performance Efficiency**: Front Door caching, zone-redundant compute, Business Critical SQL tier

## Repository Structure

```
├── modules/
│   ├── management-groups/     # ALZ management group hierarchy
│   ├── policy/                # PCI DSS v4 policy assignments
│   ├── connectivity/
│   │   ├── hub/               # Hub VNet, subnets, peering
│   │   ├── spoke/             # CDE spoke VNet
│   │   ├── firewall/          # Azure Firewall Premium
│   │   ├── front-door/        # Front Door Premium + WAF
│   │   └── dns/               # Private DNS zones
│   ├── security/
│   │   ├── defender/          # Microsoft Defender for Cloud
│   │   ├── sentinel/          # Microsoft Sentinel workspace
│   │   └── identity/          # PIM, Conditional Access
│   ├── data-platform/
│   │   ├── sql/               # Azure SQL with TDE + CMK
│   │   ├── storage/           # Immutable audit storage
│   │   └── hsm/               # Managed HSM / Payment HSM
│   └── application-platform/
│       ├── app-service/        # VNet-integrated App Service
│       └── compute/            # Trusted Launch VMs + JIT
├── environments/
│   ├── prod/                   # North Europe primary
│   └── dr/                     # West Europe disaster recovery
├── .github/workflows/          # CI/CD pipeline
└── docs/                       # Architecture & compliance docs
```

## Prerequisites

- Terraform >= 1.5
- Azure CLI >= 2.50
- An Azure tenant with Global Administrator access (initial setup)
- GitHub Actions with Workload Identity Federation (OIDC)

## Quick Start

```bash
# Clone the repository
git clone https://github.com/microsoftmrinal/azure-landing-zone-pci-dss.git
cd azure-landing-zone-pci-dss/environments/prod

# Initialize Terraform
terraform init

# Review the plan
terraform plan -var-file="terraform.tfvars"

# Apply (requires appropriate Azure permissions)
terraform apply -var-file="terraform.tfvars"
```

## PCI DSS v4.0 Compliance

This landing zone addresses all 12 PCI DSS requirements through Azure-native controls. See [docs/pci-dss-mapping.md](docs/pci-dss-mapping.md) for the full requirement-to-control mapping.

## Deployment Phases

| Phase | Scope | Duration |
|-------|-------|----------|
| 0 | Foundation & Governance (MG, Policy, Defender, Identity) | 2 weeks |
| 1 | Connectivity & Security (Hub-spoke, Firewall, VPN, Bastion) | 2 weeks |
| 2 | Data & Key Platform (HSM, SQL, Storage, Private Endpoints) | 2 weeks |
| 3 | Application Platform (App Service, Front Door, VMs) | 2 weeks |
| 4 | Validation & Go-live (Compliance proof, DR test, QSA prep) | 2 weeks |

## License

MIT License - See [LICENSE](LICENSE) for details.
