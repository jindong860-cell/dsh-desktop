@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-Web-Profile.ps1"
if errorlevel 1 (
  echo Repair failed.
  exit /b 1
)
echo Repair completed successfully.
pause