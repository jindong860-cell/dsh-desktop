param([string]$Version='2.3.6.0')
$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dist=Join-Path $Root 'dist'
New-Item -ItemType Directory -Path $Dist -Force|Out-Null
$securePassword=ConvertTo-SecureString 'dsh-test-only' -AsPlainText -Force
$cert=New-SelfSignedCertificate -Type Custom -Subject 'CN=DSH Desktop Test' -FriendlyName 'DSH Desktop Test Signing' -CertStoreLocation 'Cert:\CurrentUser\My' -KeyUsage DigitalSignature -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
$pfx=Join-Path $Dist 'DSH-Desktop-Test.pfx';$cer=Join-Path $Dist 'DSH-Desktop-Test.cer'
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $securePassword|Out-Null
Export-Certificate -Cert $cert -FilePath $cer|Out-Null
& (Join-Path $PSScriptRoot 'Build-MSIX.ps1') -Version $Version -Publisher 'CN=DSH Desktop Test' -CertificatePath $pfx -CertificatePassword 'dsh-test-only' -OutputDir $Dist
Remove-Item $pfx -Force
Write-Host "Test certificate: $cer"