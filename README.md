# Azure Landing Zone for PCI-DSS v4.0

Azure Landing Zone for a **PCI DSS v4.0 Cardholder Data Environment (CDE)** using hub-spoke topology with defence-in-depth controls. The workload runs on **Windows IIS VMs in North Europe and West Europe** (HTTPS on TCP 8082), published through Front Door Premium + WAF over Private Link, with VPN connectivity for partner clients.

> The repository is infrastructure as code. It has been validated statically (Terraform `validate` and tests, Bicep build) and has not been deployed to a customer subscription. Deploying it does not by itself establish PCI DSS compliance; validate scope and controls with your QSA.

### Interactive Visualizations

| Diagram | View |
|---------|------|
| **Architecture Diagram** (5 views: topology, traffic flow, management groups, security layers, DR) | [Open Embedded Diagram](https://microsoftmrinal.github.io/azure-landing-zone-pci-dss/#architecture) |
| **Landing Zone Explained Simply** (14 animated slides, kid-friendly) | [Open Embedded Explanation](https://microsoftmrinal.github.io/azure-landing-zone-pci-dss/#simple) |

## Architecture Overview

```mermaid
graph TB
    Internet((Internet clients))
    ClientB((Client B<br/>inbound over VPN))
    ClientA((Client A<br/>server))

    subgraph Edge["Edge Layer"]
        FD[Azure Front Door Premium<br/>+ WAF OWASP 2.1]
        DDoS[DDoS Network Protection]
    end

    subgraph NEU["North Europe — Primary"]
        subgraph HubNEU["Hub VNet • 10.1.0.0/16"]
            FW1[Azure Firewall Premium<br/>IDPS + TLS Inspection]
            VPN1[VPN Gateway<br/>IPSec]
            Bastion1[Azure Bastion]
            DNS1[Private DNS Zones]
        end
        subgraph SpokeNEU["CDE Spoke • 10.10.0.0/16"]
            PLS1[Private Link Service<br/>+ Internal LB :8082]
            VM1[IIS VM - Windows Server 2022<br/>Trusted Launch, no public IP]
            KV1[Key Vault]
            HSM1[Managed HSM<br/>FIPS 140-2 L3]
        end
    end

    subgraph WEU["West Europe — Warm standby"]
        subgraph HubWEU["Hub VNet • 10.2.0.0/16"]
            FW2[Azure Firewall Premium<br/>IDPS + TLS Inspection]
            VPN2[VPN Gateway<br/>IPSec]
        end
        subgraph SpokeWEU["CDE Spoke • 10.20.0.0/16"]
            PLS2[Private Link Service<br/>+ Internal LB :8082]
            VM2[IIS VM - Windows Server 2022<br/>Trusted Launch, no public IP]
            HSM2[Managed HSM / Key Vault]
        end
    end

    subgraph Security["Security & Monitoring"]
        Sentinel[Microsoft Sentinel<br/>+ Log Analytics 365d]
        Defender[Defender for Cloud<br/>All Plans]
        Policy[Azure Policy<br/>PCI DSS v4 Initiative]
    end

    Internet -->|HTTPS 443| FD
    FD -->|Private Link, priority 1| PLS1
    FD -.->|Private Link, priority 2 failover| PLS2
    PLS1 --> VM1
    PLS2 --> VM2
    ClientB -->|IPSec| VPN1
    VPN1 --> FW1
    FW1 -->|TCP 8082| VM1
    VM1 -->|Private Endpoint| HSM1
    VM1 -->|UDR → FW → NAT egress| FW1
    FW1 -->|Client A egress| ClientA
    VM2 -->|Private Endpoint| HSM2
    Sentinel -.->|Monitors| FW1
    Sentinel -.->|Monitors| FW2
    Defender -.->|Assesses| SpokeNEU
    Policy -.->|Enforces| SpokeNEU
    Policy -.->|Enforces| SpokeWEU
```

An optional data platform (Azure SQL with TDE + CMK and immutable audit storage) is available behind `deploy_data_platform` (default `false`) for deployments whose application needs it.

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

Public web traffic reaches IIS through Front Door and Private Link. It does **not** traverse the firewall; WAF inspects it at the edge. VPN and egress traffic is inspected by the regional firewall.

```mermaid
sequenceDiagram
    participant User as Internet User
    participant FD as Front Door + WAF
    participant PLS as Private Link Service + ILB
    participant IIS as IIS VM :8082
    participant B as Client B (VPN)
    participant FW as Firewall Premium
    participant A as Client A server
    participant HSM as Managed HSM (Private EP)

    User->>FD: HTTPS 443
    Note over FD: WAF OWASP inspection<br/>Bot detection<br/>TLS terminated, re-encrypted to origin
    FD->>PLS: Private Link (no public IP)
    PLS->>IIS: HTTPS 8082 (health-probed)
    IIS->>HSM: Key operations (private endpoint)
    IIS-->>FD: Response
    FD-->>User: HTTPS Response

    B->>FW: Over VPN, TCP 8082 only
    Note over FW: IDPS inspection<br/>Allow-listed prefixes
    FW->>IIS: Forward (symmetric return path)

    IIS->>FW: Custom app connects out (UDR 0.0.0.0/0)
    FW->>A: Scoped outbound rule, SNAT to firewall IP(s)
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
        PE[Private Endpoints / PLS]
    end

    subgraph L3["Layer 3: Identity"]
        MFA[Phishing-Resistant MFA]
        PIM[PIM Just-in-Time]
        CA[Conditional Access]
    end

    subgraph L4["Layer 4: Application"]
        MI[Managed Identity]
        TL[Trusted Launch IIS VM]
    end

    subgraph L5["Layer 5: Data"]
        CMK[CMK Disk Encryption]
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

Each failure type has its own mechanism; RTO/RPO targets must be agreed with the business and measured in recovery drills. See [docs/architecture.md](docs/architecture.md) for the full failover design.

```mermaid
graph LR
    subgraph Primary["North Europe (Active)"]
        P_FD[Front Door origin, priority 1]
        P_VM[IIS VM + ILB + PLS ●]
        P_VPN[VPN Gateway ●]
        P_APP[App process: holds lease ●]
        P_HSM[Managed HSM ●]
    end

    subgraph DR["West Europe (Warm standby)"]
        D_FD[Front Door origin, priority 2]
        D_VM[IIS VM + ILB + PLS ○]
        D_VPN[VPN Gateway ○]
        D_APP[App process: processing disabled ○]
        D_HSM[Managed HSM ○]
    end

    P_FD -.->|"Health-probe failover (new requests)"| D_FD
    P_VPN -.->|"Pre-established tunnels + route/DNS runbook"| D_VPN
    P_APP -.->|"Fenced lease promotion"| D_APP
    P_HSM -.->|"Key recovery design to validate"| D_HSM

    style Primary fill:#f0fdf4,stroke:#22c55e,stroke-width:2px
    style DR fill:#fff7ed,stroke:#f59e0b,stroke-width:2px
```

## Design Principles

| Principle | Implementation |
|-----------|---------------|
| Single public web entry | Front Door Premium + WAF; VMs have no public IPs. VPN gateways and firewall egress still use their own public IPs |
| No public IPs in CDE | Enforced by Azure Policy deny |
| Egress through Firewall | UDR 0.0.0.0/0 → Firewall on every spoke subnet |
| Private origins | Front Door → Private Link Service → internal load balancer → IIS on TCP 8082 |
| Private key plane | Managed HSM and Key Vault via private endpoints only |
| HSM-held keys | Managed HSM / Key Vault Premium with CMK for VM disks (and SQL TDE when enabled) |
| Least privilege | PIM just-in-time, phishing-resistant MFA, Entra sign-in to VMs, no standing owners |
| Regional recovery | Front Door priority failover; separate VPN, private DNS, state/key and worker-ownership mechanisms |
| Defence-in-depth | Five concentric security layers |

## Well-Architected Framework Alignment

- **Reliability**: Warm-standby second region, dependency-aware health probes, dual-region VPN, fenced worker promotion; targets defined and measured, not assumed
- **Security**: Zero-trust network, HSM key management, IDPS inspection, WAF, policy-driven governance
- **Cost Optimization**: Right-sized VM, firewall and VPN SKUs; standby capacity sized to recovery objectives
- **Operational Excellence**: IaC-only deployment, CI/CD with OIDC, Sentinel + Defender monitoring
- **Performance Efficiency**: Load-tested IIS on 8082, firewall SNAT and HSM latency baselines

## Repository Structure

```
├── modules/
│   ├── management-groups/     # ALZ management group hierarchy
│   ├── policy/                # PCI DSS v4 policy assignments
│   ├── connectivity/
│   │   ├── hub/               # Hub VNet, subnets, Bastion, VPN gateway
│   │   ├── spoke/             # CDE spoke VNet, NSGs, Private Link Service subnet
│   │   ├── firewall/          # Azure Firewall Premium, Client A/B rules
│   │   ├── front-door/        # Front Door Premium + WAF, private VM origins
│   │   └── dns/               # Private DNS zones
│   ├── security/
│   │   ├── defender/          # Microsoft Defender for Cloud
│   │   ├── sentinel/          # Microsoft Sentinel workspace
│   │   └── identity/          # PIM, Conditional Access
│   ├── data-platform/
│   │   ├── sql/               # Azure SQL with TDE + CMK (optional)
│   │   ├── storage/           # Immutable audit storage (optional)
│   │   └── hsm/               # Managed HSM, Key Vault, Disk Encryption Set
│   └── application-platform/
│       └── compute/           # Windows IIS VM + internal LB + Private Link Service
├── environments/
│   ├── prod/                   # North Europe primary
│   └── dr/                     # West Europe warm standby (hub, VPN, firewall, spoke, IIS VM)
├── bicep/                      # Bicep equivalent of the NEU + WEU deployment
├── .github/workflows/          # CI/CD pipeline
└── docs/                       # Architecture & compliance docs
```

## Prerequisites

- Terraform >= 1.5
- Azure CLI >= 2.50
- An Azure tenant with Global Administrator access (initial setup)
- GitHub Actions with Workload Identity Federation (OIDC)
- A certificate for the application FQDN (covering both regions) for IIS on TCP 8082

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

See [docs/deployment-guide.md](docs/deployment-guide.md) for the phased deployment order, West Europe stack, Front Door approvals and Client A/B configuration.

## PCI DSS v4.0 Compliance

This landing zone maps the 12 PCI DSS requirements to Azure-native controls. See [docs/pci-dss-mapping.md](docs/pci-dss-mapping.md) for the requirement-to-control mapping. The mapping is an input to a QSA assessment, not an attestation.

## Deployment Phases

| Phase | Scope |
|-------|-------|
| 0 | Foundation & Governance (MG, Policy, Defender, Identity) |
| 1 | Connectivity & Security (Hub-spoke, Firewall, VPN, Bastion) |
| 2 | Key Platform (HSM, Key Vault, Disk Encryption Set) and optional data platform |
| 3 | Application Platform (IIS VMs, internal LB + Private Link Service, Front Door) in both regions |
| 4 | Validation & Go-live (Compliance evidence, failover tests, QSA prep) |

## License

MIT License - See [LICENSE](LICENSE) for details.
