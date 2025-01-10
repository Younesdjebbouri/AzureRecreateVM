param(
    [Parameter(Mandatory = $true)][string]$subscriptionID,
    [Parameter(Mandatory = $true)][string]$resourceGroupName,
    [Parameter(Mandatory = $true)][string]$vmName,
    [Parameter(Mandatory = $true)][string]$nicName,
    [Parameter(Mandatory = $true)][string]$nicResourceGroupName,
    [Parameter(Mandatory = $true)][string]$location,
    [Parameter(Mandatory = $true)][string]$size,
    [Parameter(Mandatory = $true)][string]$osDiskName,
    [string[]]$dataDisksName,
    [Parameter(Mandatory = $true)][string]$zone,
    [Parameter(Mandatory = $true)][string]$vmssName,
    [hashtable]$tags = @{},
    [bool]$windows = $true,
    [bool]$onPremiseLicense = $true
)

$ErrorActionPreference = "Stop"
Set-AzContext -Subscription $subscriptionID | Out-Null

# Vérifications
$vm = Get-AzVm -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Ignore
if ($vm) {
    Write-Error "La VM $vmName existe déjà dans $resourceGroupName !!"
    Exit 1
}

$vmss = Get-AzVmss -ResourceGroupName $resourceGroupName -Name $vmssName -ErrorAction Stop
if ($vmss.Zones[0] -ne $zone) {
    Write-Error "Le Scale Set n'est pas dans la même zone que celle spécifiée pour la VM"
    Exit 2
}

if ($vmss.Location.ToLower() -ne $location.ToLower()) {
    Write-Error "Le Scale Set n'est pas dans la même région que celle spécifiée pour la VM"
    Exit 2
}

function GetDisk($resourceGroupName, $diskName) {
    $disk = Get-AzDisk -ResourceGroupName $resourceGroupName -DiskName $diskName
    if ($null -eq $disk) {
        Write-Error "Le disque $diskName n'existe pas"
        Exit 3
    } else {
        Write-Host "Disque récupéré : $diskName"
    }
    if ($null -ne $disk.ManagedBy) {
        Write-Error "Le disque $diskName est déjà attaché à $($disk.ManagedBy.Split("/")[-1])"
        Exit 4
    }
    return $disk
}

Write-Host "Création de la configuration de la machine virtuelle"
$extraArgs = @{}
if ($onPremiseLicense -and $windows) {$extraArgs = @{LicenseType = "Windows_Server"}}

$vm = New-AzVMConfig `
    -VMName $vmName `
    -VMSize $size `
    -Zone $zone `
    -VmssId $vmss.Id `
    -Tags $tags `
    @extraArgs

Write-Host "Attachement du disque OS : $osDiskName"
$osDisk = GetDisk $resourceGroupName $osDiskName

if ($windows) {
    $extraArgs = @{Windows = $true}
} else {
    $extraArgs = @{Linux = $true}
}

$vm = Set-AzVMOSDisk `
    -VM $vm `
    -ManagedDiskId $osDisk.Id `
    -CreateOption Attach `
    -Caching ReadWrite `
    @extraArgs

Write-Host "Disque OS $osDiskName attaché"

if ($dataDisksName) {
    Write-Host "Attachement des disques de données"
    $lun = 0
    foreach ($dataDiskName in $dataDisksName) {
        $dataDisk = GetDisk $resourceGroupName $dataDiskName
        $dataDiskCaching = "ReadOnly"
        if ($dataDisk.DiskSizeGB -gt 4095) {
            $dataDiskCaching = "None"
        }
        $vm = Add-AzVMDataDisk `
            -VM $vm `
            -Name $dataDiskName `
            -ManagedDiskId $dataDisk.Id `
            -CreateOption Attach `
            -Lun $lun `
            -Caching $dataDiskCaching
        Write-Host "Disque de données $dataDiskName attaché"
        $lun++
    }
}

Write-Host "Attachement de la carte réseau $nicName"
$nic = Get-AzNetworkInterface -ResourceGroupName $nicResourceGroupName -Name $nicName
$vm = Add-AzVMNetworkInterface `
    -VM $vm `
    -Id $nic.Id

Write-Host "Carte réseau $nicName attachée"

$vm = Set-AzVMBootDiagnostic -VM $vm -Disable
$vm = Set-AzVMSecurityProfile -VM $vm -SecurityType "Standard"

Write-Host "Création de la machine virtuelle $vmName"
New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vm -DisableBginfoExtension

Write-Host "Machine virtuelle $vmName créée dans le scale set $vmssName avec la nouvelle taille $size"
