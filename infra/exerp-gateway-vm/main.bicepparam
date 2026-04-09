// =============================================================================
// Exerp Data Gateway VM — Deployment Parameters (Production)
// =============================================================================
// ⚠️  SECURITY: Do NOT commit adminPassword to source control.
//     Use Azure Key Vault reference or set via CI/CD pipeline secret:
//
//     az deployment sub create \
//       --location uksouth \
//       --template-file main.bicep \
//       --parameters main.bicepparam \
//       --parameters adminPassword="$(az keyvault secret show --vault-name <kv> --name vm-admin-password --query value -o tsv)"
//
// =============================================================================
using './main.bicep'

param location           = 'uksouth'
param environment        = 'dev'
//param resourceGroupName  = 'rg-exerp-gateway-prod'
param workloadName       = 'exerp-gateway'

// Networking — isolated VNet, no peering required for Bastion access
param vnetAddressPrefix  = '10.100.0.0/16'
param vmSubnetPrefix     = '10.100.0.0/24'
param bastionSubnetPrefix = '10.100.1.0/26'
param vmPrivateIpAddress = '10.100.0.4'

// VM spec — Standard_D4s_v3 (4 vCPU / 16 GB) meets recommended data gateway spec
param vmSize             = 'Standard_D4s_v3'

// VM credentials — adminPassword must be supplied at deploy time (DO NOT set here)
param adminUsername      = 'pgexerpadmin'
param adminPassword      = 'overriden by parameter injection at yaml level' // ← DO NOT set real password here. Set via CI/CD pipeline secret or Azure Key Vault reference.
// Entra ID VM Login — Object ID of the AAD group (or user) who will RDP via Bastion + MFA.
// Find this in: Azure Portal → Entra ID → Groups → <group> → Object ID
// OR: az ad group show --group "PureGym-ExerpGateway-Admins" --query id -o tsv
param entraVmAdminGroupObjectId = '00000000-0000-0000-0000-000000000000' // ← replace with real group Object ID

param tags = {
  environment: 'prod'
  workload: 'exerp-gateway'
  deployedBy: 'AVM-Bicep'
  costCenter: 'FabricDevelopment'
  owner: 'data-team'
}
