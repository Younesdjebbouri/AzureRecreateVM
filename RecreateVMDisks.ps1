param(
  [Parameter(Mandatory = $true)][string]$subscriptionID, #ex: 00000000-0000-0000-0000-000000000000
  [Parameter(Mandatory = $true)][string]$resourceGroupName, #ex: RG-TEST-VD-1-PRD
  [Parameter(Mandatory = $true)][string]$vmName, #ex: vm-test-1vm-test-vd-1-prd
  [string]$location = "sameAsOld",
  [string]$storageType = "sameAsOld", # for the new disks
  [Parameter(Mandatory = $true)][int]$zone = $null, # $null for no zone, otherwise: 1, 2, 3
  [string]$hypervgeneration = "V1"
)

$ErrorActionPreference = "Stop"

Set-AzContext -Subscription $subscriptionID | Out-Null

function CreateSnapshot($diskId, $name, $resourceGroupName, $location)
{
  Write-Host "Creating snapshot: $name"

  $snapshotConfig =  New-AzSnapshotConfig `
    -SourceUri $diskId `
    -Location $location `
    -AccountType Standard_LRS `
    -CreateOption copy

  New-AzSnapshot `
    -Snapshot $snapshotConfig `
    -SnapshotName $name `
    -ResourceGroupName $resourceGroupName | Out-Null

  Write-Host "Created snapshot: $name"
}

$vm = Get-AzVm -ResourceGroupName $resourceGroupName -Name $vmName
if ($location -eq "sameAsOld")
{
  $location = $vm.Location
}
$today = Get-Date -Format "yyyy-MM-dd_HHmm"

$osSnapshotsName = "osdisk-$($vmName.ToLower())-$today"
CreateSnapshot `
  -diskId $vm.StorageProfile.OsDisk.ManagedDisk.Id `
  -resourceGroupName $resourceGroupName `
  -location $location `
  -name $osSnapshotsName 
$i = 0
$dataSnapshotsName = @()
foreach ($dataDisk in $vm.StorageProfile.DataDisks)
{
  $dataSnapshotName = "datadisk-$($i+1)-$($vmName.ToLower())-$today"
  CreateSnapshot `
    -diskId $dataDisk.ManagedDisk.Id `
    -resourceGroupName $resourceGroupName `
    -location $location `
    -name $dataSnapshotName
  $dataSnapshotsName += $dataSnapshotName
  $i++
}


# --------------------------------------------------


function CreateDiskFromSnapshot($snapshotName, $resourceGroupName, $storageType, $location, $diskSize, $zone, $name, $isOS)
{
  Write-Host "Creating disk $name from snapshot: $snapshotName"

  $d = Get-AzDisk -ResourceGroupName $resourceGroupName -DiskName $name -ErrorAction Ignore
  if ($d)
  {
    Write-Error "Disk $name already exists :-/"
    return
  }

  $extraArgs = @{}

  if ($isOS)
  {
    $extraArgs["HyperVGeneration"] = $hypervgeneration
  }

  if ($zone)
  {
    $extraArgs["Zone"] = $zone
  }

  $snapshot = Get-AzSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $snapshotName
  $diskConfig = New-AzDiskConfig `
    -SkuName $storageType `
    -Location $location `
    -CreateOption Copy `
    -SourceResourceId $snapshot.Id `
    -DiskSizeGB $diskSize `
    @extraArgs

  New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroupName -DiskName $name | Out-Null
  Write-Host "Created disk: $name"
}

$osDisk = Get-AzDisk -ResourceGroupName $resourceGroupName -Name $vm.StorageProfile.OsDisk.Name
$osDiskSize = $osDisk.DiskSizeGB
if ($storageType -eq "sameAsOld")
{
  $osStorageType = $osDisk.Sku.Name
}
else
{
  $osStorageType = $storageType
}

if ($zone) { $suffix = "az$zone" }
else { $suffix = "no-az" }

$newOsDiskName = "osdisk-$($vmName.ToLower())-$suffix"
$newDataDisksName = @()

CreateDiskFromSnapshot `
  -snapshotName $osSnapshotsName `
  -resourceGroupName $resourceGroupName `
  -storageType $osStorageType `
  -location $location `
  -diskSize $osDiskSize `
  -zone $zone `
  -name $newOsDiskName `
  -isOS $true

$i = 0
foreach($snapshotName in $dataSnapshotsName)
{
  $dataDisk = Get-AzDisk -ResourceGroupName $resourceGroupName -Name $vm.StorageProfile.DataDisks[$i].Name
  $diskSize = $dataDisk.DiskSizeGB
  if ($storageType -eq "sameAsOld")
  {
    $dataStorageType = $dataDisk.Sku.Name
  }
  else
  {
    $dataStorageType = $storageType
  }

  if ($dataSnapshotsName.Count -gt 1)
  {
    $newDataDiskName = "datadisk$($i+1)-$($vmName.ToLower())-$suffix"
  }
  else
  {
    $newDataDiskName = "datadisk-$($vmName.ToLower())-$suffix"
  }
  
  $newDataDisksName += $newDataDiskName

  CreateDiskFromSnapshot `
    -snapshotName $snapshotName `
    -resourceGroupName $resourceGroupName `
    -storageType $dataStorageType `
    -location $location `
    -diskSize $diskSize `
    -zone $zone `
    -name $newDataDiskName `
    -isOS $false
  $i++
}

Write-Host "---"
Write-Host "Snapshots created by this script can now be removed by running:"
Write-Host "Remove-AzSnapshot -ResourceGroupName ""$resourceGroupName"" -SnapshotName ""$osSnapshotsName"""
foreach($snapshotName in $dataSnapshotsName)
{
  Write-Host "Remove-AzSnapshot -ResourceGroupName ""$resourceGroupName"" -SnapshotName ""$snapshotName"""
}
$res = @{
  OsDiskName = $newOsDiskName
  DataDisksName = $newDataDisksName
}
return $res
