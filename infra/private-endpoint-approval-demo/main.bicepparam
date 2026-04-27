// =============================================================================
// Private Endpoint Approval Demo — Deployment Parameters
// =============================================================================
// ⚠️  Replace ALL placeholder values before running.
//     Better yet — leave the placeholders here and supply real values as
//     GitHub Actions variables/secrets so resource IDs are never committed
//     to source control. See the workflow YAML for how these are overridden.
//
// How to find each value:
//
//   storageAccountResourceId:
//     az storage account show --name <storageAccountName> \
//       --resource-group <rg> --query id -o tsv
//
//   subnetResourceId:
//     az network vnet subnet show \
//       --vnet-name <vnetName> --resource-group <rg> \
//       --name <subnetName> --query id -o tsv
// =============================================================================
using './main.bicep'

// Name of the private endpoint that will appear in Azure.
// Naming convention: pe-<purpose>-<subresource>
param privateEndpointName = 'pe-storage-blob-demo'

// Region — must match your existing subnet's region.
param location = 'uksouth'

// ← Overridden at workflow level via GitHub variable STORAGE_ACCOUNT_RESOURCE_ID.
// Placeholder kept here so the file is valid standalone.
param storageAccountResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-placeholder/providers/Microsoft.Storage/storageAccounts/stplaceholder'

// ← Overridden at workflow level via GitHub variable SUBNET_RESOURCE_ID.
param subnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-placeholder/providers/Microsoft.Network/virtualNetworks/vnet-placeholder/subnets/snet-placeholder'

// Sub-resource type. Change to 'file', 'queue', 'table', or 'dfs' if needed.
param storageSubResource = 'blob'

param tags = {
  demo: 'pe-approval-pattern'
  createdBy: 'sp-pe-creator'
  environment: 'dev'
}
