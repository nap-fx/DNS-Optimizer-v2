@echo off
:: Batch launcher to uninstall Auto DNS Optimizer v2 with Administrator elevation
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~dp0Uninstall.bat' -Verb RunAs"
    exit /b
)

echo Removing Auto DNS Optimizer v2...
if exist "%~dp0src\Uninstall-AutoDnsTask.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Uninstall-AutoDnsTask.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-AutoDnsTask.ps1"
)
echo.
pause
