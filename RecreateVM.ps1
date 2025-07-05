param(
  [Parameter(Mandatory = $true)][string]$sid, #ex: 00000000-0000-0000-0000-000000000000
  [Parameter(Mandatory = $true)][string]$rg, #ex: RG-APP-DEV-01
  [Parameter(Mandatory = $true)][string]$nicResourceGroupName ,
  [Parameter(Mandatory = $true)][string]$vmName, #ex: vm-app-test-01
  [Parameter(Mandatory = $true)][string]$vmssName, # Scale Set name, ex: vmss1
  [string]$location = "francecentral",
  [string]$zone = 1 # Destination zone
)

$ErrorActionPreference = "Stop"

Set-AzContext -Subscription $sid | Out-Null

$vm = Get-AzVm -ResourceGroupName $rg -Name $vmName

# Check vmss existence immediately to avoid error in middle of script after vm is removed
Get-AzVmss -ResourceGroupName $rg -Name $vmssName -ErrorAction Stop

Write-Host "Arrêt de la VM $vmName"
Stop-AzVM -ResourceGroupName $rg -Name $vmName

Write-Host "Recréation de disques dans la zone $zone"
$res = .\RecreateVMDisks.ps1 -subscriptionID $sid -resourceGroupName $rg -vmName $vmName -zone $zone
Write-Host "Fin du script de recréation des disques"

$nic1 = $vm.NetworkProfile.NetworkInterfaces[0]
$nicName = $nic1.Id.Split('/')[-1]
$size = $vm.HardwareProfile.VmSize

$osDiskName = $res.OsDiskName
$dataDisksName = $res.DataDisksName

Write-Host "La script va désormais supprimer la VM, tout en gardant les disques et la carte réseau"
Remove-AzVM -ResourceGroupName $rg -Name $vmName  # Asks for confirmation
Write-Host "VM $vmName supprimée"

Write-Host "Recréation de la VM dans la zone $zone et le scale set $vmssName"
.\RecreateVMFromDisksAndNicInAZonedScaleSet.ps1 `
  -subscriptionID $sid `
  -resourceGroupName $rg `
  -nicResourceGroupName $nicResourceGroupName `
  -vmName $vmName `
  -nicName $nicName `
  -location $location `
  -size $size `
  -osDiskName $osDiskName `
  -dataDisksName $dataDisksName `
  -zone $zone `
  -vmssName $vmssName
  -tags $tags
