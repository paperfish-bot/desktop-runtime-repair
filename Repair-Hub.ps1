#Requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$appRepair = Join-Path $PSScriptRoot 'Repair-ChatGPT.ps1'
$animationHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI\ChatGPTFix'
$animationRepair = Join-Path $animationHome 'Repair-Seamless.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-Health([switch]$Full) {
    $appAvailable = Test-Path -LiteralPath $appRepair -PathType Leaf
    $app = [pscustomobject]@{ repairAvailable = $appAvailable; diagnosisCompleted = $null }
    if ($Full -and $appAvailable) {
        $null = & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $appRepair -CheckOnly -NoPause
        $app.diagnosisCompleted = $LASTEXITCODE -eq 0
    }

    $animation = [pscustomobject]@{ installed = $false; enabled = $false; reason = '未安装启动动画（此功能可选）。' }
    if (Test-Path -LiteralPath $animationRepair -PathType Leaf) {
        try {
            $result = & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $animationRepair -CheckOnly
            if ($LASTEXITCODE -ne 0) { throw '动画状态检查失败。' }
            $status = ($result | Select-Object -Last 1) | ConvertFrom-Json
            $animation = [pscustomobject]@{ installed = $true; enabled = [bool]$status.enabled; reason = [string]$status.reason }
        } catch {
            $animation = [pscustomobject]@{ installed = $true; enabled = $false; reason = '动画状态检查失败：' + $_.Exception.Message }
        }
    }
    [pscustomobject]@{ app = $app; animation = $animation }
}

if ($CheckOnly) {
    Get-Health -Full | ConvertTo-Json -Depth 5 -Compress
    exit 0
}

while ($true) {
    Clear-Host
    Write-Host 'Windows 桌面应用启动修复助手' -ForegroundColor Cyan
    try {
        $health = Get-Health
        Write-Host ('官方 App 修复：' + $(if ($health.app.repairAvailable) { '可用，仅在故障时手动运行' } else { '修复文件缺失' }))
        Write-Host ('启动动画：' + $health.animation.reason)
    } catch {
        Write-Host ('状态检查失败：' + $_.Exception.Message) -ForegroundColor Yellow
        $health = $null
    }
    Write-Host ''
    Write-Host '1  修复官方 App 无法启动'
    Write-Host '2  检查或修复启动动画（可选）'
    Write-Host '3  打开官方 App'
    Write-Host '0  退出'
    $choice = Read-Host '请选择'
    switch ($choice) {
        '1' {
            if (Test-Path -LiteralPath $appRepair -PathType Leaf) {
                & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $appRepair
            } else { Write-Host '未找到 App 修复脚本。' -ForegroundColor Yellow }
        }
        '2' {
            if (-not (Test-Path -LiteralPath $animationRepair -PathType Leaf)) {
                Write-Host '尚未安装启动动画；此功能可选。' -ForegroundColor Yellow
            } elseif ($health -and $health.animation.enabled) {
                Write-Host $health.animation.reason
            } else {
                & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $animationRepair -NoPause
            }
        }
        '3' {
            $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($package) {
                Start-Process explorer.exe ('shell:AppsFolder\' + $package.PackageFamilyName + '!App')
            } else { Write-Host '未找到 Microsoft Store 版官方 App。' -ForegroundColor Yellow }
        }
        '0' { exit 0 }
        default { Write-Host '请输入 0–3。' }
    }
    $null = Read-Host '按回车返回菜单'
}
