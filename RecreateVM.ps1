param(
    [Parameter(Mandatory = $true)][string]$sid,
    [Parameter(Mandatory = $true)][string]$rg,
    [Parameter(Mandatory = $true)][string]$nicResourceGroupName,
    [Parameter(Mandatory = $true)][string]$vmName,
    [Parameter(Mandatory = $true)][string]$vmssName,
    [string]$location = "francecentral",
    [string]$zone = 1,
    [string]$newSize # Nouveau paramètre pour spécifier la nouvelle taille AS
)

$ErrorActionPreference = "Stop"
Set-AzContext -Subscription $sid | Out-Null

$vm = Get-AzVm -ResourceGroupName $rg -Name $vmName
$oldSize = $vm.HardwareProfile.VmSize

# Vérification de l'existence du vmss
Get-AzVmss -ResourceGroupName $rg -Name $vmssName -ErrorAction Stop

Write-Host "Arrêt de la VM $vmName"
Stop-AzVM -ResourceGroupName $rg -Name $vmName -Force

Write-Host "Recréation de disques dans la zone $zone"
$res = .\RecreateVMDisks.ps1 -subscriptionID $sid -resourceGroupName $rg -vmName $vmName -zone $zone

$nic1 = $vm.NetworkProfile.NetworkInterfaces[0]
$nicName = $nic1.Id.Split('/')[-1]
$osDiskName = $res.OsDiskName
$dataDisksName = $res.DataDisksName

Write-Host "Suppression de la VM en conservant les disques et la carte réseau"
Remove-AzVM -ResourceGroupName $rg -Name $vmName -Force

Write-Host "Recréation de la VM dans la zone $zone et le scale set $vmssName avec la nouvelle taille $newSize"
.\RecreateVMFromDisksAndNicInAZonedScaleSet.ps1 `
    -subscriptionID $sid `
    -resourceGroupName $rg `
    -nicResourceGroupName $nicResourceGroupName `
    -vmName $vmName `
    -nicName $nicName `
    -location $location `
    -size $newSize `
    -osDiskName $osDiskName `
    -dataDisksName $dataDisksName `
    -zone $zone `
    -vmssName $vmssName

Write-Host "Migration de la VM $vmName de $oldSize vers $newSize terminée avec succès"
