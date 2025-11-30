param(
    [string]$CsvPath = ".\sql-vm-migration-input.csv"
)

# Import VM details from CSV
$vms = Import-Csv -Path $CsvPath
$report = @()

foreach ($vm in $vms) {
    Write-Host "Processing VM: $($vm.VMName)" -ForegroundColor Cyan
    try {
        # Set subscription
        Set-AzContext -SubscriptionId $vm.SubscriptionId | Out-Null

        # Get Recovery Services Vault
        $oldVault = Get-AzRecoveryServicesVault -Name $vm.OldVault -ResourceGroupName $vm.OldVaultRG
        Set-AzRecoveryServicesVaultContext -Vault $oldVault

        # Get all MSSQL backup items in the vault
        $backupItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL | Where-Object {
            $_.SourceResourceId -like "*$($vm.VMName)*"
        }

        if (-not $backupItems -or $backupItems.Count -eq 0) {
            Write-Warning "No SQL (MSSQL) backup items found for VM $($vm.VMName)"
            $report += [PSCustomObject]@{
                VMName = $vm.VMName
                Status = "Skipped"
                Message = "No SQL backups found"
            }
            continue
        }

        # Loop through all DB backup items
        foreach ($item in $backupItems) {
            Write-Host "Stopping backup for DB: $($item.FriendlyName)" -ForegroundColor Yellow

            # Disable backup but keep recovery points
            Disable-AzRecoveryServicesBackupProtection -Item $item -Force
        }

        $report += [PSCustomObject]@{
            VMName = $vm.VMName
            Status = "Success"
            Message = "Disabled backup for $($backupItems.Count) SQL DB(s)"
        }

    } catch {
        Write-Host "Error processing $($vm.VMName): $($_.Exception.Message)" -ForegroundColor Red
        $report += [PSCustomObject]@{
            VMName = $vm.VMName
            Status = "Failed"
            Message = $_.Exception.Message
        }
    }
}

# Export report
$report | Export-Csv -Path ".\StopSQLBackupReport.csv" -NoTypeInformation
Write-Host "Done! Report saved to .\StopSQLBackupReport.csv" -ForegroundColor Green
