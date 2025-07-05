param(
  [Parameter(Mandatory = $true)][string]$sid, #ex: 00000000-0000-0000-0000-000000000000
  [Parameter(Mandatory = $true)][string]$rgName,
  $expected_location = "francecentral",
  $expected_primaryZone = 1,
  $expected_secondaryZone = 2,
  $asrFabricName = "test-francecentral-fabric",
  $asrProtectionContainer = "test-1-fc-source-container",
  [switch]$ignoreDiskNaming,
  [switch]$silenceSUCCESS
)

$ErrorActionPreference = "Stop"

Set-AzContext -Subscription $sid | Out-Null

# VM names should follow the pattern <prefix>-<role>-<environment>-<number>.
# Example: vm-front-prd-001. The role segment is used to group machines for
# resilience checks. Hyphens are allowed in Azure VM names.

$rg = Get-AzResourceGroup -ResourceGroupName $rgName
$rgLower = $rg.ResourceGroupName.ToLower()
$rgParts = $rgLower.Split("-")
$envType = $rgParts[2]
$environment = $rgParts[-1]
$project = $rgParts[-2]

# --------------------------------------------------

function WriteLog
{
  param (
    [string]$message,
    [string][ValidateSet('INFO','WARN','ERROR','SUCCESS')]$type
  )
  if ($type -eq "SUCCESS" -and $silenceSUCCESS)
  {
    return
  }
  $typeStr = ""
  if ($type) { $typeStr = "[" + $type + "] " }
  switch ($type)
  {
    "INFO" { $color = "Blue" }
    "WARN" { $color = "Yellow" }
    "ERROR" { $color = "Red" }
    "SUCCESS" { $color = "Green" }
    default { $color = "White" }
  }
  $log = $typeStr + $message
  Write-Host $log -ForegroundColor $color
}

function CheckLocation($loc, $desc)
{
  if ($loc -ine $expected_location)
  {
    WriteLog "Location $loc is invalid, expected $expected_location for $desc" ERROR
  }
}

function ShouldHave2InstancesAtLeast($vms, $desc)
{
  if ($vms.Count -eq 0)
  {
    WriteLog "List of $desc VMs is empty!" ERROR
  }
  elseif ($vms.Count -eq 1)
  {
    if ($envType -eq "pr")
    {
      WriteLog "List of $desc VMs is composed of only 1 VM: SPOF" ERROR
    }
    else
    {
      WriteLog "List of $desc VMs is composed of only 1 VM: no HA" WARN
    }
  }
  else
  {
    WriteLog "List of $desc VMs is composed of at least 2 VMs" SUCCESS
  }
}

function ShouldBeHalfInPrimaryZoneHalfInSecondaryZone($vms, $desc)
{
  $groups = $vms | Group-Object -Property {if ($_.Zones.Count -gt 0) {$_.Zones -join ","} else {"NO AZ"}}
  if ($groups.Name.Count -eq 2)
  {
    if (
      (($groups[0].Name -eq $expected_primaryZone) -and ($groups[1].Name -eq $expected_secondaryZone)) -or
      (($groups[0].Name -eq $expected_secondaryZone) -and ($groups[1].Name -eq $expected_primaryZone))
    )
    {
      WriteLog "VMs $desc are in the appropriate zones $expected_primaryZone and $expected_secondaryZone" SUCCESS
    }
    elseif (($groups[0].Name -eq $expected_primaryZone) -and ($groups[1].Name -ne $expected_secondaryZone))
    {
      $names = $groups[1].Group.Name -join ","
      $prefix = if ($groups[1].Count -gt 1) {"VMs $names are"} else {"VM $names is"}
      WriteLog "$prefix in zone $($groups[1].Name), but expected to be in zone $expected_secondaryZone" ERROR
    }
    elseif (($groups[0].Name -eq $expected_secondaryZone) -and ($groups[1].Name -ne $expected_primaryZone))
    {
      $names = $groups[1].Group.Name -join ","
      $prefix = if ($groups[1].Count -gt 1) {"VMs $names are"} else {"VM $names is"}
      WriteLog "$prefix in zone $($groups[1].Name), but expected to be in zone $expected_primaryZone" ERROR
    }

    if ($groups[0].Name -eq "NO AZ")
    {
      $names = $groups[0].Group.Name -join ","
      $prefix = if ($groups[0].Count -gt 1) {"VMs $names"} else {"VM $names"}
      WriteLog "$prefix should be pinned to availability zone $expected_primaryZone" ERROR
    }
    if ($groups[1].Name -eq "NO AZ")
    {
      $names = $groups[1].Group.Name -join ","
      $prefix = if ($groups[1].Count -gt 1) {"VMs $names"} else {"VM $names"}
      WriteLog "$prefix should be pinned to availability zone $expected_secondaryZone" ERROR
    }

    # On vérifie l'équilibrage des 2 groupes
    # if ([Math]::Abs($groups[0].Count - $groups[1].Count) -gt 1) # si on veut gérer un nombre impair
    if ($groups[0].Count -eq $groups[1].Count)
    {
      WriteLog "VMs $desc are equally splitted between zones $expected_primaryZone and $expected_secondaryZone" SUCCESS
    }
    else
    {
      $names = $vms.Name -join ","
      WriteLog "VMs $desc ($names) are not properly spread between zones $expected_primaryZone and $expected_secondaryZone" ERROR
    }
  }
  elseif ($vms.Count -gt 1)
  {
    $names = $vms.Name -join ","
    WriteLog "VMs $desc ($names) are not properly spread across zones $expected_primaryZone and $expected_secondaryZone" ERROR
  }
}

function ShouldBeSameSize($vms, $desc)
{
  if ($vms.Count -eq 0)
  {
    # Already handled in ShouldHave2InstancesAtLeast
    return # Prevent error message when no vm in list
  }
  $names = $vms.Name -join ","
  $groups = $vms | Group-Object -Property {$_.HardwareProfile.VmSize}
  if ($groups.Name.Count -ne 1)
  {
    WriteLog "VMs $desc ($names) don't have the same size" ERROR
  }
  else
  {
    WriteLog "VMs $desc ($names) have the same size $($groups.Name)" SUCCESS
  }
}

function CheckVMDisk($disk, $vmName, $prefix, $suffix)
{
  # Check disk naming
  $expected = "$prefix-$($vmName.ToLower())$suffix"
  if (-not $ignoreDiskNaming)
  {
    if ($disk.Name -eq $expected)
    {
      WriteLog "Disk $($disk.Name) name is ok" SUCCESS
    }
    else
    {
      WriteLog "Disk $($disk.Name) should be named: $expected" WARN
    }
  }

  $StorageAccountType = $disk.ManagedDisk.StorageAccountType
  if ($null -eq $StorageAccountType)
  {
    # VM is likely stopped
    $realDisk = Get-AzDisk -Name $disk.Name -ResourceGroupName $rgName
    $StorageAccountType = $realDisk.Sku.Name
  }

  # Check performance
  if ($prefix -eq "osdisk")
  {
    if ($StorageAccountType -eq "Premium_LRS")
    {
      WriteLog "OSDisk $($disk.Name) performance is Premium_LRS" SUCCESS
    }
    else
    {
      WriteLog "OSDisk $($disk.Name) has storage type $StorageAccountType, expected: Premium_LRS" ERROR
    }
  }
  if ($prefix -eq "datadisk" -and $environment -eq "prd" -and $StorageAccountType -ne "Premium_LRS")
  {
    WriteLog "Data Disk $($disk.Name) should have storage type: Premium_LRS in prd environment" WARN
  }

  # Check host caching
  if ($prefix -eq "osdisk")
  {
    if ($disk.Caching -eq "ReadWrite")
    {
      WriteLog "OSDisk $($disk.Name) has host caching: ReadWrite" SUCCESS
    }
    else
    {
      WriteLog "OSDisk $($disk.Name) should have host caching: ReadWrite" ERROR
    }
  }
  elseif ($prefix -eq "datadisk" -and $disk.Caching -eq "ReadWrite")
  {
    WriteLog "Data Disk $($disk.Name) should probably NOT use ReadWrite host caching" ERROR
  }
}

function CheckVMNetworking($vm, $possibleNics)
{
  $i = 0
  foreach($nicId in $vm.NetworkProfile.NetworkInterfaces.Id)
  {
    $i++
    #$nic = Get-AzNetworkInterface -ResourceId $nicId # slow overall (1 request for each vm)
    $nic = $possibleNics | Where-Object Id -eq $nicId
    if ($null -eq $nic)
    {
      WriteLog "Nic $i not found, probably in wrong resource group" WARN
      continue
    }

    $expected = "nic$i-$($vm.Name.ToLower())"
    if ($nic.Name -eq $expected)
    {
      WriteLog "Nic $i ($($nic.Name)) name is ok" SUCCESS
    }
    else
    {
      WriteLog "Nic $i ($($nic.Name)) should be named: $expected" WARN
    }

    if ($nic.EnableAcceleratedNetworking -eq $True)
    {
      WriteLog "Nic $($nic.Name) has accelerated networking enabled" SUCCESS
    }
    else
    {
      # 1 vCPU machines can't have accelerated networking
      if ($vm.HardwareProfile.VmSize -ne "Standard_DS1_v2")
      {
        WriteLog "Nic $($nic.Name) should have accelerated networking enabled" ERROR
      }
    }

    if ($null -eq $nic.NetworkSecurityGroup.Id)
    {
      WriteLog "Nic $($nic.Name) should be associated to an NSG" ERROR
    }
    else
    {
      WriteLog "Nic $($nic.Name) is associated to an NSG" SUCCESS
    }

    $firstIPConfig = $nic.IpConfigurations[0]
    $expected = "nic$i"
    if ($firstIPConfig.Name -eq $expected)
    {
      WriteLog "Nic $($nic.Name) first ip configuration ($($firstIPConfig.Name)) name is ok" SUCCESS
    }
    else
    {
      WriteLog "Nic $($nic.Name) first ip configuration ($($firstIPConfig.Name)) should be named: $expected" WARN
    }

    if ($firstIPConfig.ApplicationSecurityGroups.Count -eq 0)
    {
      WriteLog "Nic $($nic.Name) first ip configuration should have at least one ASG" WARN
    }
    else
    {
      WriteLog "Nic $($nic.Name) first ip configuration has at least one ASG" SUCCESS
    }
  }
}

function CheckVMInSameScaleSet($vms, $desc)
{
  if ($vms.Count -eq 0)
  {
    # Already handled in ShouldHave2InstancesAtLeast
    return # Prevent error message when no vm in list
  }

  $groups = $vms | Group-Object -Property {$_.VirtualMachineScaleSet.Id} -NoElement
  $names = $vms.Name -join ","
  if ($groups.Name.Count -eq 1)
  {
    if ($groups[0].Name -eq "")
    {
      if ($vms.Count -gt 1)
      {
        WriteLog "None of $desc VMs ($names) are in a scale set" ERROR
      }
      else
      {
        # Already displayed before CheckVMInSameScaleSet calls
        # WriteLog "VM $desc ($names) is not in a scale set" WARN
      }
    }
    else
    {
      $scaleSetName = $vms[0].VirtualMachineScaleSet.Id.Split("/")[-1]
      WriteLog "VMs $desc ($names) are all in the same scale set $scaleSetName" SUCCESS
    }
  }
  else
  {
    WriteLog "VMs $desc ($names) should be in the same scale set" ERROR
  }
}

function CheckASRVMs($RPIs, $vms)
{
  foreach ($vm in $vms)
  {
    $RPI = $RPIs | Where-Object FriendlyName -eq $vm.Name
    if ($null -eq $RPI)
    {
      WriteLog "$($vm.Name) is not registered in Azure Site Recovery" ERROR
    }
    else
    {
      WriteLog "$($vm.Name) is registered in Azure Site Recovery" SUCCESS

      $hasASRextension = ($vm.Extensions | Where-Object {$_.Id.EndsWith("SiteRecovery-Windows")}).Count -eq 1
      if ($hasASRextension)
      {
        WriteLog "$($vm.Name) has extension: SiteRecovery-Windows" SUCCESS
      }
      else
      {
        WriteLog "$($vm.Name) should have extension: SiteRecovery-Windows" WARN
      }

      # Check capacity reservation in ASR
      if ($environment -eq "prd")
      {
        if ($null -eq $RPI.ProviderSpecificDetails.RecoveryCapacityReservationGroupId)
        {
          WriteLog "$($vm.Name) is not associated to a capacity reservation group in Azure Site Recovery" ERROR
        }
        else
        {
          $crg = $RPI.ProviderSpecificDetails.RecoveryCapacityReservationGroupId.Split("/")[-1]
          WriteLog "$($vm.Name) is associated to capacity reservation group $crg in Azure Site Recovery" SUCCESS
        }
      }
      # Check the last successfull test failover time.
      if($null -eq $RPI.LastSuccessfulTestFailoverTime)
      {
        WriteLog "Test failover has not yet been executed on the vm : $($vm.name)" ERROR
      }
      else
      {
        $TimeSinceLastTfo = (New-TimeSpan -Start ($RPI.LastSuccessfulTestFailoverTime) -End (get-date)).Days
        if ($TimeSinceLastTfo -gt 180)
        {
          WriteLog "$($vm.Name) lastest failover has been done over 180 days ago, you must execute a new one" ERROR
        }
        else
        {
          WriteLog "$($vm.Name) lastest failover has been done on $($RPI.LastSuccessfulTestFailoverTime) (less than 180 days ago)" SUCCESS
        }
      }
      
    }
  }
}

# --------------------------------------------------
function Get-VMRole($vmName)
{
  $parts = $vmName.ToLower().Split('-')
  if ($parts.Count -ge 2)
  {
    return $parts[1]
  }
  return $null
}

WriteLog "Environment: $environment" INFO
WriteLog "Environment type: $envType" INFO
WriteLog "Project: $project" INFO

CheckLocation $rg.Location "resource group $rgName"
# --------------------------------------------------
$vms_database = @()
$vms_frontend = @()

WriteLog "Fetching VMs infos..."
$vms = Get-AzVm -ResourceGroupName $rgName
$nics = Get-AzNetworkInterface -ResourceGroupName $rgName

WriteLog "Grouping machines"
foreach($vm in $vms)
{
  $role = Get-VMRole $vm.Name
  switch ($role)
  {
    "db"    { $vms_database += $vm }
    "front" { $vms_frontend += $vm }
  }
}
# --------------------------------------------------
WriteLog "database: $($vms_database.Name -join ' ')" INFO
WriteLog "frontend: $($vms_frontend.Name -join ' ')" INFO
# --------------------------------------------------

# --------------------------------------------------

WriteLog "Checking Availability Zone & HA"
$shouldBeInPrimaryZone = $vms_frontend + $vms_database
foreach ($vm in $shouldBeInPrimaryZone)
{
  if ($vm.Zones.Count -eq 1 -and $vm.Zones[0] -eq $expected_primaryZone)
  {
    WriteLog "VM $($vm.Name) is in zone $expected_primaryZone" SUCCESS
  }
  elseif ($vm.Zones.Count -ne 1 -or $vm.Zones[0] -ne $expected_primaryZone)
  {
    WriteLog "VM $($vm.Name) is in zone $($vm.Zones), but expected to be in zone $expected_primaryZone" ERROR
  }
}
ShouldHave2InstancesAtLeast $vms_database "databases"
ShouldHave2InstancesAtLeast $vms_frontend "frontend"
ShouldBeHalfInPrimaryZoneHalfInSecondaryZone $vms_database "databases"
ShouldBeHalfInPrimaryZoneHalfInSecondaryZone $vms_frontend "frontend"

# --------------------------------------------------

WriteLog "Checking VMs size..."

ShouldBeSameSize $vms_database "databases"
ShouldBeSameSize $vms_frontend "frontend"

# --------------------------------------------------

WriteLog "Checking VMs infos..."
foreach($vm in $vms)
{
  CheckLocation $vm.Location "vm $($vm.Name)"

  # Check storage
  $suffix =  "-az$($vm.Zones[0])"
  CheckVMDisk $vm.StorageProfile.OsDisk $vm.Name "osdisk" $suffix
  $i = 0
  foreach($dataDisk in $vm.StorageProfile.DataDisks)
  {
    $i++
    if ($i -eq 1) {$prefix = "datadisk"} # most vm have 1 datadisk, without number
    else {$prefix = "datadisk$i"}
    CheckVMDisk $dataDisk $vm.Name $prefix $suffix
  }

  CheckVMNetworking $vm $nics
}

# --------------------------------------------------

WriteLog "Check Scale Set for max spreading in same zone"
foreach ($vm in $vms_frontend)
{
  if ($null -eq $vm.VirtualMachineScaleSet.Id)
  {
    $level = "ERROR"
    if ($envType -eq "np" -and $vms_frontend.Count -eq 1) { $level = "WARN" }
    WriteLog "VM $($vm.Name) should be in a scale set" $level
  }
  else
  {
    WriteLog "VM $($vm.Name) is in a scale set" SUCCESS
  }
}
CheckVMInSameScaleSet $vms_frontend "frontend"

# --------------------------------------------------

WriteLog "Check VM Backup"

$vaultCache = @{}
$vaultBackupPropertyCache = @{}
foreach($vm in $vms)
{
  $backupStatus = Get-AzRecoveryServicesBackupStatus -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Type AzureVM
  if ($backupStatus.BackedUp)
  {
    $parts = $backupStatus.VaultId.Split("/")
    $vaultName = $parts[-1]
    $vaultRg = $parts[4]
    WriteLog "VM $($vm.Name) is backed up (vault = $vaultName)" SUCCESS

    if ($vaultCache.ContainsKey($vaultName))
    {
      $vault = $vaultCache[$vaultName]
      $vaultBackup = $vaultBackupPropertyCache[$vaultName]
    }
    else
    {
      $vault = $vaultCache[$vaultName] = Get-AzRecoveryServicesVault -ResourceGroupName $vaultRg -Name $vaultName
      $vaultBackup = $vaultBackupPropertyCache[$vaultName] = Get-AzRecoveryServicesBackupProperty -Vault $vault
    }

    if ($vaultBackup.BackupStorageRedundancy -eq "LocallyRedundant")
    {
      WriteLog "VM $($vm.Name) is backed up in an LRS vault, should be ZRS or GRS" ERROR
    }
    else
    {
      WriteLog "VM $($vm.Name) is backed up in a $($vaultBackup.BackupStorageRedundancy) vault" SUCCESS
    }

    # Quite slow thus commented out
    # $Container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -VaultId $vault.ID -FriendlyName $vm.Name
    # $BackupItem = Get-AzRecoveryServicesBackupItem -Container $Container -WorkloadType AzureVM -VaultId $vault.ID
    # if ($BackupItem.ProtectionState -eq "Protected")
    # {
    #   WriteLog "VM $($vm.Name) protection status in the vault is ok" SUCCESS
    # }
    # else
    # {
    #   WriteLog "VM $($vm.Name) protection status is: $($BackupItem.ProtectionState)" WARN
    # }

    # if ($BackupItem.LastBackupTime -lt (Get-Date).AddDays(-2))
    # {
    #   WriteLog "VM $($vm.Name) last backup is more than 48H ago: $($BackupItem.LastBackupTime)" ERROR
    # }
    # else
    # {
    #   WriteLog "VM $($vm.Name) last backup is less than 48H ago: $($BackupItem.LastBackupTime)" SUCCESS
    # }
  }
  else
  {
    WriteLog "VM $($vm.Name) is NOT backed up" ERROR
  }
}

# --------------------------------------------------

$useASR = ($envType -eq "pr") -or ($environment -in @("prf", "int"))
if ($useASR)
{
  WriteLog "Check ASR architecture"

  $rgInfraASRName = "rg-asr-e2-$envType-$project-app"
  $rgInfraASR = Get-AzResourceGroup -ResourceGroupName $rgInfraASRName -ErrorAction Ignore
  if ($null -eq $rgInfraASR)
  {
    WriteLog "Resource group $rgInfraASRName for Azure Site Recovery infrastructure does not exist" ERROR
  }

  $rgSecondaryName = "rg-e2-$envType-asr-$project-$environment"
  $rgSecondary = Get-AzResourceGroup -ResourceGroupName $rgSecondaryName -ErrorAction Ignore
  if ($null -eq $rgSecondary)
  {
    WriteLog "Secondary resource group $rgSecondaryName for Azure Site Recovery usage does not exist" ERROR
  }

  if ($rgInfraASR)
  {
    $rsv = Get-AzRecoveryServicesVault -ResourceGroupName $rgInfraASRName
    if ($rsv.Count -eq 0)
    {
      WriteLog "Recovery Services vault not found in $rgInfraASRName resource group" ERROR
    }
    elseif ($rsv.Count -gt 1)
    {
      $rsv = $rsv[0]
      WriteLog "Several Recovery Services vault found in $rgInfraASRName resource group, using first one: $($rsv.Name)" WARN
    }
    else
    {
      WriteLog "Found Recovery Services vault: $($rsv.Name)" SUCCESS
    }

    if ($rsv)
    {
      Set-AzRecoveryServicesAsrVaultContext -Vault $rsv | Out-Null
      $PrimaryFabric = Get-AzRecoveryServicesAsrFabric -Name $asrFabricName
      if ($PrimaryFabric.Count -ne 1)
      {
        WriteLog "Fabric $asrFabricName not found in Recovery Services vault $($rsv.Name)" ERROR
      }
      else
      {
        $ProtContainer = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $PrimaryFabric -Name $asrProtectionContainer
        if ($ProtContainer.Count -ne 1)
        {
          WriteLog "Protection container $asrProtectionContainer not found in fabric $asrFabricName" ERROR
        }
        else
        {
          WriteLog "Listing ASR Protected Items"
          $RPIs = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $ProtContainer

          $shouldBeInASR = $vms_frontend + $vms_database
          CheckASRVMs $RPIs $shouldBeInASR
        }
      }
    }
  }
}
