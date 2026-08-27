$ErrorActionPreference = 'Stop'
$profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\web'
$profile = Join-Path $profileDir 'cordis.patch.yml'
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
if (Test-Path $profile) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $profile ($profile + '.bak-' + $stamp) -Force
}
Set-Content -Path $profile -Value '[]' -Encoding UTF8
Write-Host 'PASS: DSH Web profile overlay was reset to valid empty YAML.' -ForegroundColor Green