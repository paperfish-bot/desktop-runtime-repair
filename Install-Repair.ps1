#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoPause,
    [string]$InstallDirectory = '',
    [string]$DesktopDirectory = ''
)

$ErrorActionPreference = 'Stop'
$appId = 'paperfish-bot/desktop-runtime-repair'
$version = '1.0.1'
$shortcutName = '霜璃修复助手.lnk'
$files = @(
    'Repair-ChatGPT.ps1', 'Repair-Hub.ps1', 'Start-Repair.cmd',
    'Install-Repair.ps1', 'Install-Repair.cmd',
    'README.md', 'LICENSE', 'CHANGELOG.md',
    'assets\shuangli-icon-rounded.png', 'assets\shuangli-icon-rounded.ico'
)

function Get-FullDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '无法找到当前用户的安装位置或桌面。' }
    [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
}

function Assert-RegularPath([string]$Path, [switch]$Directory) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw ('为避免覆盖其他位置，已停止安装：' + $Path)
    }
    if ($item.PSIsContainer -ne [bool]$Directory) { throw ('文件或文件夹类型不正确：' + $Path) }
}

function Set-InstalledFile([string]$Source, [string]$Target, [string]$Backup, $Changes) {
    Assert-RegularPath $Target
    $hadFile = Test-Path -LiteralPath $Target -PathType Leaf
    if ($hadFile) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Backup))
        Copy-Item -LiteralPath $Target -Destination $Backup -Force
    }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target))
    $Changes.Add([pscustomobject]@{ target = $Target; backup = $Backup; existed = $hadFile })
    Copy-Item -LiteralPath $Source -Destination $Target -Force
    if ((Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Target).Hash) {
        throw ('复制后的文件校验失败：' + [IO.Path]::GetFileName($Target))
    }
}

function Invoke-Install {
    if (-not $InstallDirectory) {
        $InstallDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Paperfish\DesktopRuntimeRepair'
    }
    if (-not $DesktopDirectory) { $DesktopDirectory = [Environment]::GetFolderPath('DesktopDirectory') }
    $destination = Get-FullDirectory $InstallDirectory
    $desktop = Get-FullDirectory $DesktopDirectory
    $source = Get-FullDirectory $PSScriptRoot
    if ($destination -eq [IO.Path]::GetPathRoot($destination).TrimEnd([char[]]'\/') -or
        $destination -eq $source -or $source.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '安装位置不能是磁盘根目录、当前发布包目录或它的上级目录。'
    }

    Assert-RegularPath $destination -Directory
    Assert-RegularPath (Join-Path $destination 'assets') -Directory
    $statePath = Join-Path $destination 'install-state.json'
    if ((Test-Path -LiteralPath $destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) {
        Assert-RegularPath $statePath
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw '安装位置已有其他文件，已停止安装。' }
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.appId -ne $appId) { throw '安装位置不属于本修复助手，已停止安装。' }
    }

    foreach ($relative in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) {
            throw ('发布包文件不完整，请重新解压：' + $relative)
        }
        Assert-RegularPath (Join-Path $destination $relative)
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $destination 'Repair-Hub.ps1') + '"'
    $icon = (Join-Path $destination 'assets\shuangli-icon-rounded.ico') + ',0'
    $shortcutPath = Join-Path $desktop $shortcutName
    Assert-RegularPath $shortcutPath
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        $existing = $shell.CreateShortcut($shortcutPath)
        if ($existing.TargetPath -ne $powershell -or $existing.Arguments -ne $arguments -or $existing.WorkingDirectory -ne $destination) {
            throw '桌面已有同名的其他快捷方式，已停止安装。请先给那个快捷方式改名。'
        }
    }

    $parent = [IO.Path]::GetDirectoryName($destination)
    $transaction = Join-Path $parent ('.DesktopRuntimeRepair-install-' + [Guid]::NewGuid().ToString('N'))
    $payload = Join-Path $transaction 'payload'
    $backup = Join-Path $transaction 'backup'
    $destinationExisted = Test-Path -LiteralPath $destination -PathType Container
    $assetsDirectory = Join-Path $destination 'assets'
    $assetsExisted = Test-Path -LiteralPath $assetsDirectory -PathType Container
    $changes = New-Object 'System.Collections.Generic.List[object]'
    $null = [IO.Directory]::CreateDirectory($payload)
    try {
        foreach ($relative in $files) {
            $staged = Join-Path $payload $relative
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($staged))
            Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $staged
            if ((Get-FileHash -LiteralPath $staged).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source $relative)).Hash) {
                throw ('安装准备校验失败：' + $relative)
            }
        }
        $stagedShortcut = Join-Path $transaction $shortcutName
        $shortcut = $shell.CreateShortcut($stagedShortcut)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $destination
        $shortcut.IconLocation = $icon
        $shortcut.WindowStyle = 1
        $shortcut.Description = 'Windows 桌面应用启动修复助手'
        $shortcut.Save()
        $saved = $shell.CreateShortcut($stagedShortcut)
        if ($saved.TargetPath -ne $powershell -or $saved.Arguments -ne $arguments -or $saved.IconLocation -ne $icon) {
            throw '桌面快捷方式准备失败，已停止安装。'
        }
        $newState = [pscustomobject]@{ appId = $appId; version = $version; shortcut = $shortcutName }
        $newState | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'install-state.json') -Encoding UTF8
        foreach ($relative in ($files + @('install-state.json'))) {
            Set-InstalledFile (Join-Path $payload $relative) (Join-Path $destination $relative) (Join-Path $backup $relative) $changes
        }
        Set-InstalledFile $stagedShortcut $shortcutPath (Join-Path $backup $shortcutName) $changes
    } catch {
        $failure = $_
        for ($index = $changes.Count - 1; $index -ge 0; $index--) {
            $change = $changes[$index]
            try {
                if ($change.existed) {
                    Copy-Item -LiteralPath $change.backup -Destination $change.target -Force
                } elseif (Test-Path -LiteralPath $change.target -PathType Leaf) {
                    Remove-Item -LiteralPath $change.target -Force
                }
            } catch {
                Write-Warning ('未能恢复文件，请保留安装备份：' + $transaction)
                $transaction = $null
            }
        }
        foreach ($created in @(
            [pscustomobject]@{ path = $assetsDirectory; existed = $assetsExisted },
            [pscustomobject]@{ path = $destination; existed = $destinationExisted }
        )) {
            if (-not $created.existed -and (Test-Path -LiteralPath $created.path -PathType Container)) {
                try {
                    if (@(Get-ChildItem -LiteralPath $created.path -Force).Count -eq 0) { [IO.Directory]::Delete($created.path) }
                } catch { Write-Warning '新建的空文件夹未清理，可稍后手动处理。' }
            }
        }
        throw $failure
    } finally {
        if ($transaction -and (Test-Path -LiteralPath $transaction)) {
            try {
                $resolved = [IO.Path]::GetFullPath($transaction)
                if ([IO.Path]::GetDirectoryName($resolved) -ne $parent -or
                    [IO.Path]::GetFileName($resolved) -notmatch '^\.DesktopRuntimeRepair-install-[a-f0-9]{32}$') {
                    throw '临时文件夹路径核对失败。'
                }
                $items = @(Get-Item -LiteralPath $resolved -Force) + @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
                if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
                    throw '临时文件夹内存在链接。'
                }
                Remove-Item -LiteralPath $resolved -Recurse -Force
            } catch { Write-Warning '安装临时文件未清理，可稍后手动处理。' }
        }
    }
    Write-Host ''
    Write-Host ('安装完成：v' + $version) -ForegroundColor Green
    Write-Host '桌面已创建“霜璃修复助手”图标。以后双击这个图标即可打开修复菜单。'
    Write-Host '工具已复制到固定位置，下载的 ZIP 和解压包可以删除。'
    Write-Host '更新时，解压新版本，再运行一次 Install-Repair.cmd 即可。'
}

$exitCode = 0
$mutex = $null
$ownsMutex = $false
try {
    $lockDirectory = $InstallDirectory
    if (-not $lockDirectory) {
        $lockDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Paperfish\DesktopRuntimeRepair'
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-FullDirectory $lockDirectory).ToUpperInvariant()))
        $lockId = [BitConverter]::ToString($digest).Replace('-', '')
    } finally { $hasher.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\Paperfish-Repair-Install-' + $lockId))
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw '另一个安装窗口正在处理，请等它完成后再运行。' }
    Invoke-Install
} catch {
    Write-Host ('安装失败：' + $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($mutex) {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
if (-not $NoPause) { $null = Read-Host '按回车关闭窗口' }
exit $exitCode
