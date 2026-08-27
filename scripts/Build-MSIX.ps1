param(
    [string]$Version = '2.3.6.0',
    [string]$Publisher = 'CN=DSH Desktop Test',
    [string]$CertificatePath = '',
    [string]$CertificatePassword = '',
    [string]$OutputDir = "$PSScriptRoot\..\dist"
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Stage=Join-Path $Root 'build\package'
$ToolsRoot=Join-Path $Root '.tools'
$SdkRoot=Join-Path $ToolsRoot 'WindowsSdkBuildTools'
$NugetExe=Join-Path $ToolsRoot 'nuget.exe'
Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Stage,(Join-Path $Stage 'Assets'),$OutputDir,$ToolsRoot -Force|Out-Null

function Find-SdkTool([string]$Name){
    foreach($base in @('C:\Program Files (x86)\Windows Kits\10\bin',$SdkRoot)){
        if(Test-Path $base){
            $f=Get-ChildItem $base -Filter $Name -Recurse -ErrorAction SilentlyContinue |
               Where-Object FullName -Match '\\x64\\' | Sort-Object FullName -Descending | Select-Object -First 1
            if($f){return $f.FullName}
        }
    }
    return $null
}
$makeappx=Find-SdkTool 'MakeAppx.exe'
$signtool=Find-SdkTool 'SignTool.exe'
if(-not $makeappx -or ($CertificatePath -and -not $signtool)){
    if(-not (Test-Path $NugetExe)){ Invoke-WebRequest -UseBasicParsing 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $NugetExe }
    Remove-Item $SdkRoot -Recurse -Force -ErrorAction SilentlyContinue
    & $NugetExe install Microsoft.Windows.SDK.BuildTools -OutputDirectory $SdkRoot -ExcludeVersion -NonInteractive -Verbosity quiet
    if($LASTEXITCODE -ne 0){throw 'Failed to download Microsoft.Windows.SDK.BuildTools.'}
    $makeappx=Find-SdkTool 'MakeAppx.exe';$signtool=Find-SdkTool 'SignTool.exe'
}
if(-not $makeappx){throw 'MakeAppx.exe not found.'}

$hostExe=Join-Path $Root 'prebuilt\DSHDesktopHost.exe'
if(-not (Test-Path $hostExe)){
    $go=(Get-Command go.exe -ErrorAction SilentlyContinue)
    if(-not $go){throw 'Go 1.23+ is required to build DSHDesktopHost.exe from source (or provide prebuilt\DSHDesktopHost.exe).'}
    $hostOut=Join-Path $Root 'build\DSHDesktopHost.exe'
    New-Item -ItemType Directory -Path (Split-Path $hostOut) -Force | Out-Null
    Push-Location (Join-Path $Root 'host')
    try {
        $env:GOOS='windows'; $env:GOARCH='amd64'
        & $go.Source build -trimpath -ldflags '-s -w -H=windowsgui' -o $hostOut .
        if($LASTEXITCODE -ne 0){throw 'Go host build failed.'}
    } finally { Pop-Location }
    $hostExe=$hostOut
}
Copy-Item $hostExe (Join-Path $Stage 'DSHDesktopHost.exe') -Force
Copy-Item (Join-Path $Root 'app\launcher.ps1') (Join-Path $Stage 'launcher.ps1') -Force
Copy-Item (Join-Path $Root 'package\assets\*') (Join-Path $Stage 'Assets') -Force
$manifest=Get-Content (Join-Path $Root 'package\AppxManifest.xml.template') -Raw
$manifest=$manifest.Replace('__VERSION__',$Version).Replace('__PUBLISHER__',$Publisher)
Set-Content (Join-Path $Stage 'AppxManifest.xml') $manifest -Encoding UTF8
$out=Join-Path $OutputDir "DSH-Desktop-$Version-x64.msix"
& $makeappx pack /d $Stage /p $out /o
if($LASTEXITCODE -ne 0){throw 'MakeAppx failed.'}
if($CertificatePath){
    if(-not $signtool){throw 'SignTool.exe not found.'}
    & $signtool sign /fd SHA256 /f $CertificatePath /p $CertificatePassword $out
    if($LASTEXITCODE -ne 0){throw 'SignTool failed.'}
}
Get-FileHash $out -Algorithm SHA256 | Format-List
Write-Host "Built: $out"