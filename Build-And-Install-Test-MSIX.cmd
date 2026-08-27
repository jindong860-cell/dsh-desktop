@echo off
setlocal
cd /d "%~dp0"
title DSH Desktop MSIX v2.3.6 - Build + Sign + Install

powershell.exe -NoLogo -NoProfile -Command "$p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if errorlevel 1 (
  echo Requesting administrator permission for machine certificate trust...
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-And-Install-Test-MSIX.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Build/install failed.
  echo See build-install.log in this folder for details.
) else (
  echo Completed successfully.
)
echo.
pause
exit /b %RC%