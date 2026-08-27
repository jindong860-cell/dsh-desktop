param([string]$Version = '2.3.6.0')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dist = Join-Path $Root 'dist'
$BuildScript = Join-Path $PSScriptRoot 'Build-MSIX.ps1'
$Publisher = 'CN=DSH Desktop Test'
$PfxPassword = 'dsh-desktop-test-only'
$PfxPath = Join-Path $Dist 'DSH-Desktop-Test.pfx'
$CerPath = Join-Path $Dist 'DSH-Desktop-Test.cer'
$MsixPath = Join-Path $Dist (('DSH-Desktop-{0}-x64.msix') -f $Version)
$LogPath = Join-Path $Root 'build-install.log'

function Write-Step([int]$Number, [string]$Text) {
    Write-Host ''
    Write-Host (('[{0}/6] {1}') -f $Number, $Text) -ForegroundColor Cyan
}

function Remove-OldTestCertificates {
    Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Publisher -and $_.FriendlyName -eq 'DSH Desktop Test Signing' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem 'Cert:\CurrentUser\TrustedPeople' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Publisher } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem 'Cert:\CurrentUser\Root' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Publisher } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem 'Cert:\LocalMachine\TrustedPeople' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Publisher } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Find-SignTool {
    $bases = @(
        'C:\Program Files (x86)\Windows Kits\10\bin',
        (Join-Path $Root '.tools\WindowsSdkBuildTools')
    )
    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }
        $tool = Get-ChildItem $base -Filter 'SignTool.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($tool) { return $tool.FullName }
    }
    return $null
}

Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
Start-Transcript -Path $LogPath -Force | Out-Null
try {
    Write-Host ''
    Write-Host 'DSH Desktop MSIX v2.3.6 - Build + Sign + Install' -ForegroundColor Cyan
    Write-Host 'PowerShell 5.1 compatible. Visual Studio is not required. Go 1.23+ is required when building from source.' -ForegroundColor DarkGray

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator permission is required to trust the MSIX test certificate in LocalMachine TrustedPeople.'
    }

    Write-Step 1 'Checking package files'
    if (-not (Test-Path $BuildScript)) { throw 'Build-MSIX.ps1 is missing.' }
    if (-not (Test-Path (Join-Path $Root 'prebuilt\DSHDesktopHost.exe')) -and -not (Test-Path (Join-Path $Root 'host\main.go'))) { throw 'Host source/prebuilt executable is missing.' }
    if (-not (Test-Path (Join-Path $Root 'app\launcher.ps1'))) { throw 'launcher.ps1 is missing.' }
    New-Item -ItemType Directory -Path $Dist -Force | Out-Null

    Write-Step 2 'Creating local test certificate'
    Remove-OldTestCertificates
    $securePassword = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
    $certArgs = @{
        Type = 'CodeSigningCert'
        Subject = $Publisher
        FriendlyName = 'DSH Desktop Test Signing'
        CertStoreLocation = 'Cert:\CurrentUser\My'
        KeyAlgorithm = 'RSA'
        KeyLength = 2048
        HashAlgorithm = 'SHA256'
        KeyExportPolicy = 'Exportable'
        NotAfter = (Get-Date).AddYears(2)
    }
    $cert = New-SelfSignedCertificate @certArgs
    Remove-Item $PfxPath, $CerPath -Force -ErrorAction SilentlyContinue
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $securePassword | Out-Null
    Export-Certificate -Cert $cert -FilePath $CerPath | Out-Null
    Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople' | Out-Null
    Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
    Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null

    # Confirm both SignTool and AppX deployment can see the certificate.
    $trustedRoot = Get-ChildItem 'Cert:\CurrentUser\Root' -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
    if (-not $trustedRoot) { throw 'The local test certificate could not be added to CurrentUser Root.' }
    $trustedMachine = Get-ChildItem 'Cert:\LocalMachine\TrustedPeople' -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
    if (-not $trustedMachine) { throw 'The local test certificate could not be added to LocalMachine TrustedPeople.' }

    Write-Step 3 'Building and signing MSIX'
    & $BuildScript -Version $Version -Publisher $Publisher -CertificatePath $PfxPath -CertificatePassword $PfxPassword -OutputDir $Dist
    if ($LASTEXITCODE -ne 0) { throw ('Build-MSIX.ps1 failed with exit code {0}.' -f $LASTEXITCODE) }
    if (-not (Test-Path $MsixPath)) { throw ('MSIX was not created: {0}' -f $MsixPath) }

    Write-Step 4 'Verifying MSIX signature'
    $signTool = Find-SignTool
    if (-not $signTool) { throw 'SignTool.exe was not found after build.' }
    & $signTool verify /pa /v $MsixPath
    if ($LASTEXITCODE -ne 0) { throw ('Signature verification failed with exit code {0}.' -f $LASTEXITCODE) }

    Write-Step 5 'Removing previous test package'
    $oldPackage = Get-AppxPackage -Name 'DSHDesktop.MSIX' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPackage) {
        Remove-AppxPackage -Package $oldPackage.PackageFullName -ErrorAction Stop
        Start-Sleep -Milliseconds 800
    }

    Write-Step 6 'Installing MSIX'
    Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown -ErrorAction Stop
    $installed = Get-AppxPackage -Name 'DSHDesktop.MSIX' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $installed) { throw 'Package installation returned without error, but the package was not detected.' }

    $hash = (Get-FileHash $MsixPath -Algorithm SHA256).Hash
    Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'SUCCESS - DSH Desktop MSIX is installed.' -ForegroundColor Green
    Write-Host ('Package: {0}' -f $installed.PackageFullName)
    Write-Host ('MSIX: {0}' -f $MsixPath)
    Write-Host ('SHA-256: {0}' -f $hash)
    Write-Host ('Log: {0}' -f $LogPath)
    Write-Host ''
    Write-Host 'Open DSH Desktop from the Windows Start menu.' -ForegroundColor Cyan
    Write-Host 'On first launch, choose a runtime directory such as D:\DSH Desktop.' -ForegroundColor Cyan
    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $MsixPath)
}
catch {
    Write-Host ''
    Write-Host 'BUILD/INSTALL FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Log: {0}' -f $LogPath) -ForegroundColor Yellow
    throw
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}