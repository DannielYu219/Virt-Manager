param([switch]$RestartAgent)
$ErrorActionPreference = 'Continue'
Write-Host '=== Windows SPICE clipboard diagnosis ==='
Write-Host 'A tray icon is not required. The service and a per-user vdagent process are required.'
$services = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'spice|vdagent' -or $_.PathName -match 'vdservice' })
$services | Select-Object Name, State, StartMode, PathName | Format-List
if ($services.Count -eq 0) { Write-Warning 'SPICE service not installed. Repair the SPICE agent component using the bundled UTM Guest Tools installer.' }
if ($RestartAgent) {
    foreach ($service in $services) {
        try {
            Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop
            Restart-Service -Name $service.Name -ErrorAction Stop
            Write-Host "Restarted $($service.Name)"
        } catch { Write-Warning "Service restart failed (Administrator rights required): $_" }
    }
    Start-Sleep -Seconds 2
}
Write-Host '=== Agent processes and session IDs ==='
Get-Process vdagent,vdservice -ErrorAction SilentlyContinue | Select-Object Name, Id, SessionId, Path | Format-Table -AutoSize
Write-Host '=== VirtIO serial driver ==='
Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'VirtIO.*Serial|VirtIO.*Port|SPICE' } | Select-Object Name, Status, ConfigManagerErrorCode | Format-Table -AutoSize
Write-Host '=== Current Windows session ==='
Get-Process -Id $PID | Select-Object Id, SessionId | Format-Table
Write-Host 'If vdservice is running but no vdagent exists in the logged-in user session, inspect service/process failures below. Do not repeatedly launch vdagent manually.'
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-2)} -MaxEvents 300 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'vdagent|vdservice' } | Select-Object TimeCreated, ProviderName, Id, Message | Format-List
Write-Host 'This script does not read clipboard contents. Restart is opt-in with -RestartAgent.'
