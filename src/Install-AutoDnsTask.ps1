# Install-AutoDnsTask.ps1 (Model v2 - Modular Architecture)
# 1. Installs AutoDnsOptimizer to canonical system directory (C:\ProgramData\AutoDnsOptimizer)
#    so moving or deleting the Downloads folder will NEVER break the service.
# 2. Adds AutoDnsOptimizer to PATH so 'dns-optimizer' or 'autodns' runs from any CMD/PowerShell directory.
# 3. Registers native Windows Scheduled Tasks (30min, Logon, and Wi-Fi Event ID 10000).

[CmdletBinding()]
param(
    [ValidateSet('Speed', 'Privacy', 'Security', 'All', 'Custom')][string]$Profile = 'Speed',
    [switch]$EnableToast,
    [switch]$Portable # If set, installs in-place without copying to ProgramData
)

$ErrorActionPreference = 'Stop'

# Ensure running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '[*] Requesting Administrator privileges...' -ForegroundColor Yellow
    $toastArg = if ($EnableToast) { '-EnableToast' } else { '' }
    $portableArg = if ($Portable) { '-Portable' } else { '' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile $toastArg $portableArg"
    exit 0
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = Split-Path -Parent $ScriptDir

Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  Auto DNS Optimizer v2 - Global System Installation' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

# Determine Target Directory
$TargetDir = if ($Portable) {
    $RootDir
} else {
    Join-Path $env:ProgramData "AutoDnsOptimizer"
}

Write-Host "[*] Source Root:          $RootDir" -ForegroundColor Gray
Write-Host "[*] Target Directory:     $TargetDir" -ForegroundColor White
Write-Host "[*] Selected Profile:     $Profile" -ForegroundColor Yellow

# Copy files to permanent location if not in portable mode
if (-not $Portable) {
    Write-Host '[*] Deploying files to canonical system path...' -ForegroundColor Cyan
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # Core engine
    Copy-Item -Path (Join-Path $ScriptDir "AutoDnsOptimizer.ps1") -Destination $TargetDir -Force
    
    # Config file
    $cfgSrc = if (Test-Path (Join-Path $RootDir "config\config.json")) { Join-Path $RootDir "config\config.json" } else { Join-Path $ScriptDir "config.json" }
    if (Test-Path $cfgSrc) {
        Copy-Item -Path $cfgSrc -Destination $TargetDir -Force
    }

    # CLI Wrappers
    $binDir = Join-Path $RootDir "bin"
    if (Test-Path $binDir) {
        Get-ChildItem -Path $binDir -Filter "*.cmd" | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $TargetDir -Force
        }
    }

    # Uninstaller
    Copy-Item -Path (Join-Path $ScriptDir "Uninstall-AutoDnsTask.ps1") -Destination $TargetDir -Force
    if (Test-Path (Join-Path $RootDir "Uninstall.bat")) {
        Copy-Item -Path (Join-Path $RootDir "Uninstall.bat") -Destination $TargetDir -Force
    }

    Write-Host '  [OK] Project files staged in permanent directory.' -ForegroundColor Green

    # Add TargetDir to System PATH so 'dns-optimizer' / 'autodns' works in any CMD/PowerShell
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    if ($currentPath -notlike "*$TargetDir*") {
        Write-Host '[*] Registering global command in System PATH...' -ForegroundColor Cyan
        [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$TargetDir", "Machine")
        $env:PATH += ";$TargetDir"
        Write-Host '  [OK] Added to System PATH. Commands available: dns-optimizer, autodns' -ForegroundColor Green
    }
}

$targetScript = Join-Path $TargetDir "AutoDnsOptimizer.ps1"
$toastFlag = if ($EnableToast) { "-Toast" } else { "" }
$taskCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$targetScript`" -Quiet -Profile $Profile $toastFlag"

Write-Host ''
Write-Host '[*] Registering Scheduled Tasks (SYSTEM account)...' -ForegroundColor Cyan

# 1. Task: Every 30 minutes
& schtasks.exe /create /tn "AutoDnsOptimizer_v2_30Min" /tr $taskCmd /sc minute /mo 30 /ru "SYSTEM" /rl HIGHEST /f | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host '  [OK] 30-Minute recurring task registered.' -ForegroundColor Green
}

# 2. Task: At Logon (Startup)
& schtasks.exe /create /tn "AutoDnsOptimizer_v2_Startup" /tr $taskCmd /sc onlogon /ru "SYSTEM" /rl HIGHEST /f | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host '  [OK] Startup / Logon task registered.' -ForegroundColor Green
}

# 3. Task: On Network Reconnect (Event ID 10000)
& schtasks.exe /create /tn "AutoDnsOptimizer_v2_NetworkChange" /tr $taskCmd /sc ONEVENT /ec "Microsoft-Windows-NetworkProfile/Operational" /mo '*[System[(EventID=10000)]]' /ru "SYSTEM" /rl HIGHEST /f | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host '  [OK] Wi-Fi reconnect event trigger registered (Event ID 10000).' -ForegroundColor Green
}

Write-Host ''
Write-Host '[*] Executing initial optimization run...' -ForegroundColor Cyan
& schtasks.exe /run /tn "AutoDnsOptimizer_v2_30Min" | Out-Null

Start-Sleep -Seconds 2

Write-Host ''
Write-Host '[OK] Installation Complete!' -ForegroundColor Green
Write-Host 'You can now run this tool from ANY directory in CMD or PowerShell by typing:' -ForegroundColor Cyan
Write-Host '    dns-optimizer -BenchmarkOnly' -ForegroundColor Yellow
Write-Host '    autodns' -ForegroundColor Yellow
Write-Host ''
Write-Host "Real-Time Execution Log:" -ForegroundColor Gray
Write-Host "    $TargetDir\AutoDnsOptimizer.log" -ForegroundColor Yellow
Write-Host ''
