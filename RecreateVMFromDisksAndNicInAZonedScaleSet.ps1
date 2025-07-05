param(
  [Parameter(Mandatory = $true)][string]$subscriptionID , #ex: 00000000-0000-0000-0000-000000000000
  [Parameter(Mandatory = $true)][string]$resourceGroupName , #ex: RG-APP-DEV-01
  [Parameter(Mandatory = $true)][string]$vmName, #ex: vm-app-test-01
  [Parameter(Mandatory = $true)][string]$nicName , #ex: nic1-vm-app-test-01
  [Parameter(Mandatory = $true)][string]$nicResourceGroupName ,
  [Parameter(Mandatory = $true)][string]$location , #ex: francecentral
  [Parameter(Mandatory = $true)][string]$size , #ex: Standard_F16s_v2
  [Parameter(Mandatory = $true)][string]$osDiskName , #ex: osdisk-vm-app-test-01-az1
  [string[]]$dataDisksName , #ex: datadisk-0-vm-app-test-01-az1,datadisk-1-vm-app-test-01-az1
  [Parameter(Mandatory = $true)][string]$zone , # Availability zone, ex: 1
  [Parameter(Mandatory = $true)][string]$vmssName, # Scale Set name, ex: vmss1
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

$vmss = Get-AzVmss -ResourceGroupName $resourceGroupName -Name $vmssName -ErrorAction Stop
if ($vmss.Zones[0] -ne $zone)
{
  Write-Error "Scale Set is not in the same zone as specified for the vm"
  Exit 2
}
if ($vmss.Location.ToLower() -ne $location.ToLower())
{
  Write-Error "Scale Set is not in the same location as specified for the vm"
  Exit 2
}

function GetDisk($resourceGroupName, $diskName)
{
  $disk = Get-AzDisk -ResourceGroupName $resourceGroupName -DiskName $diskName
  if ($null -eq $disk)
  {
    Write-Error "Disk $name doesn't exists"
    Exit 3
  }
  else
  {
    Write-Host "Got disk: $diskName"
  }
  if ($null -ne $disk.ManagedBy)
  {
    Write-Error "Disk $name is already attached to $($disk.ManagedBy.Split("/")[-1])"
    Exit 4
  }
  return $disk
}



Write-Host "Create the virtual machine configuration"
$extraArgs = @{}
if ($onPremiseLicense -and $windows) {$extraArgs = @{LicenseType = "Windows_Server"}}
$vm = New-AzVMConfig `
  -VMName $vmName `
  -VMSize $size `
  -Zone $zone `
  -VmssId $vmss.Id `
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
$nic = Get-AzNetworkInterface -ResourceGroupName $nicResourceGroupName -Name $nicName
$vm = Add-AzVMNetworkInterface `
  -VM $vm `
  -Id $nic.Id
Write-Host "Network card $nicName attached"

$vm = Set-AzVMBootDiagnostic -VM $vm -Disable
$vm = Set-AzVMSecurityProfile -VM $vm -SecurityType "Standard"  # Prevents TrustedLaunch new default

Write-Host "Create the virtual machine $vmName"
New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vm -DisableBginfoExtension
Write-Host "Virtual machine $vmName created in scale set $vmssName"
