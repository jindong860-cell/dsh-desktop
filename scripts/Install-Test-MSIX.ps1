param([string]$Version='2.3.6.0')
$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dist=Join-Path $Root 'dist'
$cer=Join-Path $Dist 'DSH-Desktop-Test.cer'
$msix=Join-Path $Dist "DSH-Desktop-$Version-x64.msix"
if(-not (Test-Path $cer) -or -not (Test-Path $msix)){throw 'Run Build-Test-MSIX.ps1 first.'}
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'|Out-Null
Add-AppxPackage -Path $msix -ForceApplicationShutdown
Write-Host 'Installed DSH Desktop test MSIX.'