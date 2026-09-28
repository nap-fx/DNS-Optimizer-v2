@echo off
setlocal
if exist "%~dp0src\AutoDnsOptimizer.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\AutoDnsOptimizer.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoDnsOptimizer.ps1" %*
)
endlocal
