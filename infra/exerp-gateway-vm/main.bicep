// =============================================================================
// Exerp Data Gateway VM - Azure Verified Modules (AVM) Bicep Deployment
// =============================================================================
// Purpose: Hosts the Microsoft On-Premises Data Gateway to connect Power BI /
//          Fabric to Amazon Redshift (Exerp data).
//
// Security design:
//   - NO public RDP exposure. Access only via Azure Bastion over HTTPS/443.
//   - Static public IP attached to VM for OUTBOUND only → whitelist this in
//     Amazon Redshift firewall rules.
//   - NSG blocks all inbound RDP from Internet; only AzureBastionSubnet can
//     reach port 3389.
//   - Encryption at host enabled.
//   - Automatic OS patching enabled.
//
// AVM modules used:
//   - br/public:avm/res/resources/resource-group
//   - br/public:avm/res/network/network-security-group
//   - br/public:avm/res/network/virtual-network
//   - br/public:avm/res/network/public-ip-address (x2: Bastion + VM outbound)
//   - br/public:avm/res/network/bastion-host
//   - br/public:avm/res/compute/virtual-machine  (with AADLoginForWindows extension)
//   - br/public:avm/res/authorization/role-assignment  (Virtual Machine Administrator Login)
// =============================================================================

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = 'uksouth'

@description('Environment tag (e.g. prod, dev).')
@allowed(['prod', 'dev', 'test'])
param environment string = 'prod'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-exerp-gateway-${environment}'

@description('Name prefix used for all resources.')
param workloadName string = 'exerp-gateway'

@description('Virtual network address space.')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('VM subnet address prefix (within vnetAddressPrefix).')
param vmSubnetPrefix string = '10.100.0.0/24'

@description('Bastion subnet address prefix — must be named AzureBastionSubnet, min /26.')
param bastionSubnetPrefix string = '10.100.1.0/26'

@description('Static private IP for the VM within the VM subnet.')
param vmPrivateIpAddress string = '10.100.0.4'

@description('VM size. Standard_D4s_v3 = 4 vCPU / 16 GB — meets data gateway recommended spec.')
@allowed([
  'Standard_D2s_v3'  // Minimum — 2 vCPU / 8 GB
  'Standard_D4s_v3'  // Recommended — 4 vCPU / 16 GB
])
param vmSize string = 'Standard_D4s_v3'

@description('Local administrator username for the VM.')
param adminUsername string

@description('Local administrator password. Store in Key Vault; never commit to source control.')
@secure()
param adminPassword string

@description('Object ID of the Entra ID (Azure AD) group or user to be granted Virtual Machine Administrator Login. Required for Entra ID VM Login (RDP via Bastion with MFA).')
param entraVmAdminGroupObjectId string

@description('Tags applied to all resources.')
param tags object = {
  environment: environment
  workload: workloadName
  deployedBy: 'AVM-Bicep'
  costCenter: 'FabricDevelopment'
}

// ---------------------------------------------------------------------------
// Derived names (consistent naming convention)
// ---------------------------------------------------------------------------

var nsgVmName       = 'nsg-${workloadName}-vm'
var vnetName        = 'vnet-${workloadName}'
var pipBastionName  = 'pip-bastion-${workloadName}'
var pipVmName       = 'pip-${workloadName}-vm'
var bastionName     = 'bas-${workloadName}'
var vmName          = 'vm-${workloadName}'  // Max 15 chars for Windows

// Built-in role definition IDs (do not change — these are Azure global constants)
// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
var roleVmAdminLoginId = '1c0163c0-47e6-4577-8991-ea5c82e286e4' // Virtual Machine Administrator Login

// ---------------------------------------------------------------------------
// Resource Group
// ---------------------------------------------------------------------------

module resourceGroup 'br/public:avm/res/resources/resource-group:0.4.3' = {
  name: 'deploy-resource-group'
  params: {
    name: resourceGroupName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Network Security Group — VM Subnet
// Blocks all internet-facing RDP. Only allows RDP from AzureBastionSubnet.
// ---------------------------------------------------------------------------

module nsgVm 'br/public:avm/res/network/network-security-group:0.5.3' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'deploy-nsg-vm'
  dependsOn: [resourceGroup]
  params: {
    name: nsgVmName
    location: location
    tags: tags
    securityRules: [
      // ALLOW: RDP from Bastion subnet only (Bastion proxies HTTPS→RDP internally)
      {
        name: 'Allow-RDP-From-Bastion'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
          description: 'Allow RDP only from Azure Bastion subnet'
        }
      }
      // DENY: All inbound RDP from the internet — security baseline
      {
        name: 'Deny-RDP-From-Internet'
        properties: {
          priority: 200
          protocol: 'Tcp'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
          description: 'Deny all internet RDP — use Bastion for VM access'
        }
      }
      // DENY: WinRM from internet (Windows remote management — often targeted)
      {
        name: 'Deny-WinRM-From-Internet'
        properties: {
          priority: 210
          protocol: 'Tcp'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '5985-5986'
          description: 'Deny WinRM from internet'
        }
      }
      // ALLOW: Outbound HTTPS to Amazon Redshift (port 5439 default)
      // Redshift should whitelist the static VM public IP (pip-exerp-gateway-vm).
      {
        name: 'Allow-Outbound-Redshift'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '5439'
          description: 'Outbound to Amazon Redshift default port'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Network — VM subnet + AzureBastionSubnet
// ---------------------------------------------------------------------------

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.8.0' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'deploy-virtual-network'
  dependsOn: [resourceGroup, nsgVm]
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [vnetAddressPrefix]
    subnets: [
      {
        // VM subnet — NSG applied
        name: 'snet-vm'
        addressPrefix: vmSubnetPrefix
        networkSecurityGroupResourceId: nsgVm.outputs.resourceId
      }
      {
        // Azure Bastion requires this exact subnet name; no NSG restriction here
        // (Bastion manages its own security internally)
        name: 'AzureBastionSubnet'
        addressPrefix: bastionSubnetPrefix
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP — Azure Bastion (Standard, Static — required by Bastion)
// ---------------------------------------------------------------------------

module pipBastion 'br/public:avm/res/network/public-ip-address:0.12.0' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'deploy-pip-bastion'
  dependsOn: [resourceGroup]
  params: {
    name: pipBastionName
    location: location
    tags: tags
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
  }
}

// ---------------------------------------------------------------------------
// Public IP — VM outbound (Static, Standard)
//
// This IP is NOT for inbound RDP. It provides a stable outbound egress IP
// so that the Amazon Redshift cluster firewall can whitelist this single IP.
//
// ⚠️  After deployment: note the IP from this resource and supply it to the
//      Amazon Redshift / Exerp team to add to their inbound allowlist.
// ---------------------------------------------------------------------------

module pipVm 'br/public:avm/res/network/public-ip-address:0.12.0' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'deploy-pip-vm'
  dependsOn: [resourceGroup]
  params: {
    name: pipVmName
    location: location
    tags: tags
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'  // Guaranteed never to change
  }
}

// ---------------------------------------------------------------------------
// Azure Bastion — Standard SKU
//
// Standard SKU is chosen over Basic because it supports:
//   - Native RDP client tunneling: az network bastion rdp --name ... --resource-group ...
//   - Copy/paste and file transfer
//   - Shareable links
//
// Access pattern:
//   Portal: https://portal.azure.com → VM blade → Bastion → Connect
//   CLI:    az network bastion rdp --name <bastion> --resource-group <rg>
//           --target-resource-id <vm-resource-id>
// ---------------------------------------------------------------------------

module bastionHost 'br/public:avm/res/network/bastion-host:0.8.2' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'deploy-bastion-host'
  dependsOn: [virtualNetwork, pipBastion]
  params: {
    name: bastionName
    location: location
    tags: tags
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    skuName: 'Standard'
    publicIPAddressObject: {
      name: pipBastionName
      publicIPAllocationMethod: 'Static'
      skuName: 'Standard'
    }
  }
}

// ---------------------------------------------------------------------------
// Virtual Machine — Windows Server 2022, D4s_v3
//
// Spec rationale:
//   - Standard_D4s_v3: 4 vCPU / 16 GB RAM / SSD-backed — exceeds recommended
//     spec for Microsoft On-Premises Data Gateway (8 core / 8 GB recommended)
//   - Windows Server 2022 Datacenter Azure Edition — newer than required 2019,
//     includes Hotpatch support for fewer reboots
//   - Premium_LRS OS disk = SSD (recommended for data gateway)
//   - Static private IP = predictable internal addressing
//   - Static public IP = stable outbound for Redshift whitelisting
//   - Encryption at host = data at rest encrypted including temp disk
//   - AutomaticByPlatform patch mode = WSUS-free, no reboot surprises
// ---------------------------------------------------------------------------

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.22.0' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'deploy-virtual-machine'
  dependsOn: [virtualNetwork, pipVm]
  params: {
    name: vmName
    location: location
    tags: tags
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    osType: 'Windows'
    availabilityZone: 1  // Specify the availability zone(s) for the VM
    // Windows Server 2022 Datacenter Azure Edition
    // Meets requirement: 64-bit Windows Server >= 2019
    imageReference: {
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2022-datacenter-azure-edition'
      version: 'latest'
    }

    // SSD OS disk — meets 'solid-state drive' recommendation
    osDisk: {
      createOption: 'FromImage'
      caching: 'ReadWrite'
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
      diskSizeGB: 128  // > 4 GB minimum for performance monitoring logs
    }

    // NIC configuration: static private IP + static public IP (outbound)
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        enableAcceleratedNetworking: true  // Supported on D4s_v3
        ipConfigurations: [
          {
            name: 'ipconfig-01'
            subnetResourceId: virtualNetwork.outputs.subnetResourceIds[0]
            privateIPAllocationMethod: 'Static'
            privateIPAddress: vmPrivateIpAddress
            pipConfiguration: {
              publicIPAddressResourceId: pipVm.outputs.resourceId
            }
          }
        ]
      }
    ]

    // Security hardening
    encryptionAtHost: true

    // Automatic patching — 'AutomaticByPlatform' keeps the VM patched without
    // requiring manual Windows Update runs or WSUS
    patchMode: 'AutomaticByPlatform'
    enableAutomaticUpdates: true

    // Set to UK time for PureGym operational consistency
    timeZone: 'GMT Standard Time'

    // Boot diagnostics — stored in managed storage (no storage account needed)
    bootDiagnostics: true

    // ---------------------------------------------------------------------------
    // Entra ID (Azure AD) VM Login extension
    //
    // Installs AADLoginForWindows on the VM, enabling users to authenticate
    // via Entra ID (MFA supported) instead of local username/password.
    //
    // After deployment, assign the 'Virtual Machine Administrator Login' role
    // (handled below via the authorization/role-assignment module).
    //
    // RDP via Bastion + Entra ID login pattern:
    //   1. Open Azure Portal → VM → Connect → Bastion
    //   2. Choose 'Entra ID' auth option (requires Standard Bastion SKU ✓)
    //   3. Sign in with corporate Entra ID credentials (MFA enforced by policy)
    // ---------------------------------------------------------------------------
    extensionAadJoinConfig: {
      enabled: true
    }

    // RBAC: Grant the Entra admin group 'Virtual Machine Administrator Login'
    // role scoped to this VM so they can sign in via Entra ID over Bastion.
    roleAssignments: [
      {
        roleDefinitionIdOrName: roleVmAdminLoginId
        principalId: entraVmAdminGroupObjectId
        principalType: 'Group' // Change to 'User' if assigning a single user
        description: 'Allows Entra ID group to RDP into the VM via Bastion with MFA'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('ID of the deployed resource group.')
output resourceGroupId string = resourceGroup.outputs.resourceId

@description('Static public IP address of the VM. ⚠️  Whitelist this IP in Amazon Redshift firewall.')
output vmStaticPublicIp string = pipVm.outputs.ipAddress

@description('Private IP address of the VM within the VNet.')
output vmPrivateIp string = vmPrivateIpAddress

@description('Resource ID of the VM — used with Bastion CLI: az network bastion rdp --target-resource-id <this>.')
output vmResourceId string = virtualMachine.outputs.resourceId

@description('Resource ID of the Bastion Host.')
output bastionResourceId string = bastionHost.outputs.resourceId

@description('Entra ID VM Login role assignment — Virtual Machine Administrator Login granted to provided group/user.')
output entraVmLoginRoleNote string = 'AADLoginForWindows extension installed. Group ${entraVmAdminGroupObjectId} has been granted Virtual Machine Administrator Login on the VM.'
