

param(
    [string]$CsvPath = ".\vm-migration-input.csv"
)

# Import CSV
$vmsToMigrate = Import-Csv -Path $CsvPath

# Array to store results for export
$results = @()

foreach ($vm in $vmsToMigrate) {
    $status = "Unknown"
    $message = ""

    Write-Host "Processing VM: $($vm.VMName) in RG: $($vm.ResourceGroup)" -ForegroundColor Cyan

    try {
        # Set subscription context
        Set-AzContext -SubscriptionId $vm.SubscriptionId | Out-Null

        # -------------------------------
        # Step 1: Old Vault Lookup
        # -------------------------------
        $oldVault = Get-AzRecoveryServicesVault -Name $vm.OldVault -ResourceGroupName $vm.OldVaultRG -ErrorAction SilentlyContinue
        if (-not $oldVault) {
            Write-Warning "Old Vault $($vm.OldVault) not found. Continuing with new vault registration..."
        } else {
            Set-AzRecoveryServicesVaultContext -Vault $oldVault

            # Check Soft Delete
            $vaultProps = Get-AzRecoveryServicesVaultProperty -VaultId $oldVault.ID
            if ($vaultProps.SoftDeleteFeatureState -ne "Enabled") {
                Write-Warning "Soft Delete is not enabled on $($vm.OldVault). Please enable manually."
            }

            # -------------------------------
            # Step 2: Stop backup & delete recovery points
            # -------------------------------
            $container = Get-AzRecoveryServicesBackupContainer -ContainerType "AzureVM" -FriendlyName $vm.VMName -VaultId $oldVault.ID
            if ($container) {
                $backupItem = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType "AzureVM" -VaultId $oldVault.ID
                if ($backupItem) {
                    Disable-AzRecoveryServicesBackupProtection -Item $backupItem -RemoveRecoveryPoints -VaultId $oldVault.ID -Force
                    Write-Host "Stopped and deleted backup data for VM: $($vm.VMName)" -ForegroundColor Yellow
                } else {
                    Write-Host "No backup item found for VM: $($vm.VMName)" -ForegroundColor Gray
                }
            } else {
                Write-Warning "VM $($vm.VMName) not registered in old vault."
            }
        }

        # -------------------------------
        # Step 3: Register VM with New Vault
        # -------------------------------
        $newVault = Get-AzRecoveryServicesVault -Name $vm.NewVault -ResourceGroupName $vm.NewVaultRG -ErrorAction SilentlyContinue
        if (-not $newVault) {
            $status = "Failed"
            $message = "New Vault $($vm.NewVault) not found"
            throw $message
        }
        Set-AzRecoveryServicesVaultContext -Vault $newVault

        # Find Policy by Name + AzureVM type
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $newVault.ID | Where-Object {
            $_.Name -eq $vm.PolicyName -and $_.BackupManagementType -eq "AzureVM"
        }

        if (-not $policy) {
            $status = "Failed"
            $message = "Policy $($vm.PolicyName) not found in new vault"
            throw $message
        }

        # Enable backup protection
        $vmResource = Get-AzVM -Name $vm.VMName -ResourceGroupName $vm.ResourceGroup -ErrorAction Stop
        Enable-AzRecoveryServicesBackupProtection -Policy $policy -Name $vmResource.Name -ResourceGroupName $vmResource.ResourceGroupName
        Write-Host "Enabled protection for VM: $($vm.VMName) with policy $($policy.Name)" -ForegroundColor Green

        $status = "Success"
        $message = "VM registered and backup enabled in new vault"

    } catch {
        if ($status -eq "Unknown") {
            $status = "Failed"
            $message = $_.Exception.Message
        }
    }

    # Collect result
    $results += [PSCustomObject]@{
        VMName        = $vm.VMName
        ResourceGroup = $vm.ResourceGroup
        OldVault      = $vm.OldVault
        OldVaultRG    = $vm.OldVaultRG
        NewVault      = $vm.NewVault
        NewVaultRG    = $vm.NewVaultRG
        PolicyName    = $vm.PolicyName
        Status        = $status
        Message       = $message
    }
}

# Export results
$exportPath = "C:\Powershellscripts\RSV-Migration\Migration-Report.csv"
$results | Export-Csv -Path $exportPath -NoTypeInformation

Write-Host "VM Migration Script Completed! Report saved to $exportPath" -ForegroundColor Magenta
