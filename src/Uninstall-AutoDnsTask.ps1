# Uninstall-AutoDnsTask.ps1 (Model v2)
# Removes scheduled tasks, removes from PATH, deletes ProgramData folder, and reverts adapter to DHCP.

$ErrorActionPreference = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '[*] Requesting Administrator privileges...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 0
}

Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  Auto DNS Optimizer v2 - Uninstallation            ' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

# 1. Remove Scheduled Tasks
Write-Host '[*] Removing Scheduled Tasks...' -ForegroundColor Cyan
& schtasks.exe /delete /tn "AutoDnsOptimizer_v2_30Min" /f | Out-Null
& schtasks.exe /delete /tn "AutoDnsOptimizer_v2_Startup" /f | Out-Null
& schtasks.exe /delete /tn "AutoDnsOptimizer_v2_NetworkChange" /f | Out-Null
& schtasks.exe /delete /tn "AutoDnsOptimizer_30Min" /f | Out-Null
& schtasks.exe /delete /tn "AutoDnsOptimizer_Startup" /f | Out-Null
& schtasks.exe /delete /tn "AutoDnsOptimizer_NetworkChange" /f | Out-Null
Write-Host '  [OK] Scheduled tasks removed.' -ForegroundColor Green

# 2. Remove from System PATH
$targetDir = Join-Path $env:ProgramData "AutoDnsOptimizer"
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($currentPath -like "*$targetDir*") {
    Write-Host '[*] Removing from System PATH...' -ForegroundColor Cyan
    $newPath = ($currentPath.Split(';') | Where-Object { $_ -ne $targetDir -and $_ -ne "" }) -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
    Write-Host '  [OK] Removed from System PATH.' -ForegroundColor Green
}

# 3. Revert Active Adapter to DHCP
$activeAdapter = Get-NetAdapter | Where-Object { 
    $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.InterfaceAlias -notmatch 'vEthernet|Virtual|Loopback|Bluetooth'
} | Select-Object -First 1

if ($activeAdapter) {
    Write-Host "[*] Reverting $($activeAdapter.InterfaceAlias) DNS to automatic (DHCP)..." -ForegroundColor Cyan
    Set-DnsClientServerAddress -InterfaceIndex $activeAdapter.InterfaceIndex -ResetServerAddresses
    Clear-DnsClientCache
    Write-Host "  [OK] $($activeAdapter.InterfaceAlias) DNS reverted to DHCP and cache cleared." -ForegroundColor Green
}

# 4. Clean up ProgramData folder if exists
if (Test-Path $targetDir) {
    Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  [OK] ProgramData directory cleaned up.' -ForegroundColor Green
}

Write-Host ''
Write-Host '[OK] Auto DNS Optimizer v2 has been completely uninstalled.' -ForegroundColor Green
Write-Host ''
