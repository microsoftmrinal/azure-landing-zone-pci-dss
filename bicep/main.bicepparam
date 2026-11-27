using 'main.bicep'

param primaryLocation = 'northeurope'
param drLocation = 'westeurope'
param orgPrefix = 'p24'
param environment = 'prod'
param sqlAdminObjectId = '<REPLACE-WITH-ENTRA-GROUP-OBJECT-ID>'
param hsmAdminObjectIds = ['<REPLACE-WITH-HSM-ADMIN-OBJECT-ID>']
param logAnalyticsWorkspaceId = '<REPLACE-WITH-LAW-RESOURCE-ID>'

// Supply at deployment time from Key Vault, e.g. --parameters vmAdminPassword=$(...). Never commit.
param vmAdminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', '')

param appPort = 8082
// FQDN on the IIS certificate (must cover both regions).
param appOriginHostname = '<REPLACE-WITH-APP-FQDN>'

// Client B: inbound over VPN. Client A: connections initiated by the custom app on the VM.
param clientBInboundPrefixes = []
param clientADestinationPrefixes = []
param clientADestinationPorts = []
// Reserved IP (e.g. pip-clientA-nat-egress) added to the firewall. Client A must allow-list ALL firewall egress IPs.
param clientAEgressPublicIpId = ''
param drClientAEgressPublicIpId = ''
