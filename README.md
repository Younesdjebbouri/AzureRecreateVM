# AzureRecreateVM

Cette collection de scripts PowerShell a pour objectif de faciliter la recréation de machines virtuelles Azure. Elle permet notamment de recréer les disques d'une VM dans une zone de disponibilité, de réutiliser une carte réseau existante et de réintégrer la machine dans un Scale Set ou un Availability Set.

## Prérequis

- Azure PowerShell (module `Az`)
- Des droits suffisants sur l'abonnement cible

Avant d'exécuter les scripts, connectez-vous à votre abonnement :

```powershell
Connect-AzAccount
Select-AzSubscription -SubscriptionId <votre-ID-de-subscription>
```

## Scripts principaux

- **RecreateVM.ps1** : scénarise la récréation complète d'une VM dans un Scale Set zoné.
- **RecreateVM_WithoutScaleSet.ps1** : variante sans Scale Set.
- **RecreateVMDisks.ps1** : crée des snapshots puis de nouveaux disques (OS et data) dans la zone souhaitée.
- **RecreateVMFromDisksAndNic.ps1** : crée une VM à partir de disques et d'une carte réseau existants, avec gestion d'Availability Set et de Proximity Placement Group.
- **RecreateVMFromDisksAndNicInAZone.ps1** : même principe mais dans une zone de disponibilité précise.
- **RecreateVMFromDisksAndNicInAZonedScaleSet.ps1** : recrée la VM dans un Scale Set zoné.
- **RecreateVMFromDiskAndNicInAnotherScaleSet.ps1** : recrée la VM dans un autre Scale Set à partir des disques et de la carte réseau.
- **CheckResilience.ps1** : vérifie la résilience de l'infrastructure (zones, ASR, etc.).

## Exemple rapide

```powershell
# Recréation d'une VM en zone 1 au sein d'un Scale Set
./RecreateVM.ps1 -sid <subscriptionId> -rg <resourceGroup> -nicResourceGroupName <rg-nic> `
                -vmName <nomVM> -vmssName <nomScaleSet> -zone 1 -location francecentral
```

Chaque script dispose de paramètres commentés dans son en-tête. Exécutez `Get-Help <script>` pour obtenir le détail des options.

## Licence

Ces scripts sont fournis à titre d'exemple sans garantie.
