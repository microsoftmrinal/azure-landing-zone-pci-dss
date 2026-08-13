using 'main.bicep'

param primaryLocation = 'northeurope'
param drLocation = 'westeurope'
param orgPrefix = 'p24'
param environment = 'prod'
param sqlAdminObjectId = '<REPLACE-WITH-ENTRA-GROUP-OBJECT-ID>'
param hsmAdminObjectIds = ['<REPLACE-WITH-HSM-ADMIN-OBJECT-ID>']
param logAnalyticsWorkspaceId = '<REPLACE-WITH-LAW-RESOURCE-ID>'
