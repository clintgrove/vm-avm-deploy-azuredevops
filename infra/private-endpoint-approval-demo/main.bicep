// =============================================================================
// Private Endpoint Approval Demo — Bicep (resourceGroup scope)
// =============================================================================
// Purpose:
//   Demonstrate the two-identity approval pattern:
//     • Identity A  (sp-pe-creator)   — deploys this template → creates the
//       private endpoint in 'Pending' state against an EXISTING storage account.
//     • Identity B  (sp-pe-approver)  — runs a separate GitHub Actions job →
//       approves the pending connection using az CLI.
//
// Why the endpoint lands in 'Pending':
//   This template provisions a private endpoint that requests a connection to
//   the storage account. Because Identity A has NO role on the target storage
//   account (by design — only Network Contributor on this resource group), it
//   cannot auto-approve the connection. The connection therefore enters
//   'Pending' state, waiting for an authorised identity to approve it.
//
// RBAC requirements (surfaced by this demo):
// ┌──────────────────────────────────────────────────────────────────────────┐
// │ Identity A  — sp-pe-creator                                              │
// │   Role  : Network Contributor                                            │
// │   Scope : Resource group where the private endpoint is deployed          │
// │   Why   : Needs Microsoft.Network/privateEndpoints/write to create the   │
// │           PE resource. No access to the storage account is needed.       │
// ├──────────────────────────────────────────────────────────────────────────┤
// │ Identity B  — sp-pe-approver                                             │
// │   Role  : Storage Account Contributor  (broad — good for testing)        │
// │        OR Custom role with ONLY:                                         │
// │           • Microsoft.Storage/storageAccounts/read                       │
// │           • Microsoft.Storage/storageAccounts/privateEndpointConnections/read  │
// │           • Microsoft.Storage/storageAccounts/privateEndpointConnections/write │
// │   Scope : The target storage account resource                            │
// │   Why   : The approve CLI call acts on the storage account's             │
// │           privateEndpointConnections sub-resource. No network or PE      │
// │           resource group permissions are needed.                         │
// └──────────────────────────────────────────────────────────────────────────┘
//
// Resources created by this template:
//   - Microsoft.Network/privateEndpoints  (1 — against existing storage account)
//
// Resources NOT created (must already exist — supply as parameters):
//   - Storage account   → storageAccountResourceId
//   - VNet + subnet     → subnetResourceId
// =============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Name for the private endpoint resource.')
param privateEndpointName string = 'pe-storage-demo'

@description('Azure region. Must match the region of the subnet.')
param location string = 'uksouth'

@description('''
Full resource ID of the EXISTING storage account to connect to.
Example: /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>
Get it via:  az storage account show --name <name> --resource-group <rg> --query id -o tsv
''')
param storageAccountResourceId string

@description('''
Full resource ID of the EXISTING subnet into which the private endpoint NIC will be injected.
Example: /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>
Get it via:  az network vnet subnet show --vnet-name <vnet> --resource-group <rg> --name <subnet> --query id -o tsv
''')
param subnetResourceId string

@description('''
The sub-resource (group ID) of the storage account service to connect to.
Common values:
  blob  — Blob Storage (most common)
  file  — Azure Files
  queue — Queue Storage
  table — Table Storage
  dfs   — Azure Data Lake Storage Gen2
''')
@allowed(['blob', 'file', 'queue', 'table', 'dfs'])
param storageSubResource string = 'blob'

@description('Tags applied to the private endpoint resource.')
param tags object = {
  demo: 'pe-approval-pattern'
  createdBy: 'sp-pe-creator'
}

// ---------------------------------------------------------------------------
// Private Endpoint
//
// Uses AVM module: br/public:avm/res/network/private-endpoint:0.11.0
//
// The privateLinkServiceConnections block registers a connection request
// against the storage account. Because sp-pe-creator has no role on the
// storage account, Azure cannot auto-approve — the connection enters
// 'Pending' state. Identity B must approve it separately.
// ---------------------------------------------------------------------------

module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.0' = {
  name: 'deploy-private-endpoint'
  params: {
    name: privateEndpointName
    location: location
    tags: tags
    subnetResourceId: subnetResourceId
    // manualPrivateLinkServiceConnections (not privateLinkServiceConnections) is required
    // to land in Pending state. Using the automatic variant requires the deploying identity
    // to have PrivateEndpointConnectionsApproval/action on the target resource — if it
    // doesn't, the deployment fails with LinkedAuthorizationFailed rather than going Pending.
    manualPrivateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-conn'
        properties: {
          privateLinkServiceId: storageAccountResourceId
          groupIds: [
            storageSubResource
          ]
          requestMessage: 'Pending approval — created by sp-pe-creator via GitHub Actions'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the private endpoint.')
output privateEndpointResourceId string = privateEndpoint.outputs.resourceId

@description('Name of the private endpoint resource.')
output privateEndpointName string = privateEndpoint.outputs.name

@description('Reminder: connection is Pending. The approve job (sp-pe-approver) must run next.')
output nextStep string = 'Connection is PENDING on the storage account — the approve job must run as sp-pe-approver.'
