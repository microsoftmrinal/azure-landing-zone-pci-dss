# Architecture

## Overview

This Azure Landing Zone implements a **PCI DSS v4.0 compliant Cardholder Data Environment (CDE)** using the Azure Landing Zone conceptual architecture, tailored for a single-tenant payment processing workload.

## Design Principles

1. **Single public entry** — Front Door Premium + WAF is the only internet-facing surface
2. **Zero public IPs in CDE** — Enforced by Azure Policy `deny` effect
3. **All egress through Firewall** — UDR 0.0.0.0/0 → Azure Firewall on every spoke subnet
4. **Private data plane** — All data services accessed via private endpoints only
5. **HSM-held keys** — Managed HSM (FIPS 140-2 L3) for TDE CMK and application keys
6. **Least privilege** — PIM just-in-time, phishing-resistant MFA, no standing owners
7. **Active DR** — Front Door routing + SQL auto-failover group across NEU ↔ WEU
8. **Defence-in-depth** — Five concentric layers (Edge → Network → Identity → App → Data)

## Management Group Hierarchy

```
Tenant Root Group
└── P24-Root (Intermediate Root)
    ├── Platform
    │   ├── Connectivity
    │   ├── Management
    │   └── Identity
    ├── Landing Zones
    │   ├── CDE-Prod        ← PCI DSS v4 policy initiative assigned here
    │   └── Corp
    ├── Sandbox
    └── Decommissioned
```

## Network Topology

### Address Plan

| Network | CIDR | Region |
|---------|------|--------|
| Hub Primary | 10.1.0.0/16 | North Europe |
| Hub DR | 10.2.0.0/16 | West Europe |
| CDE Spoke Primary | 10.10.0.0/16 | North Europe |
| CDE Spoke DR | 10.20.0.0/16 | West Europe |

### Traffic Flow

```
Internet → Front Door (WAF/OWASP) → Private Link → App Service (VNet-integrated)
                                                         │
                                                    UDR → Firewall (IDPS)
                                                         │
                                                    Private Endpoint → SQL/Storage/HSM
```

### Routing

- All spoke subnets have UDR: `0.0.0.0/0 → Firewall private IP`
- BGP route propagation **disabled** on spoke route tables to prevent learned-route bypass
- BGP propagation **enabled** on GatewaySubnet for on-premises connectivity
- Hub-to-hub peering for cross-region traffic (also inspected by firewall)

## Security Layers

| Layer | Controls |
|-------|----------|
| **Edge** | Front Door Premium, WAF (OWASP DRS 2.1 + Bot Manager), DDoS Protection |
| **Network** | Azure Firewall Premium (IDPS Deny + TLS inspection), NSGs, Private Endpoints |
| **Identity** | Entra ID, PIM, Conditional Access (phishing-resistant MFA), no legacy auth |
| **Application** | App Service (VNet-integrated, no public access), managed identity |
| **Data** | SQL TDE + CMK, Managed HSM, immutable audit storage, private endpoints |

## Compliance Model

Two engines maintain continuous compliance:

1. **Azure Policy** — Prevents non-compliance (deny public IPs, require encryption, enforce tags)
2. **Microsoft Defender for Cloud** — Proves compliance (PCI DSS v4 regulatory dashboard, recommendations)

These form a continuous loop: Defender consumes Policy definitions, so every recommendation maps to a policy assessment.

## Disaster Recovery

| Component | Strategy | RTO | RPO |
|-----------|----------|-----|-----|
| Front Door | Active-active (global) | 0 min | 0 |
| App Service | Active-passive (NEU→WEU) | < 5 min | 0 |
| Azure SQL | Auto-failover group | < 60 min | < 5 sec |
| Firewall | Per-region (mirrored) | 0 | N/A |
| Key Vault/HSM | Geo-replicated | Automatic | Near-zero |

## Well-Architected Framework Alignment

### Reliability
- Zone-redundant Firewall, App Service Plan, SQL Business Critical
- Multi-region active-passive with automatic failover
- DDoS Network Protection on public VNets

### Security
- Zero-trust: verify explicitly, least privilege, assume breach
- All 12 PCI DSS v4 requirements mapped to Azure controls
- FIPS 140-2 Level 3 key management

### Cost Optimization
- Right-sized SKUs (P2v3 App Service, BC_Gen5_4 SQL)
- Reserved capacity recommended for predictable workloads
- Lifecycle management on audit storage (cool → archive)

### Operational Excellence
- 100% IaC (Terraform); no portal changes
- CI/CD with workload-identity federation (no secrets)
- Sentinel analytics for automated incident detection

### Performance Efficiency
- Front Door caching and global load balancing
- Zone-redundant compute and storage
- Business Critical SQL for local read replicas
