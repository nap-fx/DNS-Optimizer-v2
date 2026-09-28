@echo off
setlocal
if exist "%~dp0..\src\AutoDnsOptimizer.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\AutoDnsOptimizer.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoDnsOptimizer.ps1" %*
)
endlocal
