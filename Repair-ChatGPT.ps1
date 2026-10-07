#Requires -Version 5.1
<#
Repairs only the bundled cua_node runtime cache for OpenAI.Codex.
No chat history, authentication data, application settings, or other runtimes are removed.
Use -CheckOnly for a read-only diagnosis; -NoPause is intended for automated checks.
#>
[CmdletBinding()]
param([switch]$CheckOnly, [switch]$NoPause, [string]$OriginUserSid = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:LogFile = $null
$script:Delegated = $false

function Write-Status([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Assert-NoLink([string]$Path, [string]$Boundary = '') {
    $current = [IO.Path]::GetFullPath($Path)
    $stopAt = ''
    if ($Boundary) { $stopAt = [IO.Path]::GetFullPath($Boundary).TrimEnd('\') }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝操作链接或重定向目录：$current"
            }
        }
        if ($stopAt -and $current.TrimEnd('\') -ieq $stopAt) { break }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Get-ChildPath([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative.Contains(':')) {
        throw "无效的相对路径：$Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "路径超出允许范围：$full" }
    Assert-NoLink $full $base
    return $full
}

function Get-SafeFiles([string]$Root) {
    Assert-NoLink $Root $Root
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "目录内含有链接，已停止：$($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { Write-Output $item }
        }
    }
}

function Get-ChatGPTPackage {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' | Where-Object { $_.InstallLocation } |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package) { throw '当前 Windows 用户未安装 OpenAI.Codex。请先通过 Microsoft Store 安装或更新 ChatGPT。' }
    if (-not (Test-Path -LiteralPath $package.InstallLocation -PathType Container)) { throw 'ChatGPT 安装目录不存在。' }
    return $package
}

function Get-RuntimeInfo([string]$Source) {
    # WindowsApps package directories can legitimately be reparse points.
    # The registered install location is read-only; inspect links inside its runtime only.
    Assert-NoLink $Source $Source
    $manifestPath = Get-ChildPath $Source 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.platform -ne 'windows') { throw '安装包内的 runtime 不是 Windows 版本。' }
    $node = Get-ChildPath $Source ([string]$manifest.node_path)
    $repl = Get-ChildPath $Source ([string]$manifest.node_repl_path)
    $modules = Get-ChildPath $Source ([string]$manifest.node_modules)
    foreach ($path in @($manifestPath, $node, $repl)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 0) { throw "安装包缺少关键文件：$path" }
    }
    if (-not (Test-Path -LiteralPath $modules -PathType Container)) { throw '安装包缺少 node_modules。' }
    $files = @(Get-SafeFiles $Source)
    if ($files.Count -lt 4) { throw '安装包内的 runtime 不完整。' }
    return [pscustomobject]@{ Manifest = $manifest; ManifestPath = $manifestPath; Node = $node; Repl = $repl; Files = $files }
}

function Get-RuntimeId([string]$Source, $Info) {
    # Verified against the installed client's cua_node deployment implementation.
    # Do not infer the current ID from the newest .staging directory: it may be stale.
    $builder = New-Object System.Text.StringBuilder
    foreach ($relative in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')) {
        $file = Get-ChildPath $Source $relative
        $digest = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $null = $builder.Append($relative).Append([char]0).Append($digest).Append([char]0)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digestBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString()))
        return ([BitConverter]::ToString($digestBytes).Replace('-', '').ToLowerInvariant().Substring(0, 16))
    } finally { $sha.Dispose() }
}

function Assert-RuntimeCopy([string]$Source, [string]$Destination, $Files) {
    $prefix = [IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
    foreach ($file in $Files) {
        $relative = $file.FullName.Substring($prefix.Length)
        $target = Get-ChildPath $Destination $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "运行环境缺少文件：$relative" }
        if ((Get-Item -LiteralPath $target).Length -ne $file.Length) { throw "文件大小不匹配：$relative" }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
            throw "文件校验失败：$relative"
        }
    }
}

function Copy-Runtime([string]$Source, [string]$Destination, $Files) {
    Assert-NoLink $Destination
    if (Test-Path -LiteralPath $Destination) { $null = @(Get-SafeFiles $Destination) }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $prefix = [IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
    # Preserve empty directories too, so the destination contains the whole bundled tree.
    foreach ($folder in @(Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force)) {
        $targetFolder = Get-ChildPath $Destination $folder.FullName.Substring($prefix.Length)
        $null = New-Item -ItemType Directory -Path $targetFolder -Force
    }
    # Publish the manifest last. Copy directly to the formal directory to avoid staging rename.
    foreach ($file in @($Files | Sort-Object @{ Expression = { $_.FullName -eq (Join-Path $Source 'manifest.json') } }, FullName)) {
        $target = Get-ChildPath $Destination $file.FullName.Substring($prefix.Length)
        $parent = [IO.Path]::GetDirectoryName($target)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # WindowsApps files can carry package encryption attributes that Copy-Item
                # cannot preserve outside the package. Stream the readable bytes instead.
                $inputStream = [IO.File]::OpenRead($file.FullName)
                try {
                    $outputStream = [IO.File]::Open($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $inputStream.CopyTo($outputStream); $outputStream.Flush() } finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
                break
            }
            catch { if ($attempt -eq 3) { throw }; Start-Sleep -Milliseconds 700 }
        }
    }
}

function Remove-FailedStaging([string]$RuntimeRoot) {
    $rootFull = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
    $leftovers = 0
    foreach ($folder in @(Get-ChildItem -LiteralPath $rootFull -Directory -Force)) {
        if ($folder.Name -notmatch '^\.staging-[a-fA-F0-9]{16}-[a-zA-Z0-9_-]+$') { continue }
        try {
            $targetFull = [IO.Path]::GetFullPath($folder.FullName)
            if ([IO.Path]::GetDirectoryName($targetFull) -ine $rootFull) { throw '临时目录超出了允许清理的范围。' }
            Assert-NoLink $targetFull
            $null = @(Get-SafeFiles $targetFull)
            Remove-Item -LiteralPath $targetFull -Recurse -Force
            Write-Status ('已清理临时目录：' + $folder.Name)
        } catch {
            $leftovers++
            Write-Status ('临时目录暂时无法清理，已保留：' + $folder.Name + '；' + $_.Exception.Message)
        }
    }
    return $leftovers
}

function Stop-ChatGPT {
    $sessionId = (Get-Process -Id $PID).SessionId
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $processes = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        if (-not $processes.Count) { return }
        foreach ($process in $processes) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
            catch { if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) { throw } }
        }
        Start-Sleep -Milliseconds 700
    }
    if (@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }).Count) {
        throw 'ChatGPT 进程未完全退出，已停止修复。请关闭 ChatGPT 后重试。'
    }
}

function Start-ChatGPT($Package) {
    [xml]$appManifest = Get-Content -LiteralPath (Join-Path $Package.InstallLocation 'AppxManifest.xml') -Raw
    $app = @($appManifest.Package.Applications.Application) | Where-Object { $_.Executable -match '(?i)(^|[/\\])ChatGPT\.exe$' } | Select-Object -First 1
    if (-not $app) { throw '未找到 ChatGPT 的 Windows 应用启动入口。' }
    $appId = $Package.PackageFamilyName + '!' + $app.Id
    # Explorer activates the registered app in the signed-in user's desktop session.
    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute('explorer.exe', ('shell:AppsFolder\' + $appId), '', 'open', 1)
    $sessionId = (Get-Process -Id $PID).SessionId
    $deadline = (Get-Date).AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 1000
        $running = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        if (@($running | Where-Object { $_.MainWindowHandle -ne 0 }).Count) { return $true }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-ChatGPTRepair {
    $localRoot = [Environment]::GetFolderPath('LocalApplicationData')
    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($OriginUserSid -and $OriginUserSid -ne $currentUserSid) {
        throw '请使用启动修复助手的 Windows 账号确认管理员权限；不要输入其他账号。已停止修复。'
    }
    $configPath = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $config.LocalAppData -ine $localRoot) {
            throw '请使用创建快捷方式的 Windows 账号运行；不要在提权窗口输入其他账号。'
        }
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $CheckOnly -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $argsText = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        $argsText += ' -OriginUserSid "' + $currentUserSid + '"'
        if ($NoPause) { $argsText += ' -NoPause' }
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $argsText
        $script:Delegated = $true
        return
    }
    $package = Get-ChatGPTPackage
    $source = Join-Path $package.InstallLocation 'app\resources\cua_node'
    $info = Get-RuntimeInfo $source
    $runtimeId = Get-RuntimeId $source $info
    if ($runtimeId -notmatch '^[a-f0-9]{16}$') { throw '无法可靠确定 runtime 编号，已停止。' }
    $runtimeRoot = Join-Path $localRoot 'OpenAI\Codex\runtimes\cua_node'
    Assert-NoLink $runtimeRoot
    $destination = Get-ChildPath $runtimeRoot $runtimeId
    Write-Status ('ChatGPT 版本：' + $package.Version)
    Write-Status ('安装位置：' + $package.InstallLocation)
    Write-Status ('运行环境编号：' + $runtimeId)
    Write-Status ('修复目标：' + $destination)
    Write-Status ('官方运行环境文件数：' + $info.Files.Count)
    if ($CheckOnly) {
        $staging = @()
        if (Test-Path -LiteralPath $runtimeRoot -PathType Container) { $staging = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force | Where-Object { $_.Name -like '.staging-*' }) }
        Write-Status ('失败临时目录数：' + $staging.Count)
        if (Test-Path -LiteralPath $destination -PathType Container) {
            try { Assert-RuntimeCopy $source $destination $info.Files; Write-Status '现有正式运行环境完整，所有文件校验通过。' }
            catch { Write-Status ('现有正式运行环境需要修复：' + $_.Exception.Message) }
        } else { Write-Status '当前版本所需的正式运行环境尚不存在。' }
        Write-Status '只检查已完成。未关闭应用、未更改运行环境、未清理任何目录。'
        return
    }
    $logRoot = Join-Path $PSScriptRoot 'Logs'
    Assert-NoLink $logRoot
    $null = New-Item -ItemType Directory -Path $logRoot -Force
    $script:LogFile = Join-Path $logRoot ('Repair-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
    Write-Status ('开始修复 ChatGPT ' + $package.Version + '，runtime=' + $runtimeId)
    Write-Status '正在关闭 ChatGPT。聊天记录和账号数据不会被删除。'
    Stop-ChatGPT
    $freshPackage = Get-ChatGPTPackage
    if ($freshPackage.PackageFullName -ne $package.PackageFullName) { throw 'ChatGPT 正在更新，安装版本已变化。请等待更新完成后重新运行。' }
    $needsCopy = $true
    if (Test-Path -LiteralPath $destination -PathType Container) {
        try { Assert-RuntimeCopy $source $destination $info.Files; $needsCopy = $false } catch { Write-Status ('发现不完整文件：' + $_.Exception.Message) }
    }
    if ($needsCopy) {
        Write-Status '正在从官方安装包复制完整运行环境……'
        Copy-Runtime $source $destination $info.Files
    } else { Write-Status '现有运行环境完整，保留已校验的文件。' }
    Write-Status '正在校验所有文件……'
    Assert-RuntimeCopy $source $destination $info.Files
    if ((Get-RuntimeId $source (Get-RuntimeInfo $source)) -ne $runtimeId) { throw '修复期间安装包发生变化，请重新运行。' }
    Write-Status '运行环境完整性校验通过。'
    $leftovers = Remove-FailedStaging $runtimeRoot
    Write-Status '正在重新启动 ChatGPT……'
    if (Start-ChatGPT $package) { Write-Status '修复完成，已检测到 ChatGPT 窗口。' }
    else { Write-Status '运行环境已修复并已发送启动请求，但尚未检测到窗口；请稍等或从开始菜单打开 ChatGPT。如果仍打不开，原因可能不止运行环境。' }
    if ($leftovers) { Write-Status '有临时目录被占用，已保留，不影响已验证的正式运行环境。' }
    Write-Status ('修复日志：' + $script:LogFile)
}

$exitCode = 0
$mutex = $null
$ownsMutex = $false
try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $CheckOnly -and $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $mutex = New-Object System.Threading.Mutex($false, ('Local\ChatGPTFix-' + $sid))
        try { $ownsMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw '修复程序已经在运行，请等待它完成。' }
    }
    Invoke-ChatGPTRepair
} catch {
    $exitCode = 1
    Write-Host ('修复未完成：' + $_.Exception.Message) -ForegroundColor Red
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value ($_ | Out-String) -Encoding UTF8 }
    Write-Host '没有删除聊天记录或账号数据。请保留此窗口中的错误信息。'
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
if (-not $NoPause -and -not $CheckOnly -and -not $script:Delegated) { $null = Read-Host '按回车关闭窗口' }
exit $exitCode
