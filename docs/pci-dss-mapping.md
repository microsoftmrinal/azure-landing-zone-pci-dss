# PCI DSS v4.0 Requirement-to-Control Mapping

This document maps every PCI DSS v4.0 requirement to the specific Azure control implemented in this landing zone.

## Requirement 1: Install and Maintain Network Security Controls

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 1.2.1 - Network segmentation | Hub-spoke topology with forced firewall routing | `modules/connectivity/hub`, `modules/connectivity/spoke` |
| 1.2.5 - All services/ports allowed are identified | Azure Firewall Premium rule collections (explicit allow) | `modules/connectivity/firewall` |
| 1.3.1 - Inbound traffic restricted | Front Door WAF to private IIS origins; no public IPs on VMs (Azure Policy deny); NSG allows TCP 8082 only from the Private Link Service subnet and approved VPN prefixes | `modules/connectivity/front-door`, `modules/connectivity/spoke`, Azure Policy deny |
| 1.3.2 - Outbound traffic restricted | UDR 0.0.0.0/0 → Firewall; IDPS in Deny mode; scoped Client A egress rule | `modules/connectivity/firewall` |
| 1.4.1 - NSGs between trusted/untrusted | NSG on every spoke subnet (default deny inbound) | `modules/connectivity/spoke` |

## Requirement 2: Apply Secure Configurations

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 2.2.1 - System configuration standards | Azure Policy (TLS 1.2, encryption, allowed SKUs) | `modules/policy` |
| 2.2.7 - Non-console admin encrypted | Azure Bastion (RDP over TLS); no SSH or direct RDP from the internet | `modules/connectivity/hub`, `modules/connectivity/spoke` |
| 2.3.1 - Wireless not applicable | Cloud-native; no wireless in scope | N/A |

## Requirement 3: Protect Stored Account Data

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 3.5.1 - Encryption keys protected | Managed HSM (FIPS 140-2 Level 3) | `modules/data-platform/hsm` |
| 3.5.1.1 - Key access restricted | RBAC on HSM + PIM just-in-time | `modules/security/identity` |
| 3.6.1 - Key management procedures | HSM key rotation policy (annual) | `modules/data-platform/hsm` |
| 3.7.1 - Encryption of stored data | SQL TDE with CMK from HSM | `modules/data-platform/sql` |

## Requirement 4: Protect Cardholder Data in Transit

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 4.2.1 - Strong cryptography in transit | TLS 1.2 minimum; HTTPS to IIS on 8082 with certificate name validation from Front Door; WAF in front | `modules/application-platform/compute`, `modules/connectivity/front-door` |
| 4.2.1.1 - Certificate management | Front Door managed certificates; Key Vault for internal | `modules/connectivity/front-door` |

## Requirement 5: Protect Against Malicious Software

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 5.2.1 - Anti-malware deployed | Microsoft Defender for Servers (real-time protection) | `modules/security/defender` |
| 5.3.1 - Anti-malware mechanisms active | Defender auto-provisioning enabled | `modules/security/defender` |

## Requirement 6: Develop and Maintain Secure Systems

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 6.2.4 - Software engineering techniques | IaC via Terraform; PR review required; no portal changes | `.github/workflows/deploy.yml` |
| 6.3.1 - Vulnerability identification | Defender vulnerability assessment (SQL, VMs, containers) | `modules/security/defender` |
| 6.4.1 - Public-facing web app protection | Front Door Premium WAF (OWASP + Bot Manager) in Prevention mode | `modules/connectivity/front-door` |
| 6.4.2 - WAF detection/prevention | WAF policy in Prevention mode with Default Rule Set 2.1 | `modules/connectivity/front-door` |

## Requirement 7: Restrict Access to System Components

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 7.2.1 - Access based on need to know | Azure RBAC + PIM (no standing access) | `modules/security/identity` |
| 7.2.2 - Access assigned based on job function | Entra ID security groups; role-based assignment | `modules/security/identity` |

## Requirement 8: Identify Users and Authenticate Access

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 8.3.1 - MFA for all CDE access | Conditional Access: phishing-resistant MFA required | `modules/security/identity` |
| 8.3.2 - Strong authentication (MFA) | FIDO2 / certificate-based authentication | `modules/security/identity` |
| 8.4.1 - MFA for admin access | CA policy on admin roles | `modules/security/identity` |
| 8.6.1 - System/application accounts managed | Managed Identities (no passwords); Key Vault for secrets | `modules/data-platform/hsm` |

## Requirement 9: Restrict Physical Access

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 9.x - Physical security | Microsoft PCI AoC covers datacenter physical security | Platform responsibility |

## Requirement 10: Log and Monitor All Access

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 10.2.1 - Audit log covers all access | Diagnostic settings on every resource; 365-day retention | All modules |
| 10.2.2 - Admin actions logged | Activity Log + SQL audit + Key Vault audit | `modules/security/sentinel` |
| 10.3.1 - Audit log protected | Immutable (WORM) storage for audit logs | `modules/data-platform/storage` |
| 10.4.1 - Audit logs reviewed | Microsoft Sentinel analytics rules + scheduled alerts | `modules/security/sentinel` |
| 10.7.1 - Critical failures trigger alert | Sentinel: brute force, data exfiltration alerts | `modules/security/sentinel` |

## Requirement 11: Test Security Regularly

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 11.3.1 - Internal vulnerability scans | Defender for Cloud continuous assessment | `modules/security/defender` |
| 11.4.1 - Penetration testing | Manual (authorised); Defender recommendations as input | Process |
| 11.5.1 - Network intrusion detection | Azure Firewall Premium IDPS in Deny mode | `modules/connectivity/firewall` |
| 11.6.1 - Change detection on payment pages | Front Door WAF; page change/tamper detection is an application-level control to be implemented and evidenced (not provided by this repository) | `modules/connectivity/front-door` |

## Requirement 12: Support Information Security with Policies

| Sub-Requirement | Azure Control | Resource |
|----------------|---------------|----------|
| 12.3.1 - Risk assessment | Defender for Cloud Secure Score + PCI dashboard | `modules/security/defender` |
| 12.10.1 - Incident response plan | Microsoft Sentinel playbooks + automation rules | `modules/security/sentinel` |
