# Azure Landing Zone for PCI-DSS v4.0

Production-ready Azure Landing Zone implementing a **PCI DSS v4.0 compliant Cardholder Data Environment (CDE)** using hub-spoke topology with defence-in-depth controls.

## Architecture Overview

```mermaid
graph TB
    Internet((Internet))

    subgraph Edge["Edge Layer"]
        FD[Azure Front Door Premium<br/>+ WAF OWASP 2.1]
        DDoS[DDoS Network Protection]
    end

    subgraph NEU["North Europe — Primary"]
        subgraph HubNEU["Hub VNet • 10.1.0.0/16"]
            FW1[Azure Firewall Premium<br/>IDPS + TLS Inspection]
            VPN1[VPN Gateway<br/>BGP / IPSec]
            Bastion1[Azure Bastion]
            DNS1[Private DNS Zones]
        end
        subgraph SpokeNEU["CDE Spoke • 10.10.0.0/16"]
            App1[App Service P2v3<br/>VNet-integrated]
            VM1[VMs - Trusted Launch<br/>JIT Access]
            SQL1[(SQL Business Critical<br/>TDE + CMK)]
            KV1[Key Vault]
            HSM1[Managed HSM<br/>FIPS 140-2 L3]
            ST1[Storage WORM<br/>Immutable Audit]
        end
    end

    subgraph WEU["West Europe — DR"]
        subgraph HubWEU["Hub VNet • 10.2.0.0/16"]
            FW2[Azure Firewall Premium<br/>IDPS + TLS Inspection]
            VPN2[VPN Gateway<br/>BGP / IPSec]
        end
        subgraph SpokeWEU["CDE Spoke • 10.20.0.0/16"]
            App2[App Service P2v3<br/>Standby]
            SQL2[(SQL Failover<br/>Read-Only)]
            ST2[Storage GRS<br/>Geo-Replicated]
        end
    end

    subgraph Security["Security & Monitoring"]
        Sentinel[Microsoft Sentinel<br/>+ Log Analytics 365d]
        Defender[Defender for Cloud<br/>All Plans]
        Policy[Azure Policy<br/>PCI DSS v4 Initiative]
    end

    Internet -->|HTTPS| FD
    FD -->|Private Link| App1
    FD -.->|Failover| App2
    App1 -->|UDR → FW| FW1
    FW1 -->|Private Endpoint| SQL1
    FW1 -->|Private Endpoint| KV1
    FW1 -->|Private Endpoint| ST1
    SQL1 <-->|Auto-Failover<br/>RPO < 5s| SQL2
    ST1 <-.->|GRS Replication| ST2
    HubNEU <-->|Hub Peering| HubWEU
    VPN1 -->|IPSec| OnPrem((On-Premises))
    Sentinel -.->|Monitors| FW1
    Sentinel -.->|Monitors| FW2
    Defender -.->|Assesses| SpokeNEU
    Policy -.->|Enforces| SpokeNEU
    Policy -.->|Enforces| SpokeWEU
```

## Management Group Hierarchy

```mermaid
graph TD
    TRG[Tenant Root Group]
    TRG --> Root["P24-Root<br/><i>Security baseline policies</i>"]

    Root --> Platform[Platform]
    Root --> LZ[Landing Zones]
    Root --> Sandbox[Sandbox]
    Root --> Decom[Decommissioned]

    Platform --> Conn[Connectivity<br/><i>Hub, Firewall, VPN</i>]
    Platform --> Mgmt[Management<br/><i>Sentinel, Defender</i>]
    Platform --> Ident[Identity<br/><i>PIM, CA Policies</i>]

    LZ --> CDE["CDE-Prod 🔴<br/><i>PCI DSS v4 assigned</i>"]
    LZ --> Corp[Corp<br/><i>Non-CDE workloads</i>]

    style CDE fill:#fee2e2,stroke:#ef4444,stroke-width:3px
    style Root fill:#dbeafe,stroke:#3b82f6,stroke-width:2px
    style Platform fill:#e0e7ff,stroke:#6366f1
    style LZ fill:#dcfce7,stroke:#22c55e
```

## Traffic Flow

```mermaid
sequenceDiagram
    participant User as Internet User
    participant FD as Front Door + WAF
    participant FW as Firewall Premium
    participant App as App Service
    participant SQL as SQL (Private EP)

    User->>FD: HTTPS Request
    Note over FD: WAF OWASP inspection<br/>Bot detection<br/>Rate limiting
    FD->>App: Private Link (no public IP)
    Note over FW: IDPS inspection<br/>TLS decryption
    App->>FW: Data request (UDR 0.0.0.0/0)
    FW->>SQL: Private Endpoint
    SQL-->>FW: Encrypted response (TDE)
    FW-->>App: Inspected traffic
    App-->>FD: Response
    FD-->>User: HTTPS Response
```

## Security Layers (Defence-in-Depth)

```mermaid
graph LR
    A[Attacker] ==>|Blocked| L1

    subgraph L1["Layer 1: Edge"]
        FD2[Front Door WAF]
        DDOS2[DDoS Protection]
    end

    subgraph L2["Layer 2: Network"]
        FW3[Firewall IDPS]
        NSG[NSGs]
        PE[Private Endpoints]
    end

    subgraph L3["Layer 3: Identity"]
        MFA[Phishing-Resistant MFA]
        PIM[PIM Just-in-Time]
        CA[Conditional Access]
    end

    subgraph L4["Layer 4: Application"]
        MI[Managed Identity]
        VNET[VNet Integration]
    end

    subgraph L5["Layer 5: Data"]
        TDE[TDE + CMK]
        HSM2[Managed HSM]
        WORM[Immutable Storage]
    end

    L1 --> L2 --> L3 --> L4 --> L5

    style L1 fill:#fef2f2,stroke:#ef4444,stroke-width:2px
    style L2 fill:#fff7ed,stroke:#f59e0b,stroke-width:2px
    style L3 fill:#faf5ff,stroke:#a78bfa,stroke-width:2px
    style L4 fill:#f0fdf4,stroke:#22c55e,stroke-width:2px
    style L5 fill:#eff6ff,stroke:#3b82f6,stroke-width:2px
```

## Disaster Recovery

```mermaid
graph LR
    subgraph Primary["North Europe (Active)"]
        P_FD[Front Door ●]
        P_FW[Firewall ●]
        P_App[App Service ●]
        P_SQL[(SQL Read-Write ●)]
        P_HSM[HSM ●]
    end

    subgraph DR["West Europe (Standby)"]
        D_FD[Front Door ○]
        D_FW[Firewall ●]
        D_App[App Service ○]
        D_SQL[(SQL Read-Only ○)]
        D_KV[Key Vault ○]
    end

    P_SQL <-->|"Auto-Failover<br/>RTO < 60min | RPO < 5sec"| D_SQL
    P_FD <-.->|"Active-Active<br/>RTO: 0"| D_FD
    P_App <-.->|"Active-Passive<br/>RTO < 5min"| D_App

    style Primary fill:#f0fdf4,stroke:#22c55e,stroke-width:2px
    style DR fill:#fff7ed,stroke:#f59e0b,stroke-width:2px
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
