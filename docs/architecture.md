# Architecture

## Scope and Deployment Status

This document describes the Payment24 Cardholder Data Environment (CDE) architecture
implemented by this repository, incorporating customer requirements supplied on
27 November 2026. App Service has been removed from the repository; the workload runs
on Windows IIS VMs. The design is a recommendation and the repository is IaC that
has been validated statically (Terraform `validate`/tests, Bicep build) but not
deployed to a customer subscription. Neither establishes PCI DSS compliance.
Validate controls and scope with the customer's QSA.

Customer requirements:

- Windows VMs running IIS in North Europe (NEU) and West Europe (WEU); no App Service.
- IIS serves HTTPS on TCP 8082 with an FQDN and matching certificate.
- Some clients connect over the public internet; others use VPN connectivity.
- Client A requires connections initiated by a custom process on the VM. The
     customer has reserved `pip-clientA-nat-egress` for outbound connectivity.
- Client B initiates inbound connections over VPN.
- The application also connects to Managed HSM.
- Both regions need a working application and a tested recovery process.

**Repository status:** Terraform (`environments/prod`, `environments/dr`) and Bicep
now deploy, per region: a Windows Server 2022 IIS VM (Trusted Launch, CMK-encrypted
disk, no public IP), a Standard internal load balancer on TCP 8082 with an HTTPS
readiness probe, and a Private Link Service. Front Door Premium takes both Private Link
Services as priority-1 (NEU) and priority-2 (WEU) origins on HTTPS 8082. The firewall
module adds scoped rules for Client B (VPN to IIS) and Client A (app to Client A
server), and can attach the reserved `pip-clientA-nat-egress` as an additional
firewall public IP. VPN traffic is steered through the firewall with a GatewaySubnet
route table.

Not implemented in code (operational or customer decisions): NAT Gateway on
`AzureFirewallSubnet` (see the Client A section), private DNS failover automation,
worker lease/fencing, state and HSM recovery between regions, certificates and the
IIS site binding on 8082, and the Front Door private endpoint approvals.

## Design Decisions

1. Use Front Door Premium with WAF as the only public **web application** entry.
      VPN gateways and controlled egress still require their own public IPs.
2. Keep VM NICs and application load balancer frontends private.
3. Use a regional Standard internal Load Balancer (ILB) and Private Link Service
      (PLS) per region to expose IIS privately to Front Door.
4. Route inspected internet egress and VPN-to-workload traffic through the
      regional Azure Firewall Premium. Do not assume Private Link traffic is inspected.
5. Separate public web failover, VPN routing failover, private service selection,
      data recovery, and background worker ownership.
6. Prefer NEU-active/WEU-warm-standby initially. Enable active-active processing
      only if the application and its state support concurrent execution safely.

## Phased Rollout

The production stack is gated by feature flags in `environments/prod/variables.tf` so it
can be stood up incrementally with a plain `terraform apply` (enabling a later phase only
creates new resources).

| Flag | Default | Deploys |
|------|---------|---------|
| `deploy_vpn_gateway` | `true` | Hub VPN Gateway, spoke gateway-transit peering, GatewaySubnet route table to the firewall |
| `deploy_key_platform` | `true` | Managed HSM, Key Vault, Disk Encryption Set (VM CMK) |
| `deploy_compute_vm` | `true` | IIS VM, internal load balancer and Private Link Service in the CDE spoke |
| `deploy_data_platform` | `false` | Azure SQL + immutable audit storage (only if the application needs them) |
| `deploy_front_door` | `false` | Front Door Premium + WAF with private IIS origins (requires `deploy_compute_vm`) |

The West Europe stack is `environments/dr` (hub, VPN gateway, firewall, spoke, key
platform, IIS VM + PLS). Apply it, then pass its `private_link_service_id` output to the
production stack as `dr_private_link_service_id` to add the priority-2 Front Door origin.

**Firewall SKU:** `firewall_sku_tier` may be `Standard` for phase 1 and upgraded to
`Premium` in place. IDPS is only configured on Premium; PCI DSS CDE scope ultimately
requires Premium for IDPS and TLS inspection before go-live.

**Operational notes:**
- The VPN Gateway takes about 30-45 minutes to provision on first apply.
- Managed HSM requires a manual activation and security-domain download after creation.
- `encryption_at_host` on the VM requires the `EncryptionAtHost` feature on the CDE subscription.
- Administrators reach the VMs over RDP through the hub Azure Bastion; the compute NSG allows
  RDP only from `management_inbound_prefixes` (the hub range). SSH is not opened.
- Front Door private endpoint connections appear as *Pending* on each Private Link Service
  and must be approved before traffic flows.

## Management Group Hierarchy

```text
Tenant Root Group
└── P24-Root (Intermediate Root)
    ├── Platform
    │   ├── Connectivity
    │   ├── Management
    │   └── Identity
    ├── Landing Zones
    │   ├── CDE-Prod        <- PCI DSS v4 policy initiative assigned here
    │   └── Corp
    ├── Sandbox
    └── Decommissioned
```

## Network Topology

### Address Plan

| Network | CIDR | Region |
|---------|------|--------|
| Hub primary | 10.1.0.0/16 | North Europe |
| Hub recovery | 10.2.0.0/16 | West Europe |
| CDE spoke primary | 10.10.0.0/16 | North Europe |
| CDE spoke recovery | 10.20.0.0/16 | West Europe |

Confirm these ranges do not overlap customer or partner networks before deploying.

### Public Internet to IIS

```text
Public client: HTTPS 443 to public application FQDN
     -> Front Door Premium + WAF (global)
           -> NEU origin, priority 1: Front Door-managed private endpoint
                    -> NEU Private Link Service -> Standard ILB TCP 8082 -> IIS VM:8082
           -> WEU origin, priority 2: Front Door-managed private endpoint
                    -> WEU Private Link Service -> Standard ILB TCP 8082 -> IIS VM:8082
```

This is Microsoft's supported private-origin pattern for VM-hosted web workloads.
Front Door creates the private endpoint in its managed network; the customer
approves its connection to each regional PLS. It is **not a private endpoint on
Azure Firewall**. The baseline path above does not traverse Azure Firewall.

For this path, no inbound public firewall DNAT rule or extra firewall public IP is
needed. WAF inspects web requests at the edge; restrict IIS ingress with NSGs and
Windows Firewall to the actual regional PLS NAT source IPs and approved private
client paths. Allow required Azure Load Balancer health probes separately. PLS
source NAT means IIS does not see the original internet client as its TCP peer;
use trusted proxy headers for application logging, not unauthenticated headers
as an authorization control.

If the security requirement is that **every public request must also traverse
Firewall Premium IDPS**, the direct PLS-to-IIS pattern does not meet it. Approve a
separate inline inspection design with supported load balancing/routing and prove
both directions through packet and firewall-log tests before implementation. Do
not assume a default route supplies inspection. Front Door WAF and Firewall
Premium provide different controls.

### HTTPS, FQDNs, and Port 8082

- Public clients use `https://<public-application-fqdn>` on 443. Front Door does
     not expose a client-facing HTTPS listener on 8082.
- Configure each Front Door origin's HTTPS port as 8082 and forwarding protocol
     as HTTPS-only. Keep the ILB frontend/backend TCP ports at 8082.
- Use a regional origin hostname matching the IIS certificate SAN and SNI binding.
     Configure the origin host header for the application's IIS host binding. Retain
     certificate name validation and use a certificate chain trusted by Front Door.
- Front Door terminates client TLS and establishes a separate TLS session to IIS;
     this is not TLS passthrough. Confirm the protocol is HTTP over TLS, not arbitrary
     TCP with SSL. Validate client certificate or end-to-end TLS passthrough
     requirements separately before selecting Front Door.
- Configure a lightweight HTTPS readiness endpoint on 8082 that accepts the chosen
     probe method, validates readiness to serve, and discloses no sensitive data.
     A listening IIS port alone does not establish application readiness.
- Disable caching for payment APIs, authenticated responses, and sensitive data.
     Review timeouts, retries, and request-size limits against actual client behavior.

### Client B: Inbound over VPN

```text
Client B private network -> regional VPN Gateway
     -> regional Firewall Premium -> private ILB/IIS:8082
IIS response -> same regional Firewall -> VPN Gateway -> Client B
```

Front Door is not in this private path. Allow only agreed Client B source CIDRs,
IIS destinations, and TCP 8082; require application authentication over HTTPS.
Network rules do not provide HTTP WAF inspection of this VPN path. Assess whether
a private regional WAF/reverse proxy is required by the threat model.

Implement explicit routes for partner prefixes in both directions. A spoke
`0.0.0.0/0` route does not override more-specific BGP or peering routes. If BGP
propagation is disabled on workload route tables, add required partner-prefix
UDRs to the firewall and ensure the firewall can route them to the VPN gateway.
Use supported GatewaySubnet UDRs for spoke prefixes to steer inbound traffic
through the firewall; do not attach a blanket default route to GatewaySubnet.
Prove symmetric paths and prohibit unintended direct gateway-to-spoke bypass.
Peering alone does not provide transitive cross-region routing.

For private destinations, firewall network rules normally preserve private source
addresses rather than internet-SNAT them. Validate configured SNAT private ranges,
especially if the partner uses non-RFC1918 address space. Use VPN Gateway NAT only
where supported and necessary, such as overlapping S2S address ranges; it is not
an internet egress IP selector.

### Client A: VM-Initiated Connections

First confirm whether Client A's server is reached over the internet or over the
VPN. Reserving a public IP does not attach it to any data path.

| Client A destination | Recommended connectivity | Address Client A should allow |
|----------------------|--------------------------|-------------------------------|
| Public internet server | VM -> UDR -> Firewall -> internet SNAT -> Client A | Actual regional internet egress public IP(s) |
| Private server over S2S VPN | VM -> Firewall -> VPN Gateway -> Client A | Agreed private source prefix or explicitly designed VPN NAT mapping |

For public connectivity, create narrowly scoped outbound allow rules for the VM,
Client A's destination and required ports. For network-rule traffic, Azure Firewall
performs internet SNAT automatically; a DNAT rule is not an outbound SNAT rule.
Application rules may be appropriate for supported HTTP(S) protocols; do not use
them for an arbitrary custom TCP protocol.

**Do not promise a per-client egress IP by adding another firewall public IP.**
Azure Firewall does not offer a normal per-rule choice of its SNAT public IP;
Client A must allow the possible egress IPs. Attaching `pip-clientA-nat-egress`
as an additional firewall IP does not guarantee that Client A flows use it.

If a deterministic public egress IP is mandatory, an option is a NAT Gateway with
one compatible static public IP attached to **AzureFirewallSubnet**. Keep spoke
UDRs pointing to Firewall so inspection is preserved. Outbound internet flows
through that firewall then use the NAT Gateway IP, not just Client A flows. A NAT
Gateway is not a filtering device and does not SNAT traffic carried inside a VPN.
Do not attach it to the VM subnet expecting it to override a UDR to Firewall.

For a zone-redundant firewall, evaluate StandardV2 NAT Gateway and regional
availability/SKU compatibility. Confirm the reserved IP's region, SKU, zone
properties, current association, and compatibility before reuse. If only Client A
may share that egress identity, design a dedicated inspected egress boundary;
shared-firewall NAT Gateway is not destination-selective.

Provision a separate WEU egress address and have Client A allow both regions in
advance. A regional public IP cannot simply move from NEU to WEU during recovery.

### When Does Firewall Need Another Public IP?

| Reason | Guidance |
|--------|----------|
| Front Door private ingress to IIS | No additional firewall public IP required in the baseline PLS/ILB design |
| SNAT port exhaustion | Additional firewall IPs or NAT Gateway can increase capacity; measure utilization first |
| Distinct inbound DNAT mappings or overlapping listener ports | Additional IPs can separate mappings, but do not expose IIS directly and bypass WAF |
| Client A requires one fixed source IP | Extra firewall IP alone is insufficient; use the validated egress design above |
| WEU recovery environment | Its regional firewall/egress and VPN resources need their own addresses |

Premium features themselves do not require a separate public IP per application,
client, TLS inspection rule, or IDPS policy. VPN Gateway public IPs are separate
resources from firewall public IPs.

### Application to HSM

Use the Managed HSM private endpoint and private DNS, with public data-plane access
disabled. Authorize the VM managed identity through Managed HSM local RBAC with
only the required key operations. Verify HTTPS 443, DNS resolution, certificates,
key availability, and application retry behavior from each region.

Do not send HSM traffic through Client A's internet NAT. A private endpoint is
not automatically firewall-inspected: explicit routing and private endpoint
network-policy configuration are required if inspection is mandated. Account for
TLS inspection compatibility; do not assume certificate-pinned or mutually
authenticated connections tolerate decryption.

## Security Layers

| Layer | Controls |
|-------|----------|
| Edge | Front Door Premium, WAF (Default Rule Set 2.1 + Bot Manager) in Prevention mode |
| Network | Azure Firewall (VPN ingress and egress), NSGs, private endpoints, Private Link Service |
| Identity | Entra ID, PIM, Conditional Access, Entra sign-in to VMs (`AADLoginForWindows`) |
| Application | IIS on a Trusted Launch VM, no public IP, managed identity |
| Data | Managed HSM and Key Vault, CMK disk encryption, private endpoints, immutable audit storage |

## Compliance Model

1. **Azure Policy** prevents non-compliance (deny public IPs, require encryption, enforce tags).
2. **Microsoft Defender for Cloud** reports posture (PCI DSS v4 regulatory dashboard).

Both are inputs to a QSA assessment, not an attestation.

## Availability and Disaster Recovery

### Independent Failure Mechanisms

| Failure | Detection and recovery | Important limit |
|---------|------------------------|-----------------|
| NEU public IIS/origin unavailable | Front Door HTTPS readiness probes select healthy WEU priority-2 origin | New requests fail over; existing connections and in-flight payments are not migrated |
| NEU VPN unavailable | Preconfigured client tunnels to both regional VPN gateways; BGP preference/withdrawal or tested static-route automation | Requires customer VPN device support, correct prefixes, and WEU application reachability |
| NEU VM unavailable while NEU VPN remains healthy | Private service discovery or health-driven private DNS switches Client B to the WEU private service FQDN | VPN/BGP does not detect IIS failure; clients must re-resolve and reconnect |
| NEU background process unavailable | Application supervisor plus coordinated, fenced worker ownership promotes WEU | Front Door cannot start a background process or choose its owner |
| NEU state or HSM dependency unavailable | Restore/promote a tested state/key recovery topology before declaring WEU ready | Traffic failover alone cannot recover application data or keys |
| Region recovers | Controlled resynchronization, ownership handback, and failback approval | Avoid automatic flapping and duplicate payment execution |

### Public Web Failover

Keep both regional VMs configured and ready, with two private origins in the same
Front Door origin group. Set NEU priority 1 and WEU priority 2. Configure and test
probe intervals, sample thresholds, readiness semantics, and failback behavior.
**If all origins are unhealthy, Front Door can distribute traffic across unhealthy
origins**; health routing is not a fail-closed security boundary. Gate unsafe
processing in the application and use explicit incident controls where required.

One VM per region provides regional recovery, not intra-region VM high
availability. If the agreed SLO needs resilience to a single VM or zone failure,
run multiple IIS instances across zones behind each regional ILB, with sessions
and durable state outside individual VMs. Check licensing and HSM throughput.

### VPN and Private Application Failover

Assume S2S VPN for the flows above; confirm whether any clients actually use P2S,
which requires a separate profile/reconnection design. Regional active-active
gateway instances improve tunnel availability within a region; they do not
replace a second regional VPN gateway or cross-region route configuration.

Provide a private application FQDN for VPN callers with certificates valid in
both regions. A monitored runbook/controller can update its private DNS record
from the NEU ILB to the WEU ILB after checking application, state, and key readiness.
Use a suitable TTL and explicitly test client DNS caching, TLS validation,
connection pooling, retry/backoff, and idempotent reconnect behavior. Azure Private
DNS records do not perform health-based failover by themselves. Public Traffic
Manager probes cannot directly test an isolated private IIS endpoint.

Ensure each surviving tunnel can reach whichever region the private FQDN selects.
That may require advertising both regional service prefixes and an explicitly
inspected cross-region transit design. If NEU VPN fails but NEU IIS remains up,
WEU VPN must either reach NEU IIS over that transit or the recovery workflow must
also switch private service selection to WEU. Do not assume a tunnel change also
changes an application's destination IP.

### Background Application Processing

Install and monitor the custom application in both regions, for example as a
Windows Service with local service-recovery settings. Initially enable business
processing only in the active region. Local service restart is not regional DR.

Use a durable work queue/checkpoint store where supported, idempotency keys for
payments and Client A calls, and a cross-region-safe leader/lease mechanism with
fencing. A network partition must not allow both regional workers to execute the
same payment. Stop processing on loss of safe ownership and ensure stale workers
cannot commit side effects. If the application cannot support safe automated
ownership, use an operator-controlled, fenced promotion runbook instead.

Promotion must verify recovered state and keys, fence the former worker, grant
ownership to WEU, verify Client A connectivity and source-IP allowlisting, start
processing, then publish service readiness. Define transaction reconciliation
and retries for uncertain outcomes. Front Door failover does none of these steps.

### State, Keys, and Recovery Objectives

Inventory databases, files, IIS configuration, certificates, application secrets,
HSM key dependencies, and job checkpoints before selecting replication tools.
Do not assume Azure SQL is used because a SQL module exists in this repository.
VM recovery tooling alone does not establish application-consistent recovery.

Choose and test a supported Managed HSM multi-region replication or backup/restore
strategy, including current service/region constraints, private endpoint and DNS
behavior, key availability, identities, activation, and security-domain custody.
Do not assume independent HSM pools automatically share keys or that a private
endpoint transparently fails over. Exercise key operations from WEU during tests.

Agree business RTO/RPO for web requests, VPN connectivity, state, keys, and worker
processing separately. Measure detection, promotion, DNS/cache delay, reconnect,
backlog drain, and reconciliation in recovery drills. No zero-RTO, zero-RPO, or
automatic end-to-end failover guarantee is made by this design.

## Well-Architected Framework Alignment

| Pillar | Customer-specific design and verification |
|--------|-------------------------------------------|
| Reliability | Define SLO/RTO/RPO; warm regional standby; optional zone-spread VMs; dependency-aware probes; dual-region VPNs; fenced processing; tested failover and failback |
| Security | Front Door WAF Prevention; private VM origins; least-privilege VPN/egress rules; VM patching/Defender; managed identity; HSM RBAC; segmentation and validated PCI DSS scope |
| Cost Optimization | Size VM/ILB/Firewall/VPN/HSM standby capacity to recovery objectives; budget NAT Gateway and duplicate regional services; evaluate reservations only after baselining |
| Operational Excellence | IaC-reviewed changes; IIS/application/Front Door/firewall/VPN/HSM telemetry; certificate renewal; synthetic public and private tests; owned promotion and reconciliation runbooks |
| Performance Efficiency | Load-test IIS:8082, TLS, firewall SNAT, HSM key-operation latency, and WEU recovery capacity; avoid caching sensitive payment content |

Firewall Premium IDPS and TLS inspection require policy configuration, compatible
traffic, and tuning. They do not prove PCI DSS compliance. WAF, segmentation,
vulnerability management, access control, evidence retention, and operational
procedures must be assessed together; Azure Policy and Defender findings are
inputs to that assessment, not a compliance attestation.

## Implementation and Acceptance Gates

Before changing infrastructure, confirm Client A's public/private destination,
protocol and ports; VPN type, BGP capabilities and prefixes; source-IP contract;
public/private FQDNs and TLS requirements; application concurrency/state model;
HSM recovery topology; and business RTO/RPO. Obtain approval for the resulting
resource, routing, and cost changes.

Remaining work after approval (the repository already provides the Terraform/Bicep for
dual-region IIS VMs, Private Link origins on HTTPS 8082, WAF, VPN firewall rules and
the Client A egress rule):

- Deploy the IIS site, the HTTPS binding on 8082 and the certificate for the application
  FQDN; implement a readiness endpoint that reflects dependency health.
- Approve the Front Door private endpoint connections on both Private Link Services.
- Agree and, if required, implement a NAT Gateway design for a deterministic Client A
  source IP (the repository only adds the reserved IP to the firewall).
- Implement private DNS selection for VPN callers, worker ownership with fencing,
  state/key recovery, telemetry, and promotion/failback runbooks.
- Resolve spoke DNS resolution for private endpoints (spoke VNets use Azure-provided DNS
  while private DNS zones are linked only to the North Europe hub) and link the zones to
  the West Europe hub.

Acceptance tests:

1. Public FQDN on 443 succeeds through WAF to IIS:8082; direct public VM/origin
      access fails. Verify certificates, PLS approval, source restrictions, and logs.
2. Make NEU IIS unhealthy without stopping its VPN. Verify public failover and,
      separately, private DNS selection, client reconnect, and WEU readiness.
3. Drop NEU VPN while IIS remains healthy. Verify tunnel/route convergence and
      application reachability through the surviving path, including return traffic.
4. Initiate Client A sessions from each region and confirm observed source IP,
      firewall inspection, allowlist acceptance, and no unintended destination access.
5. Simulate process failure and network partition. Verify only one authorized
      worker processes each payment, HSM operations succeed, and uncertain outcomes
      are reconciled without duplicate side effects.
6. Exercise state/key recovery and controlled failback; record measured RTO/RPO,
      DNS/cache delays, data integrity, and operator evidence.

## Microsoft Guidance

- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/)
- [Well-Architected guidance for Azure Front Door](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/azure-front-door)
- [Architecture Center: multi-region N-tier application](https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/n-tier/multi-region-sql-server) (use the regional reliability principles, not an assumption that this customer uses SQL Server)
- [Front Door Premium to an internal load balancer over Private Link](https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-enable-private-link-internal-load-balancer)
- [Secure Front Door origins](https://learn.microsoft.com/en-us/azure/frontdoor/origin-security)
- [Firewall integration with NAT Gateway](https://learn.microsoft.com/en-us/azure/firewall/integrate-with-nat-gateway)
- [Azure Firewall SNAT private address ranges](https://learn.microsoft.com/en-us/azure/firewall/snat-private-range)
- [Highly available VPN connectivity](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-highlyavailable)
- [Architecture Center: leader election pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/leader-election)
- [Managed HSM multi-region replication](https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/multi-region-replication)
