@echo off
:: Batch launcher to install Auto DNS Optimizer v2 with Administrator elevation
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~dp0Install.bat' -Verb RunAs"
    exit /b
)

echo Running Auto DNS Optimizer v2 Installer...
if exist "%~dp0src\Install-AutoDnsTask.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Install-AutoDnsTask.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AutoDnsTask.ps1"
)
echo.
pause
