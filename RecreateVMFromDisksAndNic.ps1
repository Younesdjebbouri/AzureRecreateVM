param(
  [Parameter(Mandatory = $true)][string]$subscriptionID, #ex: 00000000-0000-0000-0000-000000000000
  [Parameter(Mandatory = $true)][string]$resourceGroupName, #ex: RG-APP-VD-DEV-001
  [Parameter(Mandatory = $true)][string]$vmName, #ex: vm-test-az1
  [Parameter(Mandatory = $true)][string]$nicName, #ex: nic1-vm-test-az1
  [Parameter(Mandatory = $true)][string]$location, #ex: francecentral
  [Parameter(Mandatory = $true)][string]$size, #ex: Standard_F16s_v2
  [Parameter(Mandatory = $true)][string]$osDiskName, #ex: osdisk-vm-test-az1
  [string[]]$dataDisksName, #ex: datadisk-0-vm-test-az1,datadisk-1-vm-test-az1
  [Parameter(Mandatory = $true)][string]$avName, # Availability Set name, ex: as-app-vm-test-az1
  [Parameter(Mandatory = $true)][string]$ppgName, # Proximity Placement Group name, ex: ppg-app-vm-test-az1
  [string]$ppgZone, # Proximity Placement Group zone, ex: 1
  [string[]]$intentVMSizeList, # Possible sizes of virtual machines that can be created in the proximity placement group
  [hashtable]$tags = @{},
  [bool]$windows = $true,
  [bool]$onPremiseLicense = $true
)

$ErrorActionPreference = "Stop"

Set-AzContext -Subscription $subscriptionID | Out-Null

# Checks
$vm = Get-AzVm -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Ignore
if ($vm)
{
  Write-Error "VM $vmName already exists in $resourceGroupName !!"
  Exit 1
}

function GetDisk($resourceGroupName, $diskName)
{
  $disk = Get-AzDisk -ResourceGroupName $resourceGroupName -DiskName $diskName
  if ($null -eq $disk)
  {
    Write-Error "Disk $name doesn't exists"
    Exit 2
  }
  else
  {
    Write-Host "Got disk: $diskName"
  }
  if ($null -ne $disk.ManagedBy)
  {
    Write-Error "Disk $name is already attached to $($disk.ManagedBy.Split("/")[-1])"
    Exit 3
  }
  return $disk
}


# Create new availability set if it does not exist
$availSet = Get-AzAvailabilitySet -ResourceGroupName $resourceGroupName -Name $avName -ErrorAction Ignore
if (-Not $availSet)
{
  Write-Host "Availability Set $avName doesn't exists yet, let's create it"
  if (-Not $ppgName)
  {
    Write-Error "-ppgName parameter must be specified when the Availability Set doesn't exists yet"
    Exit 4
  }
  $ppg = Get-AzProximityPlacementGroup -ResourceGroupName $resourceGroupName -Name $ppgName -ErrorAction Ignore
  Write-Host "Proximity Placement Group $ppgName doesn't exists yet, let's create it"
  if (-Not $ppg)
  {
    $ppg = New-AzProximityPlacementGroup `
      -Location $location `
      -Name $ppgName `
      -ResourceGroupName $resourceGroupName `
      -ProximityPlacementGroupType Standard `
      -Zone $ppgZone `
      -IntentVMSizeList $intentVMSizeList
    Write-Host "Proximity Placement Group $ppgName created"
  }

  $availSet = New-AzAvailabilitySet `
    -Location $location `
    -Name $avName `
    -ResourceGroupName $resourceGroupName `
    -PlatformFaultDomainCount 2 `
    -Sku Aligned `
    -ProximityPlacementGroupId $ppg.Id
    # -PlatformUpdateDomainCount 5 ` # not required
  Write-Host "Availability Set $avName created and attached to Proximity Placement Group $($ppg.Name)"
}


Write-Host "Create the virtual machine configuration"
$extraArgs = @{}
if ($onPremiseLicense -and $windows) {$extraArgs = @{LicenseType = "Windows_Server"}}
$vm = New-AzVMConfig `
  -VMName $vmName `
  -VMSize $size `
  -AvailabilitySetId $availSet.Id `
  -Tags $tags `
  @extraArgs

Write-Host "Attaching OS disk: $osDiskName"
$osDisk = GetDisk $resourceGroupName $osDiskName
if ($windows) { $extraArgs = @{Windows = $true} }
else { $extraArgs = @{Linux = $true} }
$vm = Set-AzVMOSDisk `
  -VM $vm `
  -ManagedDiskId $osDisk.Id `
  -CreateOption Attach `
  -Caching ReadWrite `
  @extraArgs
Write-Host "OS disk $osDiskName attached"

if ($dataDisksName)
{
  Write-Host "Attaching data disks"
  $lun = 0
  foreach ($dataDiskName in $dataDisksName)
  {
    $dataDisk = GetDisk $resourceGroupName $dataDiskName
    $dataDiskCaching = "ReadOnly"
    if ($dataDisk.DiskSizeGB -gt 4095)
    {
      # Only Disk CachingType 'None' is supported for disk with size greater than 4095 GB
      $dataDiskCaching = "None"
    }
    $vm = Add-AzVMDataDisk `
      -VM $vm `
      -Name $dataDiskName `
      -ManagedDiskId $dataDisk.Id `
      -CreateOption Attach `
      -Lun $lun `
      -Caching $dataDiskCaching
    Write-Host "Data disk $dataDiskName attached"
    $lun++
  }
}

Write-Host "Attaching network card $nicName"
$nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName -Name $nicName
$vm = Add-AzVMNetworkInterface `
  -VM $vm `
  -Id $nic.Id
Write-Host "Network card $nicName attached"

$vm = Set-AzVMBootDiagnostic -VM $vm -Disable
$vm = Set-AzVMSecurityProfile -VM $vm -SecurityType "Standard"  # Prevents TrustedLaunch new default

Write-Host "Create the virtual machine $vmName"
New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vm -DisableBginfoExtension
Write-Host "Virtual machine $vmName created"
