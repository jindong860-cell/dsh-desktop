#requires -version 5.1
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$ShellDataRoot = Join-Path $env:LOCALAPPDATA 'DSHDesktopShell'
$SettingsPath = Join-Path $ShellDataRoot 'settings.json'
$LegacySettings = Join-Path $env:LOCALAPPDATA 'DSHDesktop\settings.json'
$DshHomeDefault = Join-Path $env:USERPROFILE '.dsh'
$RegistryLatest = 'https://registry.npmjs.org/@deepseek-ai%2Fdsh/latest'
$TestedDshVersion = '0.1.1-rc.2'
New-Item -ItemType Directory -Path $ShellDataRoot -Force | Out-Null

function Default-Settings {
    [pscustomobject]@{
        runtimeRoot = ''
        dshHome = $DshHomeDefault
        updateMode = 'ask'
        port = 3080
    }
}
function Load-Settings {
    foreach ($p in @($SettingsPath,$LegacySettings)) {
        if (Test-Path $p) {
            try {
                $s = Get-Content $p -Raw | ConvertFrom-Json
                if (-not $s.PSObject.Properties['runtimeRoot']) { $s | Add-Member runtimeRoot '' }
                if (-not $s.PSObject.Properties['dshHome']) { $s | Add-Member dshHome $DshHomeDefault }
                return $s
            } catch {}
        }
    }
    return (Default-Settings)
}
function Save-Settings($s) {
    $s | ConvertTo-Json -Depth 5 | Set-Content $SettingsPath -Encoding UTF8
}
function Get-Paths($s) {
    if (-not $s.runtimeRoot) { return $null }
    $root = [IO.Path]::GetFullPath([string]$s.runtimeRoot)
    [pscustomobject]@{
        Root = $root
        NodeRoot = Join-Path $root 'node'
        CoreRoot = Join-Path $root 'core'
        LogRoot = Join-Path $root 'logs'
        PidPath = Join-Path $root 'server.pid'
        NodeExe = Join-Path $root 'node\node.exe'
        NpmCmd = Join-Path $root 'node\npm.cmd'
        NpmCli = Join-Path $root 'node\node_modules\npm\bin\npm-cli.js'
        DshBin = Join-Path $root 'core\node_modules\@deepseek-ai\dsh\lib\bin.js'
        CorePackage = Join-Path $root 'core\node_modules\@deepseek-ai\dsh\package.json'
        ReadyMarker = Join-Path $root 'runtime-ready-v236.json'
    }
}
function Test-WritableFolder([string]$path) {
    try {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $test = Join-Path $path ('.dsh-write-test-' + [guid]::NewGuid().ToString('N'))
        Set-Content $test 'ok' -Encoding ASCII
        Remove-Item $test -Force
        return $true
    } catch { return $false }
}
function Choose-RuntimeFolder {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择 DSH 运行环境位置（Node、DSH Core、日志将存放在这里）'
    $dlg.ShowNewFolderButton = $true
    $current = Load-Settings
    if ($current.runtimeRoot -and (Test-Path $current.runtimeRoot)) { $dlg.SelectedPath = $current.runtimeRoot }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $chosen = $dlg.SelectedPath
    if (-not (Test-WritableFolder $chosen)) {
        [System.Windows.MessageBox]::Show('所选目录不可写。请换一个普通用户有写入权限的目录，例如 D:\DSH Desktop。','DSH Desktop') | Out-Null
        return $null
    }
    return $chosen
}
function Get-LocalVersion($p) {
    if (-not $p -or -not (Test-Path $p.CorePackage)) { return '未安装' }
    try { return (Get-Content $p.CorePackage -Raw | ConvertFrom-Json).version } catch { return '未知' }
}
function Get-NodeVersion($p) {
    if (-not $p -or -not (Test-Path $p.NodeExe)) { return '未安装' }
    try { return (& $p.NodeExe -v).Trim() } catch { return '未知' }
}
function Get-LatestVersion {
    try { return (Invoke-RestMethod -Uri $RegistryLatest -Method Get -TimeoutSec 12).version } catch { return $null }
}
function Test-Port([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1',$Port,$null,$null)
        if (-not $iar.AsyncWaitHandle.WaitOne(350)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-PortOwnerPid([int]$Port) {
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
        if ($conn) { return [int]$conn.OwningProcess }
    } catch {}
    try {
        $netstat = Join-Path $env:SystemRoot 'System32\\netstat.exe'
        if (Test-Path $netstat) {
            foreach ($line in (& $netstat -ano -p tcp 2>$null)) {
                if ($line -match ('^\\s*TCP\\s+\\S+:' + [regex]::Escape([string]$Port) + '\\s+\\S+\\s+LISTENING\\s+(\\d+)\\s*$')) {
                    return [int]$matches[1]
                }
            }
        }
    } catch {}
    return $null
}
function Get-ProcessCommandLine([int]$ProcessId) {
    try {
        $wp = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($wp) { return [string]$wp.CommandLine }
    } catch {}
    return ''
}
function Test-IsManagedDshProcess([int]$ProcessId,$p) {
    if (-not $p -or $ProcessId -le 0) { return $false }
    $cmd = Get-ProcessCommandLine $ProcessId
    if (-not $cmd) { return $false }
    return ($cmd.IndexOf([string]$p.DshBin,[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}
function Test-IsAnyDshProcess([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    $cmd = Get-ProcessCommandLine $ProcessId
    if (-not $cmd) { return $false }
    return ($cmd -match '(?i)@deepseek-ai[\\/]+dsh[\\/]+lib[\\/]+bin\\.js')
}
function Find-FreePreferredPort([int]$PreferredPort) {
    $start = [Math]::Max(1024,$PreferredPort + 1)
    $finish = [Math]::Min(65535,$start + 49)
    for ($candidate=$start; $candidate -le $finish; $candidate++) {
        if (-not (Test-Port $candidate)) { return $candidate }
    }
    return (Get-FreeLocalPort)
}

function Get-ManagedPid($p) {
    if (-not $p -or -not (Test-Path $p.PidPath)) { return $null }
    $raw = Get-Content $p.PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    $n = 0
    if ([int]::TryParse([string]$raw,[ref]$n)) {
        if (Get-Process -Id $n -ErrorAction SilentlyContinue) { return $n }
    }
    Remove-Item $p.PidPath -Force -ErrorAction SilentlyContinue
    return $null
}
function Set-Status([string]$text,[string]$kind='normal') {
    $StatusText.Text = $text
    switch ($kind) {
        'ok'    { $StatusDot.Fill = '#16A34A' }
        'busy'  { $StatusDot.Fill = '#2563EB' }
        'error' { $StatusDot.Fill = '#DC2626' }
        default { $StatusDot.Fill = '#94A3B8' }
    }
    [System.Windows.Forms.Application]::DoEvents()
}
function Refresh-Ui {
    $s = Load-Settings
    $p = Get-Paths $s
    $RuntimePathText.Text = $(if($s.runtimeRoot){$s.runtimeRoot}else{'尚未选择'})
    $DshHomeText.Text = $s.dshHome
    $CoreVersionText.Text = Get-LocalVersion $p
    $NodeVersionText.Text = Get-NodeVersion $p
    if ($p -and (Get-ManagedPid $p)) {
        Set-Status 'DSH 服务正在运行' 'ok'
        $StartButton.IsEnabled = $false
        $StopButton.IsEnabled = $true
    } else {
        Set-Status '服务未启动' 'normal'
        $StartButton.IsEnabled = [bool]$s.runtimeRoot
        $StopButton.IsEnabled = $false
    }
}
$script:WizardWindow = $null
$script:WizardProgress = $null
$script:WizardPhaseText = $null
$script:WizardDetailText = $null
$script:WizardElapsedText = $null
$script:WizardLogBox = $null
$script:WizardStarted = $null
$script:WizardBusy = $false
$script:WizardAction = ''

function Pump-WizardUi {
    if ($script:WizardStarted -and $script:WizardElapsedText) {
        $elapsed = (Get-Date) - $script:WizardStarted
        $script:WizardElapsedText.Text = ('已用时 {0:00}:{1:00}' -f [int]$elapsed.TotalMinutes,$elapsed.Seconds)
    }
    [System.Windows.Forms.Application]::DoEvents()
}
function Append-WizardLog([string]$text) {
    if (-not $script:WizardLogBox -or [string]::IsNullOrWhiteSpace($text)) { return }
    $script:WizardLogBox.AppendText($text.TrimEnd() + "`r`n")
    if ($script:WizardLogBox.Text.Length -gt 80000) {
        $script:WizardLogBox.Text = $script:WizardLogBox.Text.Substring($script:WizardLogBox.Text.Length - 60000)
    }
    $script:WizardLogBox.ScrollToEnd()
    Pump-WizardUi
}
function Set-WizardProgress([double]$value,[string]$phase,[string]$detail,[bool]$indeterminate=$false) {
    if ($script:WizardProgress) {
        $script:WizardProgress.IsIndeterminate = $indeterminate
        if (-not $indeterminate) { $script:WizardProgress.Value = [Math]::Max(0,[Math]::Min(100,$value)) }
    }
    if ($script:WizardPhaseText) { $script:WizardPhaseText.Text = $phase }
    if ($script:WizardDetailText) { $script:WizardDetailText.Text = $detail }
    Pump-WizardUi
}
function Set-WizardStepState([int]$number,[string]$state) {
    if (-not $script:WizardWindow) { return }
    $box = $script:WizardWindow.FindName(('Step{0}Box' -f $number))
    $badge = $script:WizardWindow.FindName(('Step{0}Badge' -f $number))
    $title = $script:WizardWindow.FindName(('Step{0}Title' -f $number))
    if (-not $box -or -not $badge -or -not $title) { return }
    switch ($state) {
        'done' {
            $box.Background = '#0E302D'; $box.BorderBrush = '#1F665C'
            $badge.Background = '#157A6E'; $badge.Text = '✓'; $title.Foreground = '#D8FFF7'
        }
        'current' {
            $box.Background = '#102E52'; $box.BorderBrush = '#2F6FC8'
            $badge.Background = '#397CF7'; $badge.Text = [string]$number; $title.Foreground = '#FFFFFF'
        }
        'error' {
            $box.Background = '#351B24'; $box.BorderBrush = '#8F3547'
            $badge.Background = '#C13F57'; $badge.Text = '!'; $title.Foreground = '#FFDCE3'
        }
        default {
            $box.Background = '#09182B'; $box.BorderBrush = '#17324F'
            $badge.Background = '#18304D'; $badge.Text = [string]$number; $title.Foreground = '#8FA5BE'
        }
    }
    Pump-WizardUi
}
function Update-WizardLogFromFiles([string[]]$files) {
    if (-not $script:WizardLogBox) { return }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        if (Test-Path $file) {
            try {
                foreach ($line in (Get-Content $file -Tail 55 -Encoding UTF8 -ErrorAction SilentlyContinue)) { [void]$lines.Add([string]$line) }
            } catch {}
        }
    }
    if ($lines.Count -gt 0) {
        $script:WizardLogBox.Text = ($lines | Select-Object -Last 90) -join "`r`n"
        $script:WizardLogBox.ScrollToEnd()
    }
    Pump-WizardUi
}
function Download-WizardFile([string]$uri,[string]$destination,[double]$from,[double]$to) {
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.UserAgent = 'DSH-Desktop'
    $request.Timeout = 30000
    $response = $request.GetResponse()
    try {
        $total = [int64]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] 1048576
            $received = [int64]0
            $lastBucket = -1
            while (($read = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $outputStream.Write($buffer,0,$read)
                $received += $read
                if ($total -gt 0) {
                    $pct = [Math]::Min(100,[Math]::Round(($received * 100.0) / $total))
                    $globalValue = $from + (($to-$from) * $pct / 100.0)
                    Set-WizardProgress $globalValue '步骤 2/5 · 下载 Node.js 24' (('正在下载 Node.js：{0}%  ·  {1:N1} / {2:N1} MB' -f $pct,($received/1MB),($total/1MB))) $false
                    $bucket = [int]([Math]::Floor($pct / 10))
                    if ($bucket -ne $lastBucket) {
                        $lastBucket = $bucket
                        Append-WizardLog (('Node.js 下载进度：{0}%' -f $pct))
                    }
                } else {
                    Set-WizardProgress $from '步骤 2/5 · 下载 Node.js 24' (('已下载 {0:N1} MB' -f ($received/1MB))) $true
                }
            }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
        }
    } finally { $response.Close() }
}
function Install-PortableNode($p) {
    Set-Status '正在安装 Node.js 运行环境…' 'busy'
    Set-WizardStepState 2 'current'
    Set-WizardProgress 12 '步骤 2/5 · 准备 Node.js 24' '正在获取官方版本与 SHA-256 校验信息…' $true
    Append-WizardLog '正在解析 Node.js 24 Windows 安装包。'
    New-Item -ItemType Directory -Path $p.Root,$p.LogRoot -Force | Out-Null
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {'arm64'} else {'x64'}
    $sumsUrl = 'https://nodejs.org/download/release/latest-v24.x/SHASUMS256.txt'
    $sums = (Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -TimeoutSec 30).Content
    $match = [regex]::Match($sums,"(?m)^([0-9a-fA-F]{64})\s+(node-v[0-9.]+-win-$arch\.zip)$")
    if (-not $match.Success) { throw '无法解析 Node.js 24 下载包。' }
    $expected = $match.Groups[1].Value.ToLowerInvariant()
    $file = $match.Groups[2].Value
    $temp = Join-Path $env:TEMP ('DSHMSIX-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $temp $file
    $extract = Join-Path $temp 'extract'
    New-Item -ItemType Directory -Path $temp,$extract -Force | Out-Null
    try {
        Append-WizardLog ('下载：' + $file)
        Download-WizardFile "https://nodejs.org/download/release/latest-v24.x/$file" $zip 15 38
        Set-WizardProgress 40 '步骤 2/5 · 校验 Node.js' '正在执行 SHA-256 完整性校验…' $true
        $actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw 'Node.js SHA-256 校验失败。' }
        Append-WizardLog 'Node.js SHA-256 校验通过。'
        Set-WizardProgress 43 '步骤 2/5 · 解压 Node.js' '正在解压便携运行环境…' $true
        Expand-Archive $zip $extract -Force
        $src=Get-ChildItem $extract -Directory | Select-Object -First 1
        if (-not $src) { throw 'Node.js 压缩包结构异常。' }
        if (Test-Path $p.NodeRoot) { Remove-Item $p.NodeRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $p.NodeRoot -Force | Out-Null
        Copy-Item (Join-Path $src.FullName '*') $p.NodeRoot -Recurse -Force
        Append-WizardLog ('Node.js 已安装：' + (Get-NodeVersion $p))
        Set-WizardProgress 46 '步骤 2/5 · Node.js 已就绪' ('版本：' + (Get-NodeVersion $p)) $false
        Set-WizardStepState 2 'done'
    } finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Get-NpmHeapLimitMb {
    try {
        $mem = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        $gb = [math]::Round($mem / 1GB, 1)
        if ($gb -ge 16) { return 6144 }
        if ($gb -ge 8) { return 4096 }
        return 3072
    } catch { return 4096 }
}
function Prepare-CoreProjectPolicy($p) {
    New-Item -ItemType Directory -Path $p.CoreRoot -Force | Out-Null
    $policyPath = Join-Path $p.CoreRoot 'package.json'
    $policy = [ordered]@{
        name = 'dsh-desktop-runtime'
        version = '1.0.0'
        private = $true
        allowScripts = [ordered]@{
            '@deepseek-ai/dsh-subprocess-local' = $true
            '@google/genai' = $true
            'koffi' = $true
            'node-pty' = $true
            'protobufjs' = $true
        }
    }
    $policy | ConvertTo-Json -Depth 6 | Set-Content -Path $policyPath -Encoding UTF8
    Append-WizardLog '已写入 npm install-script allowlist（DSH 所需原生/后处理依赖）。'
}
function Invoke-NpmWizardAttempt($p,[string[]]$specs,[string]$attemptName) {
    New-Item -ItemType Directory -Path $p.LogRoot,$p.CoreRoot -Force | Out-Null
    $stdout = Join-Path $p.LogRoot 'npm-current-out.log'
    $stderr = Join-Path $p.LogRoot 'npm-current-error.log'
    $combined = Join-Path $p.LogRoot 'npm-install.log'
    Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $p.NodeExe)) { throw ('Node.js executable not found: ' + $p.NodeExe) }
    if (-not (Test-Path $p.NpmCli)) { throw ('npm CLI not found: ' + $p.NpmCli) }

    $heapMb = Get-NpmHeapLimitMb
    Add-Content -Path $combined -Value ("`r`n===== $attemptName · $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====") -Encoding UTF8
    Append-WizardLog ("开始：$attemptName")
    Append-WizardLog ("依赖解析策略：--legacy-peer-deps；npm 堆上限：${heapMb}MB")

    $npmArgs = @(
        ("`"{0}`"" -f $p.NpmCli),
        'install',
        '--prefix', ("`"{0}`"" -f $p.CoreRoot)
    )
    foreach ($spec in $specs) { $npmArgs += ("`"{0}`"" -f $spec) }
    $npmArgs += @('--legacy-peer-deps','--no-audit','--no-fund','--loglevel','notice')

    $oldNodeOptions = $env:NODE_OPTIONS
    try {
        $env:NODE_OPTIONS = "--max-old-space-size=$heapMb"
        $process = Start-Process -FilePath $p.NodeExe -ArgumentList $npmArgs -WorkingDirectory $p.Root -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        while (-not $process.HasExited) {
            Update-WizardLogFromFiles @($stdout,$stderr)
            Set-WizardProgress 62 '步骤 3/5 · 安装 DSH Core' '正在解析依赖并安装。已启用兼容依赖模式以避免 npm 依赖树内存溢出。' $true
            Start-Sleep -Milliseconds 350
            $process.Refresh()
        }
        $process.WaitForExit()
        $process.Refresh()
        $exitCode = [int]$process.ExitCode
    } finally {
        if ($null -eq $oldNodeOptions) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
        else { $env:NODE_OPTIONS = $oldNodeOptions }
    }

    Update-WizardLogFromFiles @($stdout,$stderr)
    foreach($f in @($stdout,$stderr)) {
        if(Test-Path $f) { Get-Content $f -ErrorAction SilentlyContinue | Add-Content -Path $combined -Encoding UTF8 }
    }
    Add-Content -Path $combined -Value ("npm ExitCode=$exitCode") -Encoding UTF8
    Append-WizardLog ("$attemptName 结束，ExitCode=$exitCode")

    if ($exitCode -eq 0) { return $true }
    # Some Windows PowerShell 5.1 + redirected-process combinations have been
    # observed to report a stale/non-zero exit code even though npm completed
    # the package layout. Structural + smoke validation below is authoritative.
    if ((Test-Path $p.DshBin) -and (Test-Path $p.CorePackage)) {
        Append-WizardLog 'npm 返回非零状态，但 DSH 文件结构已完整；继续进入重建与启动校验。'
        return $true
    }
    return $false
}
function Invoke-NpmWizardRebuild($p) {
    $stdout = Join-Path $p.LogRoot 'npm-rebuild-out.log'
    $stderr = Join-Path $p.LogRoot 'npm-rebuild-error.log'
    $combined = Join-Path $p.LogRoot 'npm-install.log'
    Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
    Append-WizardLog '正在运行 npm rebuild，确保 node-pty / koffi / subprocess helper 等安装脚本已执行。'
    Add-Content -Path $combined -Value ("`r`n===== npm rebuild · $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====") -Encoding UTF8
    $npmArgs = @(("`"{0}`"" -f $p.NpmCli),'rebuild','--prefix',("`"{0}`"" -f $p.CoreRoot),'--loglevel','notice')
    $heapMb = Get-NpmHeapLimitMb
    $oldNodeOptions = $env:NODE_OPTIONS
    try {
        $env:NODE_OPTIONS = "--max-old-space-size=$heapMb"
        $process = Start-Process -FilePath $p.NodeExe -ArgumentList $npmArgs -WorkingDirectory $p.Root -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        while(-not $process.HasExited){
            Update-WizardLogFromFiles @($stdout,$stderr)
            Set-WizardProgress 78 '步骤 3/5 · 准备原生依赖' '正在执行已允许的 install/postinstall 脚本。' $true
            Start-Sleep -Milliseconds 350
            $process.Refresh()
        }
        $process.WaitForExit(); $process.Refresh(); $exitCode=[int]$process.ExitCode
    } finally {
        if ($null -eq $oldNodeOptions) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
        else { $env:NODE_OPTIONS = $oldNodeOptions }
    }
    Update-WizardLogFromFiles @($stdout,$stderr)
    foreach($f in @($stdout,$stderr)){ if(Test-Path $f){ Get-Content $f -ErrorAction SilentlyContinue | Add-Content -Path $combined -Encoding UTF8 } }
    Add-Content -Path $combined -Value ("npm rebuild ExitCode=$exitCode") -Encoding UTF8
    Append-WizardLog ("npm rebuild 结束，ExitCode=$exitCode")
    return ($exitCode -eq 0)
}
function Get-DshRequiredPeerPackages {
    # Runtime peer-only packages required by the standalone DSH deployment.
    # DSH-prefixed packages must be kept on exactly the same version line as
    # the main @deepseek-ai/dsh package. cordis-plugin-group is a vendored
    # package with its own independent 1.x version line, so it is not pinned to
    # the DSH version.
    @(
        '@deepseek-ai/cordis-plugin-group',
        '@deepseek-ai/dsh-anonymous-user-id',
        '@deepseek-ai/dsh-atomic-write',
        '@deepseek-ai/dsh-authorization',
        '@deepseek-ai/dsh-bash-local',
        '@deepseek-ai/dsh-code-runtime',
        '@deepseek-ai/dsh-compaction',
        '@deepseek-ai/dsh-fs',
        '@deepseek-ai/dsh-invariants',
        '@deepseek-ai/dsh-output-retention',
        '@deepseek-ai/dsh-sandbox',
        '@deepseek-ai/dsh-scope',
        '@deepseek-ai/dsh-session-telemetry',
        '@deepseek-ai/dsh-session-title-llm',
        '@deepseek-ai/dsh-shell',
        '@deepseek-ai/dsh-spill',
        '@deepseek-ai/dsh-subagent-in-process-driver',
        '@deepseek-ai/dsh-timeout',
        '@deepseek-ai/dsh-workflow'
    )
}
function Get-VersionLockedPeerSpecs([string]$DshVersion) {
    $specs = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-DshRequiredPeerPackages)) {
        if ($name -like '@deepseek-ai/dsh-*') { [void]$specs.Add("$name@$DshVersion") }
        else { [void]$specs.Add("$name@latest") }
    }
    return $specs.ToArray()
}
function Get-InstalledDshPackageManifests($p) {
    $scopeRoot = Join-Path (Join-Path $p.CoreRoot 'node_modules') '@deepseek-ai'
    if (-not (Test-Path $scopeRoot)) { return @() }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in (Get-ChildItem -Path $scopeRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -ne 'dsh' -and -not $dir.Name.StartsWith('dsh-')) { continue }
        $manifestPath = Join-Path $dir.FullName 'package.json'
        if (-not (Test-Path $manifestPath)) { continue }
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.name -and $manifest.version) {
                [void]$items.Add([pscustomobject]@{ Name=[string]$manifest.name; Version=[string]$manifest.version; Path=$manifestPath })
            }
        } catch {}
    }
    return $items.ToArray()
}
function Test-DshVersionAlignment($p,[string]$TargetVersion,[bool]$ThrowOnMismatch=$true) {
    $mismatch = [System.Collections.Generic.List[string]]::new()
    foreach ($pkg in (Get-InstalledDshPackageManifests $p)) {
        if ($pkg.Version -ne $TargetVersion) { [void]$mismatch.Add("$($pkg.Name)=$($pkg.Version)") }
    }
    if ($mismatch.Count -gt 0) {
        if ($ThrowOnMismatch) { throw ('DSH 包版本不一致：目标 ' + $TargetVersion + '；发现 ' + ($mismatch -join ', ')) }
        return $false
    }
    Append-WizardLog ("DSH package version alignment 已通过：全部 dsh-* 包 = $TargetVersion")
    return $true
}
function Repair-DshVersionAlignment($p,[string]$TargetVersion) {
    for ($pass=1; $pass -le 3; $pass++) {
        $specs = [System.Collections.Generic.List[string]]::new()
        foreach ($pkg in (Get-InstalledDshPackageManifests $p)) {
            if ($pkg.Version -ne $TargetVersion) { [void]$specs.Add("$($pkg.Name)@$TargetVersion") }
        }
        if ($specs.Count -eq 0) {
            Append-WizardLog ("DSH 版本闭包已一致：$TargetVersion")
            return $true
        }
        Append-WizardLog ("发现 $($specs.Count) 个跨版本 DSH 包，正在执行第 $pass 次版本对齐。")
        foreach ($spec in $specs) { Append-WizardLog ("  pin: $spec") }
        $ok = Invoke-NpmWizardAttempt $p $specs.ToArray() ("对齐 DSH 运行时版本（pass $pass）")
        if (-not $ok) { return $false }
    }
    return (Test-DshVersionAlignment $p $TargetVersion $false)
}
function Test-DshRequiredPeerClosure($p,[string]$TargetVersion) {
    $missing = [System.Collections.Generic.List[string]]::new()
    $wrongVersion = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-DshRequiredPeerPackages)) {
        $relative = $name.Replace('/','\')
        $manifest = Join-Path (Join-Path $p.CoreRoot 'node_modules') (Join-Path $relative 'package.json')
        if (-not (Test-Path $manifest)) {
            [void]$missing.Add($name)
            continue
        }
        if ($name -like '@deepseek-ai/dsh-*') {
            try {
                $actual = [string](Get-Content $manifest -Raw | ConvertFrom-Json).version
                if ($actual -ne $TargetVersion) { [void]$wrongVersion.Add("$name=$actual") }
            } catch { [void]$wrongVersion.Add("$name=?") }
        }
    }
    if ($missing.Count -gt 0) { throw ('DSH 运行时依赖闭包不完整，仍缺少：' + ($missing -join ', ')) }
    if ($wrongVersion.Count -gt 0) { throw ('DSH peer 版本与 Core 不一致：' + ($wrongVersion -join ', ')) }
    Append-WizardLog 'DSH required peer closure 已补齐，且所有 dsh-* peer 与 Core 版本一致。'
}
function Reset-CoreDependencyTree($p,[string]$Reason) {
    Append-WizardLog ("正在重建 DSH 依赖树：$Reason")
    $modules = Join-Path $p.CoreRoot 'node_modules'
    $lock = Join-Path $p.CoreRoot 'package-lock.json'
    if (Test-Path $modules) { Remove-Item $modules -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Remove-Item $p.ReadyMarker -Force -ErrorAction SilentlyContinue
    Prepare-CoreProjectPolicy $p
}
function Install-DshCore($p,[bool]$Repair=$false) {
    Set-Status $(if($Repair){'正在修复 DSH Core…'}else{'正在安装 DSH Core…'}) 'busy'
    Set-WizardStepState 3 'current'
    Set-WizardProgress 52 '步骤 3/5 · 安装 DSH Core' '锁定同一 DSH 版本线并补齐运行时 peer，避免 prerelease 包 API 混装。' $true
    if ((Test-Path $p.CoreRoot) -and -not (Test-Path $p.CorePackage)) {
        Append-WizardLog '检测到上次未完成的 Core 安装，正在清理残留。'
        Remove-Item $p.CoreRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $p.ReadyMarker -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $p.CoreRoot,$p.LogRoot -Force | Out-Null
    $env:PATH = "$($p.NodeRoot);$env:PATH"
    $combined = Join-Path $p.LogRoot 'npm-install.log'
    Set-Content -Path $combined -Value ('DSH Desktop npm install log · ' + (Get-Date)) -Encoding UTF8
    Prepare-CoreProjectPolicy $p

    # Repair mode first checks whether the existing tree is already coherent.
    # v2.3.5 could finish npm successfully and then fail only in PowerShell's
    # List[object] + @() binder; in that case there is no reason to download
    # hundreds of packages again.
    $reuseAlignedTree = $false
    $existingVersion = Get-LocalVersion $p
    if ($Repair -and (Test-Path $p.DshBin) -and $existingVersion -ne '未安装' -and $existingVersion -ne '未知') {
        try {
            Test-DshRequiredPeerClosure $p ([string]$existingVersion)
            if (Test-DshVersionAlignment $p ([string]$existingVersion) $false) {
                $reuseAlignedTree = $true
                Append-WizardLog ("现有 DSH 依赖闭包已一致：$existingVersion；跳过重新下载，直接进入 rebuild 与启动校验。")
            }
        } catch {
            Append-WizardLog ('现有依赖树需要重建：' + $_.Exception.Message)
        }
    }

    if ($Repair -and -not $reuseAlignedTree -and (Test-Path (Join-Path $p.CoreRoot 'node_modules'))) {
        Reset-CoreDependencyTree $p '修复模式：清除旧版可能留下的跨版本依赖'
    }

    if ($reuseAlignedTree) {
        $targetVersion = [string]$existingVersion
        $ok = $true
    } else {
        $latest = Get-LatestVersion
        if (-not $latest) { $latest = $TestedDshVersion }
        $targetVersion = [string]$latest
        $targetSpecs = @("@deepseek-ai/dsh@$targetVersion") + @(Get-VersionLockedPeerSpecs $targetVersion)
        Append-WizardLog ("目标 DSH 版本：$targetVersion；所有 dsh-* peer 将锁定到同一版本。")
        $ok = Invoke-NpmWizardAttempt $p $targetSpecs ("安装一致版本闭包 $targetVersion")

        if (-not $ok -and $targetVersion -ne $TestedDshVersion) {
            Reset-CoreDependencyTree $p ("latest $targetVersion 安装失败，回退到已测试版本 $TestedDshVersion")
            $targetVersion = $TestedDshVersion
            $targetSpecs = @("@deepseek-ai/dsh@$targetVersion") + @(Get-VersionLockedPeerSpecs $targetVersion)
            $ok = Invoke-NpmWizardAttempt $p $targetSpecs ("安装已测试一致版本闭包 $targetVersion")
        }
        if (-not $ok) { throw 'DSH Core 安装失败，请查看 npm-install.log。' }
        if (-not (Test-Path $p.DshBin)) { throw 'npm 已完成，但未找到 DSH Core 启动文件。' }
    }

    $installedCore = Get-LocalVersion $p
    if ($installedCore -eq '未安装' -or $installedCore -eq '未知') { throw '无法读取已安装 DSH Core 版本。' }
    $targetVersion = [string]$installedCore
    Test-DshRequiredPeerClosure $p $targetVersion

    # npm's prerelease/caret dependency ranges can still select a newer dsh-*
    # transitive package. Scan the complete installed DeepSeek DSH scope and
    # explicitly pin every mismatch back to the Core version, repeating until
    # the package API closure is coherent.
    if (-not (Repair-DshVersionAlignment $p $targetVersion)) {
        throw 'DSH 依赖版本对齐失败；仍存在与 Core 不同版本的 dsh-* 包。'
    }
    Test-DshRequiredPeerClosure $p $targetVersion
    Test-DshVersionAlignment $p $targetVersion $true | Out-Null

    $rebuildOk = Invoke-NpmWizardRebuild $p
    if (-not $rebuildOk) { Append-WizardLog 'npm rebuild 返回非零状态；将继续通过真实 DSH 启动测试判断环境是否可用。' }
    Append-WizardLog ('DSH Core 文件已安装并完成版本一致性检查：' + (Get-LocalVersion $p))
    Set-WizardProgress 86 '步骤 3/5 · DSH Core 已对齐' ('版本：' + (Get-LocalVersion $p) + '；全部 dsh-* 包已锁定到同一版本，下一步执行真实启动校验。') $false
    Set-WizardStepState 3 'done'
}
function Get-FreeLocalPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback,0)
    try { $listener.Start(); return [int]$listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
function Test-DshSmokeStart($p) {
    $port = Get-FreeLocalPort
    $validationHome = Join-Path $p.Root '.validation-home'
    $out = Join-Path $p.LogRoot 'validation-out.log'
    $err = Join-Path $p.LogRoot 'validation-error.log'
    Remove-Item $validationHome -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $validationHome,$p.LogRoot -Force | Out-Null
    $oldHome = $env:DSH_HOME
    $oldPath = $env:PATH
    $proc = $null
    try {
        $env:DSH_HOME = $validationHome
        $env:PATH = "$($p.NodeRoot);$($p.CoreRoot)\node_modules\.bin;$oldPath"
        $nodeArgs = @('--expose-internals',("`"{0}`"" -f $p.DshBin),'web','--no-open','--port',[string]$port)
        $proc = Start-Process -FilePath $p.NodeExe -ArgumentList $nodeArgs -WorkingDirectory $p.Root -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        $ready = $false
        for($i=0;$i -lt 90;$i++){
            if($proc.HasExited){break}
            if(Test-Port $port){$ready=$true;break}
            Update-WizardLogFromFiles @($out,$err)
            Pump-WizardUi
            Start-Sleep -Milliseconds 500
        }
        if(-not $ready){
            $tail=''
            if(Test-Path $err){$tail=(Get-Content $err -Tail 100 -Encoding UTF8 -ErrorAction SilentlyContinue)-join "`r`n"}
            if(-not $tail -and (Test-Path $out)){$tail=(Get-Content $out -Tail 100 -Encoding UTF8 -ErrorAction SilentlyContinue)-join "`r`n"}
            throw ("DSH 启动校验失败。`r`n" + $tail)
        }
        Append-WizardLog ("真实启动校验通过：http://127.0.0.1:$port")
        return $true
    } finally {
        if($proc -and -not $proc.HasExited){ Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        if($null -eq $oldHome){Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue}else{$env:DSH_HOME=$oldHome}
        $env:PATH=$oldPath
        Start-Sleep -Milliseconds 300
        Remove-Item $validationHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Test-RuntimeInstallation($p) {
    Set-WizardStepState 4 'current'
    Set-WizardProgress 90 '步骤 4/5 · 校验运行环境' '正在检查文件完整性，并启动一个临时 DSH Web 实例进行真实可用性验证…' $true
    if (-not (Test-Path $p.NodeExe)) { throw 'Node.js 未安装完整。' }
    if (-not (Test-Path $p.NpmCli)) { throw 'npm 未安装完整：缺少 npm-cli.js。' }
    if (-not (Test-Path $p.DshBin)) { throw 'DSH Core 启动文件不存在。' }
    $nodeVersion = Get-NodeVersion $p
    $coreVersion = Get-LocalVersion $p
    if ($nodeVersion -in @('未知','未安装')) { throw 'Node.js 版本验证失败。' }
    if ($coreVersion -in @('未知','未安装')) { throw 'DSH Core 版本验证失败。' }
    Append-WizardLog ("Node.js：$nodeVersion")
    Append-WizardLog ("DSH Core：$coreVersion")
    [void](Test-DshSmokeStart $p)
    $marker = [ordered]@{ validatedAt=(Get-Date).ToString('o'); node=$nodeVersion; dsh=$coreVersion }
    $marker | ConvertTo-Json | Set-Content -Path $p.ReadyMarker -Encoding UTF8
    Append-WizardLog '运行环境校验通过，并写入完成标记。'
    Set-WizardProgress 96 '步骤 4/5 · 校验通过' 'Node.js、DSH Core 与真实 Web 启动均已验证。' $false
    Set-WizardStepState 4 'done'
}
function New-RuntimeWizard($p,[bool]$Repair) {
    $wizardXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH Desktop · 运行环境安装" Width="900" Height="650"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#071426" FontFamily="Segoe UI" FontSize="14">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#F7FAFF"/></Style>
    <Style x:Key="ActionButton" TargetType="Button">
      <Setter Property="Foreground" Value="#EAF2FF"/><Setter Property="Background" Value="#132945"/>
      <Setter Property="BorderBrush" Value="#27486D"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="16,9"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="9"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Grid.Column="0" Background="#08192D" BorderBrush="#17324F" BorderThickness="0,0,1,0">
      <Grid Margin="24,28,20,24">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="DSH Desktop" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Text="运行环境安装向导" Foreground="#7890AA" Margin="0,5,0,0"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Margin="0,28,0,0">
          <Border x:Name="Step1Box" Background="#09182B" BorderBrush="#17324F" BorderThickness="1" CornerRadius="10" Padding="11" Margin="0,0,0,9"><StackPanel Orientation="Horizontal"><TextBlock x:Name="Step1Badge" Text="1" Width="26" Height="26" TextAlignment="Center" Padding="0,3,0,0" Background="#18304D"/><StackPanel Margin="11,0,0,0"><TextBlock x:Name="Step1Title" Text="运行位置" FontWeight="SemiBold"/><TextBlock Text="保存 Node 与 DSH Core" Foreground="#67809A" FontSize="11"/></StackPanel></StackPanel></Border>
          <Border x:Name="Step2Box" Background="#09182B" BorderBrush="#17324F" BorderThickness="1" CornerRadius="10" Padding="11" Margin="0,0,0,9"><StackPanel Orientation="Horizontal"><TextBlock x:Name="Step2Badge" Text="2" Width="26" Height="26" TextAlignment="Center" Padding="0,3,0,0" Background="#18304D"/><StackPanel Margin="11,0,0,0"><TextBlock x:Name="Step2Title" Text="Node.js 24" FontWeight="SemiBold"/><TextBlock Text="下载、校验、解压" Foreground="#67809A" FontSize="11"/></StackPanel></StackPanel></Border>
          <Border x:Name="Step3Box" Background="#09182B" BorderBrush="#17324F" BorderThickness="1" CornerRadius="10" Padding="11" Margin="0,0,0,9"><StackPanel Orientation="Horizontal"><TextBlock x:Name="Step3Badge" Text="3" Width="26" Height="26" TextAlignment="Center" Padding="0,3,0,0" Background="#18304D"/><StackPanel Margin="11,0,0,0"><TextBlock x:Name="Step3Title" Text="DSH Core" FontWeight="SemiBold"/><TextBlock Text="npm 安装与依赖解析" Foreground="#67809A" FontSize="11"/></StackPanel></StackPanel></Border>
          <Border x:Name="Step4Box" Background="#09182B" BorderBrush="#17324F" BorderThickness="1" CornerRadius="10" Padding="11" Margin="0,0,0,9"><StackPanel Orientation="Horizontal"><TextBlock x:Name="Step4Badge" Text="4" Width="26" Height="26" TextAlignment="Center" Padding="0,3,0,0" Background="#18304D"/><StackPanel Margin="11,0,0,0"><TextBlock x:Name="Step4Title" Text="环境校验" FontWeight="SemiBold"/><TextBlock Text="确认核心文件可用" Foreground="#67809A" FontSize="11"/></StackPanel></StackPanel></Border>
          <Border x:Name="Step5Box" Background="#09182B" BorderBrush="#17324F" BorderThickness="1" CornerRadius="10" Padding="11"><StackPanel Orientation="Horizontal"><TextBlock x:Name="Step5Badge" Text="5" Width="26" Height="26" TextAlignment="Center" Padding="0,3,0,0" Background="#18304D"/><StackPanel Margin="11,0,0,0"><TextBlock x:Name="Step5Title" Text="完成" FontWeight="SemiBold"/><TextBlock Text="返回工作台" Foreground="#67809A" FontSize="11"/></StackPanel></StackPanel></Border>
        </StackPanel>
        <TextBlock Grid.Row="3" Text="npm 不提供稳定的精确百分比，因此 DSH Core 阶段显示阶段进度、耗时与实时日志。" TextWrapping="Wrap" Foreground="#6F839C" FontSize="11"/>
      </Grid>
    </Border>
    <Grid Grid.Column="1" Margin="32,28,32,26">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="安装 DSH 运行环境" FontSize="26" FontWeight="SemiBold"/>
          <TextBlock x:Name="RuntimeRootText" Foreground="#8FA5BE" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border Grid.Column="1" Background="#112A49" BorderBrush="#214A77" BorderThickness="1" CornerRadius="14" Padding="11,6" VerticalAlignment="Center"><TextBlock x:Name="ElapsedText" Text="已用时 00:00" Foreground="#CFE0F4"/></Border>
      </Grid>
      <StackPanel Grid.Row="1" Margin="0,28,0,0">
        <TextBlock x:Name="PhaseText" Text="准备安装" FontSize="18" FontWeight="SemiBold"/>
        <TextBlock x:Name="DetailText" Text="正在初始化…" Foreground="#8FA5BE" Margin="0,6,0,12" TextWrapping="Wrap"/>
        <ProgressBar x:Name="WizardProgress" Height="8" Minimum="0" Maximum="100" Value="0" Foreground="#397CF7" Background="#10233D" BorderThickness="0"/>
      </StackPanel>
      <Grid Grid.Row="2" Margin="0,22,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="实时安装日志" FontWeight="SemiBold"/><TextBlock Grid.Column="1" Text="可用于判断是否仍在下载 / 安装" Foreground="#67809A" FontSize="11"/></Grid>
      <Border Grid.Row="3" Background="#06111F" BorderBrush="#17324F" BorderThickness="1" CornerRadius="12" Padding="12">
        <TextBox x:Name="LogBox" Background="Transparent" Foreground="#BFD0E5" BorderThickness="0" FontFamily="Consolas" FontSize="12" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </Border>
      <Grid Grid.Row="4" Margin="0,18,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="FooterText" Text="安装期间请保持网络连接。" Foreground="#6F839C" VerticalAlignment="Center"/>
        <Button x:Name="OpenLogButton" Grid.Column="1" Style="{StaticResource ActionButton}" Content="打开日志目录" Margin="0,0,10,0"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal"><Button x:Name="RetryButton" Style="{StaticResource ActionButton}" Content="重试" Visibility="Collapsed" Margin="0,0,10,0"/><Button x:Name="FinishButton" Style="{StaticResource ActionButton}" Content="安装中…" IsEnabled="False"/></StackPanel>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@
    $reader=New-Object System.Xml.XmlNodeReader ([xml]$wizardXaml)
    $wizard=[Windows.Markup.XamlReader]::Load($reader)
    $wizard.Owner=$Window
    $script:WizardWindow=$wizard
    $script:WizardProgress=$wizard.FindName('WizardProgress')
    $script:WizardPhaseText=$wizard.FindName('PhaseText')
    $script:WizardDetailText=$wizard.FindName('DetailText')
    $script:WizardElapsedText=$wizard.FindName('ElapsedText')
    $script:WizardLogBox=$wizard.FindName('LogBox')
    $wizard.FindName('RuntimeRootText').Text = $p.Root
    $openLog=$wizard.FindName('OpenLogButton')
    $retry=$wizard.FindName('RetryButton')
    $finish=$wizard.FindName('FinishButton')
    $footer=$wizard.FindName('FooterText')
    $openLog.Add_Click({ New-Item -ItemType Directory -Path $p.LogRoot -Force|Out-Null; Start-Process explorer.exe $p.LogRoot })
    $retry.Add_Click({ $script:WizardAction='retry'; $script:WizardBusy=$false; $wizard.Close() })
    $finish.Add_Click({ $script:WizardAction='finish'; $script:WizardBusy=$false; $wizard.Close() })
    $wizard.Add_Closing({ param($sender,$e) if($script:WizardBusy){ $e.Cancel=$true; $footer.Text='安装正在进行，请等待当前步骤完成。' } })
    [pscustomobject]@{ Window=$wizard; Retry=$retry; Finish=$finish; Footer=$footer }
}
function Show-RuntimeInstallWizard($s,$p,[bool]$Repair=$false) {
    do {
        $ui=New-RuntimeWizard $p $Repair
        $wizard=$ui.Window
        $script:WizardAction=''
        $script:WizardBusy=$true
        $script:WizardStarted=Get-Date
        foreach($n in 1..5){Set-WizardStepState $n 'pending'}
        Set-WizardStepState 1 'done'
        Append-WizardLog ('运行环境位置：' + $p.Root)
        $Window.IsEnabled=$false
        $wizard.Show()
        $success=$false
        try {
            if (Test-Path $p.NodeExe) {
                Set-WizardStepState 2 'done'
                Set-WizardProgress 46 '步骤 2/5 · Node.js 已存在' ('版本：' + (Get-NodeVersion $p)) $false
                Append-WizardLog ('复用已有 Node.js：' + (Get-NodeVersion $p))
            } else { Install-PortableNode $p }
            if ($Repair -or -not (Test-Path $p.DshBin) -or -not (Test-Path $p.ReadyMarker)) { Install-DshCore $p $true }
            else {
                Set-WizardStepState 3 'done'
                Set-WizardProgress 86 '步骤 3/5 · DSH Core 已存在' ('版本：' + (Get-LocalVersion $p)) $false
                Append-WizardLog ('复用已有 DSH Core：' + (Get-LocalVersion $p))
            }
            Test-RuntimeInstallation $p
            Set-WizardStepState 5 'current'
            Set-WizardProgress 100 '步骤 5/5 · 安装完成' (('DSH Core {0} 已准备完成，可以返回工作台。' -f (Get-LocalVersion $p))) $false
            Append-WizardLog '全部步骤完成。'
            Set-WizardStepState 5 'done'
            $ui.Footer.Text='安装成功。点击“完成”返回工作台。'
            $ui.Finish.Content='完成'
            $ui.Finish.IsEnabled=$true
            $success=$true
        } catch {
            $failedStep = 3
            if (-not (Test-Path $p.NodeExe)) { $failedStep=2 }
            elseif (-not (Test-Path $p.DshBin)) { $failedStep=3 }
            else { $failedStep=4 }
            Set-WizardStepState $failedStep 'error'
            Set-WizardProgress 0 '安装未完成' $_.Exception.Message $false
            Append-WizardLog ('ERROR: ' + $_.Exception.Message)
            if ($_.ScriptStackTrace) { Append-WizardLog ('STACK: ' + $_.ScriptStackTrace) }
            $ui.Footer.Text='安装失败。可打开日志检查详情，或点击“重试”。'
            $ui.Retry.Visibility='Visible'
            $ui.Finish.Content='关闭'
            $ui.Finish.IsEnabled=$true
        } finally {
            $script:WizardBusy=$false
        }
        while($wizard.IsVisible){Pump-WizardUi;Start-Sleep -Milliseconds 120}
        $Window.IsEnabled=$true
        $Window.Activate() | Out-Null
        $action=$script:WizardAction
        $script:WizardWindow=$null;$script:WizardProgress=$null;$script:WizardPhaseText=$null;$script:WizardDetailText=$null;$script:WizardElapsedText=$null;$script:WizardLogBox=$null;$script:WizardStarted=$null
        if($success){return $true}
        if($action -ne 'retry'){return $false}
        $Repair=$true
    } while($true)
}
function Ensure-Runtime($s,$p) {
    if ((Test-Path $p.NodeExe) -and (Test-Path $p.DshBin) -and (Test-Path $p.ReadyMarker)) { return $true }
    return (Show-RuntimeInstallWizard $s $p $false)
}
function Find-Edge {
    $c=@()
    if (${env:ProgramFiles(x86)}) { $c += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:ProgramFiles) { $c += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:LOCALAPPDATA) { $c += (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe') }
    $c | Where-Object { Test-Path $_ } | Select-Object -First 1
}
function Open-App([int]$port) {
    $url="http://127.0.0.1:$port/"
    $edge=Find-Edge
    if ($edge) { Start-Process $edge "--app=$url" | Out-Null } else { Start-Process $url | Out-Null }
}
function Show-Error([string]$headline,[string]$details,$p) {
    $log = if($p){$p.LogRoot}else{$ShellDataRoot}
    $msg = "$headline`r`n`r`n$details`r`n`r`n日志目录：$log"
    [System.Windows.MessageBox]::Show($msg,'DSH Desktop',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null
}
function Start-Dsh([bool]$open=$true) {
    $s=Load-Settings
    if (-not $s.runtimeRoot) {
        [System.Windows.MessageBox]::Show('请先选择 DSH 运行环境位置。','DSH Desktop') | Out-Null
        return
    }
    $p=Get-Paths $s
    try {
        if(-not (Ensure-Runtime $s $p)){ throw 'DSH 运行环境尚未安装完成。' }
        $existing=Get-ManagedPid $p
        if ($existing) { if($open){Open-App ([int]$s.port)}; Refresh-Ui; return }

        $requestedPort = [int]$s.port
        if (Test-Port $requestedPort) {
            $ownerPid = Get-PortOwnerPid $requestedPort
            if ($ownerPid -and (Test-IsManagedDshProcess $ownerPid $p)) {
                Set-Content $p.PidPath $ownerPid -Encoding ASCII
                Set-Status "检测到已运行的 DSH（端口 $requestedPort），已接管" 'ok'
                if($open){Open-App $requestedPort}
                Refresh-Ui
                return
            }
            if ($ownerPid -and (Test-IsAnyDshProcess $ownerPid)) {
                Set-Status "检测到另一个 DSH 已运行在端口 $requestedPort" 'ok'
                if($open){Open-App $requestedPort}
                Refresh-Ui
                return
            }
            $fallbackPort = Find-FreePreferredPort $requestedPort
            $s.port = $fallbackPort
            Save-Settings $s
            Set-Status "端口 $requestedPort 已占用，自动切换到 $fallbackPort" 'busy'
        }
        Set-Status '正在启动 DSH 服务…' 'busy'
        $env:DSH_HOME=$s.dshHome
        $env:PATH="$($p.NodeRoot);$($p.CoreRoot)\node_modules\.bin;$env:PATH"
        New-Item -ItemType Directory -Path $p.LogRoot,$s.dshHome -Force | Out-Null
        $out=Join-Path $p.LogRoot 'dsh-out.log'; $err=Join-Path $p.LogRoot 'dsh-error.log'
        Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
        $work=[Environment]::GetFolderPath('MyDocuments'); if(-not $work){$work=$env:USERPROFILE}
        $nodeArgs=@('--expose-internals',"`"$($p.DshBin)`"",'web','--no-open','--port',[string]$s.port)
        $proc=Start-Process $p.NodeExe -ArgumentList $nodeArgs -WorkingDirectory $work -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        Set-Content $p.PidPath $proc.Id -Encoding ASCII
        $ready=$false
        for($i=0;$i -lt 120;$i++){
            if($proc.HasExited){break}
            if(Test-Port ([int]$s.port)){$ready=$true;break}
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()
        }
        if(-not $ready){
            Remove-Item $p.PidPath -Force -ErrorAction SilentlyContinue
            $tail=''; if(Test-Path $err){$tail=(Get-Content $err -Tail 80 -Encoding UTF8)-join "`r`n"}
            throw "DSH 未能启动。`r`n$tail"
        }
        Set-Status 'DSH 已启动' 'ok'
        if($open){Open-App ([int]$s.port)}
    } catch {
        Set-Status '启动失败' 'error'
        Show-Error 'DSH 启动失败' $_.Exception.Message $p
    } finally { Refresh-Ui }
}
function Stop-Dsh {
    $s=Load-Settings; $p=Get-Paths $s; if(-not $p){return}
    $managedPid=Get-ManagedPid $p
    if($managedPid){ Stop-Process -Id $managedPid -Force -ErrorAction SilentlyContinue; Remove-Item $p.PidPath -Force -ErrorAction SilentlyContinue }
    Refresh-Ui
}
function Repair-Dsh {
    $s=Load-Settings; if(-not $s.runtimeRoot){return}; $p=Get-Paths $s
    try {
        Stop-Dsh
        if(Show-RuntimeInstallWizard $s $p $true){Set-Status '修复完成' 'ok'}
    } catch { Show-Error '修复失败' $_.Exception.Message $p } finally { Refresh-Ui }
}
function Update-Core {
    $s=Load-Settings; if(-not $s.runtimeRoot){return}; $p=Get-Paths $s
    $latest=Get-LatestVersion
    if(-not $latest){ [System.Windows.MessageBox]::Show('无法连接 npm 更新源。','DSH Desktop')|Out-Null; return }
    $local=Get-LocalVersion $p
    if($local -eq $latest){ [System.Windows.MessageBox]::Show("DSH Core 已是最新版本：$local",'DSH Desktop')|Out-Null; return }
    if([System.Windows.MessageBox]::Show("发现新版本：$local → $latest`r`n立即更新？",'DSH Desktop',[System.Windows.MessageBoxButton]::YesNo) -eq 'Yes'){
        Stop-Dsh
        if(Show-RuntimeInstallWizard $s $p $true){Set-Status ('已更新到 ' + (Get-LocalVersion $p)) 'ok'}
        Refresh-Ui
    }
}

$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH Desktop" Width="1080" Height="720" MinWidth="980" MinHeight="650"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip"
        Background="#071426" FontFamily="Segoe UI" FontSize="14">
  <Window.Resources>
    <SolidColorBrush x:Key="ShellBg" Color="#071426"/>
    <SolidColorBrush x:Key="PanelBg" Color="#0D1D33"/>
    <SolidColorBrush x:Key="PanelBgHover" Color="#122844"/>
    <SolidColorBrush x:Key="Stroke" Color="#1C3555"/>
    <SolidColorBrush x:Key="Accent" Color="#4D8DFF"/>
    <SolidColorBrush x:Key="AccentHover" Color="#6AA1FF"/>
    <SolidColorBrush x:Key="Cyan" Color="#35D0FF"/>
    <SolidColorBrush x:Key="TextMain" Color="#F7FAFF"/>
    <SolidColorBrush x:Key="TextSub" Color="#9FB2C9"/>
    <SolidColorBrush x:Key="Muted" Color="#6F839C"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
    </Style>

    <Style x:Key="FluentButton" TargetType="Button">
      <Setter Property="Foreground" Value="#EAF2FF"/>
      <Setter Property="Background" Value="#132945"/>
      <Setter Property="BorderBrush" Value="#27486D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="18,11"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="10" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1A3557"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3C6591"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.82"/>
              </Trigger>              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource FluentButton}">
      <Setter Property="Background" Value="#397CF7"/>
      <Setter Property="BorderBrush" Value="#5C96FF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="10" BorderThickness="1"
                    BorderBrush="#72A6FF">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#4C8CFF" Offset="0"/>
                  <GradientStop Color="#286DE8" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect>
                <DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.28" Color="#2D7CFF"/>
              </Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.92"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.80"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource FluentButton}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#24415F"/>
      <Setter Property="Foreground" Value="#BDD0E5"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#0D1D33"/>
      <Setter Property="BorderBrush" Value="#183453"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Padding" Value="22"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect BlurRadius="24" ShadowDepth="0" Opacity="0.18" Color="#000000"/></Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="Background" Value="#112A49"/>
      <Setter Property="BorderBrush" Value="#214A77"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="10,5"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#071426" Offset="0"/>
        <GradientStop Color="#0A1B31" Offset="0.55"/>
        <GradientStop Color="#071426" Offset="1"/>
      </LinearGradientBrush>
    </Grid.Background>

    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="236"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Left navigation / brand rail -->
    <Border Grid.Column="0" Background="#08192D" BorderBrush="#17324F" BorderThickness="0,0,1,0">
      <Grid Margin="22,24,20,20">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel>
          <Border Width="46" Height="46" CornerRadius="13" HorizontalAlignment="Left">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#4D8DFF" Offset="0"/>
                <GradientStop Color="#35D0FF" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="D" FontSize="24" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="DSH Desktop" FontSize="22" FontWeight="SemiBold" Margin="0,14,0,0"/>
          <TextBlock Text="DeepSeek Harness shell" FontSize="12" Foreground="#7890AA" Margin="0,5,0,0"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Margin="0,30,0,0">
          <Border Background="#112A49" CornerRadius="10" Padding="12,10" Margin="0,0,0,8">
            <StackPanel Orientation="Horizontal">
              <Ellipse Width="8" Height="8" Fill="#4D8DFF" Margin="0,5,10,0"/>
              <TextBlock Text="控制台" FontWeight="SemiBold"/>
            </StackPanel>
          </Border>
          <Border Background="Transparent" CornerRadius="10" Padding="12,10">
            <TextBlock Text="MSIX · v2.3.6" Foreground="#7890AA"/>
          </Border>
        </StackPanel>

        <StackPanel Grid.Row="3">
          <TextBlock Text="第三方桌面封装" Foreground="#6F839C" FontSize="12"/>
          <TextBlock Text="非 DeepSeek 官方产品" Foreground="#6F839C" FontSize="12" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Main content -->
    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <Grid Margin="34,28,36,26">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,20">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="工作台" FontSize="28" FontWeight="SemiBold"/>
            <TextBlock Text="启动、配置并维护本机 DeepSeek Harness 环境" Foreground="#8FA5BE" Margin="0,5,0,0"/>
          </StackPanel>
          <Border Grid.Column="1" Style="{StaticResource Pill}" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#94A3B8" Margin="0,5,8,0"/>
              <TextBlock x:Name="StatusText" Text="服务未启动" Foreground="#DCE9F8" FontWeight="SemiBold"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- Hero / quick actions -->
        <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,0,16">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="DeepSeek Harness" FontSize="20" FontWeight="SemiBold"/>
              <TextBlock Text="本地服务默认仅监听 127.0.0.1；API Key 由 Harness 自己保存。" Foreground="#8FA5BE" Margin="0,7,0,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,17,0,0">
                <Border Background="#0A1729" BorderBrush="#193956" BorderThickness="1" CornerRadius="9" Padding="12,8" Margin="0,0,10,0">
                  <StackPanel><TextBlock Text="DSH Core" Foreground="#7890AA" FontSize="11"/><TextBlock x:Name="CoreVersionText" Text="未安装" FontWeight="SemiBold" Margin="0,3,0,0"/></StackPanel>
                </Border>
                <Border Background="#0A1729" BorderBrush="#193956" BorderThickness="1" CornerRadius="9" Padding="12,8">
                  <StackPanel><TextBlock Text="Node.js" Foreground="#7890AA" FontSize="11"/><TextBlock x:Name="NodeVersionText" Text="未安装" FontWeight="SemiBold" Margin="0,3,0,0"/></StackPanel>
                </Border>
              </StackPanel>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="24,0,0,0">
              <Button x:Name="StartButton" Style="{StaticResource PrimaryButton}" Content="启动 DSH" MinWidth="120"/>
              <Button x:Name="ApiButton" Style="{StaticResource FluentButton}" Content="配置 API" MinWidth="112"/>
              <Button x:Name="StopButton" Style="{StaticResource GhostButton}" Content="停止" MinWidth="90" Margin="0"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Two column cards -->
        <Grid Grid.Row="2" Margin="0,0,0,16">
          <Grid.ColumnDefinitions><ColumnDefinition Width="1.15*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="0.85*"/></Grid.ColumnDefinitions>

          <Border Grid.Column="0" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="运行环境位置" FontSize="17" FontWeight="SemiBold"/>
              <TextBlock Text="Node、DSH Core 与日志可放在你指定的磁盘或目录。" Foreground="#8FA5BE" Margin="0,5,0,16"/>
              <Border Background="#08182B" BorderBrush="#1A3A59" BorderThickness="1" CornerRadius="10" Padding="13,11">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="RuntimePathText" Text="尚未选择" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Foreground="#E8F1FC"/>
                  <Button x:Name="BrowseRuntimeButton" Grid.Column="1" Style="{StaticResource FluentButton}" Content="选择位置" Margin="14,0,0,0" Padding="14,8"/>
                </Grid>
              </Border>
              <TextBlock Text="建议：D:\DSH Desktop 或其他空间充足的普通目录" Foreground="#67809A" FontSize="12" Margin="2,10,0,0"/>
            </StackPanel>
          </Border>

          <Border Grid.Column="2" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="用户数据" FontSize="17" FontWeight="SemiBold"/>
              <TextBlock Text="会话、模型设置与凭据目录" Foreground="#8FA5BE" Margin="0,5,0,16"/>
              <TextBlock x:Name="DshHomeText" Text="~\.dsh" TextTrimming="CharacterEllipsis" Foreground="#DDEAF8" FontWeight="SemiBold" Margin="0,2,0,14"/>
              <Button x:Name="OpenDataButton" Style="{StaticResource GhostButton}" Content="打开数据目录" HorizontalAlignment="Left" Margin="0"/>
            </StackPanel>
          </Border>
        </Grid>

        <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,0,0,16">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="维护与更新" FontSize="17" FontWeight="SemiBold"/>
              <TextBlock Text="DSH Core 独立更新；MSIX 外壳后续可接 App Installer / Microsoft Store 更新。" Foreground="#8FA5BE" Margin="0,6,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="24,0,0,0">
              <Button x:Name="UpdateButton" Style="{StaticResource FluentButton}" Content="检查 Core 更新"/>
              <Button x:Name="RepairButton" Style="{StaticResource FluentButton}" Content="修复 DSH"/>
              <Button x:Name="OpenLogButton" Style="{StaticResource GhostButton}" Content="日志" Margin="0"/>
            </StackPanel>
          </Grid>
        </Border>

        <Grid Grid.Row="4">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Ellipse Width="7" Height="7" Fill="#35D0FF" Margin="0,5,10,0"/>
          <TextBlock Grid.Column="1" Text="隐私：DSH Desktop 不读取或上传你的 API Key；密钥仍由 DeepSeek Harness 自己管理。" Foreground="#6F839C" FontSize="12"/>
        </Grid>
      </Grid>
    </ScrollViewer>
  </Grid>
</Window>
'@

$reader=New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$Window=[Windows.Markup.XamlReader]::Load($reader)
$StatusText=$Window.FindName('StatusText'); $StatusDot=$Window.FindName('StatusDot')
$CoreVersionText=$Window.FindName('CoreVersionText'); $NodeVersionText=$Window.FindName('NodeVersionText')
$RuntimePathText=$Window.FindName('RuntimePathText'); $DshHomeText=$Window.FindName('DshHomeText')
$StartButton=$Window.FindName('StartButton'); $StopButton=$Window.FindName('StopButton'); $ApiButton=$Window.FindName('ApiButton')
$BrowseRuntimeButton=$Window.FindName('BrowseRuntimeButton'); $OpenDataButton=$Window.FindName('OpenDataButton')
$UpdateButton=$Window.FindName('UpdateButton'); $RepairButton=$Window.FindName('RepairButton'); $OpenLogButton=$Window.FindName('OpenLogButton')

$BrowseRuntimeButton.Add_Click({
    $folder=Choose-RuntimeFolder
    if($folder){ $s=Load-Settings; $s.runtimeRoot=$folder; Save-Settings $s; Refresh-Ui }
})
$StartButton.Add_Click({Start-Dsh $true})
$StopButton.Add_Click({Stop-Dsh})
$ApiButton.Add_Click({Start-Dsh $true; [System.Windows.MessageBox]::Show('在 DSH 页面进入“设置 → 模型”，填写 DeepSeek API Key。','配置 API')|Out-Null})
$UpdateButton.Add_Click({Update-Core})
$RepairButton.Add_Click({Repair-Dsh})
$OpenDataButton.Add_Click({$s=Load-Settings; New-Item -ItemType Directory -Path $s.dshHome -Force|Out-Null; Start-Process explorer.exe $s.dshHome})
$OpenLogButton.Add_Click({$s=Load-Settings; $p=Get-Paths $s; if($p){New-Item -ItemType Directory -Path $p.LogRoot -Force|Out-Null; Start-Process explorer.exe $p.LogRoot}else{Start-Process explorer.exe $ShellDataRoot}})
$Window.Add_ContentRendered({
    Refresh-Ui
    $s=Load-Settings
    $justSelected=$false
    if(-not $s.runtimeRoot){
        $folder=Choose-RuntimeFolder
        if($folder){$s.runtimeRoot=$folder;Save-Settings $s;Refresh-Ui;$justSelected=$true}
    }
    if($justSelected){
        $p=Get-Paths $s
        if($p -and (-not (Test-Path $p.NodeExe) -or -not (Test-Path $p.DshBin))){
            [void](Show-RuntimeInstallWizard $s $p $false)
            Refresh-Ui
        }
    }
})
$Window.Add_Closing({ Stop-Dsh })
[void]$Window.ShowDialog()