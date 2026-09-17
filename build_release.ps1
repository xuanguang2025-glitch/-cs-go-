#Requires -Version 5.1
[CmdletBinding()]
param([string]$Version = "1.0.0.0")

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = "1.0.0.0" }
Set-Location -LiteralPath $PSScriptRoot

$ProjectDir = $PSScriptRoot
$ToolsDir = Join-Path (Split-Path $ProjectDir -Parent) ".tools"
$BuildDir = Join-Path $ProjectDir "build"
$OutExe = Join-Path $BuildDir "PROJECT_STRIKE.exe"
$OverlayBin = Join-Path $BuildDir "_overlay.bin"
$OverlayTool = Join-Path $ProjectDir "overlay_tool.py"
$Icon = Join-Path $ProjectDir "icon\game.ico"

function Quote-NativeArg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-Captured([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory = $ProjectDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-NativeArg ([string]$_) }) -join " ")
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Invoke-NativeNoCapture([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory = $ProjectDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-NativeArg ([string]$_) }) -join " ")
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Write-Step([string]$Number, [string]$Text) {
    Write-Host "[$Number] $Text" -ForegroundColor Cyan
}

$engine = Join-Path $ToolsDir "GodotSteam_Editor.exe"
if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $ToolsDir "Godot441.exe" }
if (-not (Test-Path -LiteralPath $engine)) { throw "未找到 Godot 引擎: $ToolsDir" }
if (-not (Test-Path -LiteralPath $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null }

$pythonCandidates = @(
    "C:\Users\徐浩然\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe",
    "C:\Users\徐浩然\.workbuddy-ai\binaries\python\versions\3.14.4\python.exe",
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python314\python.exe")
)
$Python = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$rceditCandidates = @(
    "C:\GodotTools\rcedit.exe",
    (Join-Path $ToolsDir "rcedit-x64.exe")
)
$Rcedit = $rceditCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host " PROJECT STRIKE Release Build  (v$Version)" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "  引擎 : $engine" -ForegroundColor DarkGray

Write-Step "1/5" "写入版本号 $Version"
$presetPath = Join-Path $ProjectDir "export_presets.cfg"
$preset = [System.IO.File]::ReadAllText($presetPath)
$preset = [regex]::Replace($preset, 'application/file_version="[^"]*"', ('application/file_version="' + $Version + '"'))
$preset = [regex]::Replace($preset, 'application/product_version="[^"]*"', ('application/product_version="' + $Version + '"'))
[System.IO.File]::WriteAllText($presetPath, $preset, (New-Object System.Text.UTF8Encoding($false)))

Write-Step "2/5" "导出 Windows 发布版"
if (Test-Path -LiteralPath $OutExe) { [System.IO.File]::Delete($OutExe) }
$godotCode = Invoke-NativeNoCapture $engine @("--headless", "--path", $ProjectDir, "--export-release", "Windows Desktop", $OutExe)
if (-not (Test-Path -LiteralPath $OutExe)) { throw "Godot 导出失败，未生成 $OutExe (exit=$godotCode)" }

Write-Step "3/5" "保护内嵌 PCK并注入资源"
$overlayOffset = $null
$overlaySaved = $false
if ($Python -and (Test-Path -LiteralPath $OverlayTool)) {
    $save = Invoke-Captured $Python @($OverlayTool, "save", $OutExe, $OverlayBin)
    if ($save.ExitCode -eq 0) {
        foreach ($line in ($save.StdOut -split "`r?`n")) {
            if ($line -match '^OFFSET=(\d+)$') { $overlayOffset = [int64]$Matches[1] }
        }
        $overlaySaved = ($null -ne $overlayOffset)
        if ($overlaySaved) { Write-Host "      PCK 已备份 offset=$overlayOffset" -ForegroundColor DarkGray }
    } else {
        Write-Host "      [WARN] PCK 备份失败: $($save.StdErr.Trim())" -ForegroundColor Yellow
    }
} else {
    Write-Host "      [WARN] 未找到 Python 或 overlay_tool.py，跳过 PE 资源注入" -ForegroundColor Yellow
}

if ($Rcedit -and $overlaySaved) {
    $resourceArgs = @($OutExe, "--set-file-version", $Version, "--set-product-version", $Version,
        "--set-version-string", "CompanyName", "PROJECT STRIKE",
        "--set-version-string", "ProductName", "PROJECT STRIKE",
        "--set-version-string", "FileDescription", "PROJECT STRIKE - 5v5 Tactical FPS",
        "--set-version-string", "LegalCopyright", "Copyright (c) 2026 PROJECT STRIKE")
    if (Test-Path -LiteralPath $Icon) { $resourceArgs += @("--set-icon", $Icon) }
    $resource = Invoke-Captured $Rcedit $resourceArgs
    if ($resource.ExitCode -ne 0) { Write-Host "      [WARN] 资源注入失败: $($resource.StdErr.Trim())" -ForegroundColor Yellow }
    $restore = Invoke-Captured $Python @($OverlayTool, "restore", $OutExe, $OverlayBin, [string]$overlayOffset)
    if ($restore.ExitCode -ne 0) { throw "内嵌 PCK 还原失败: $($restore.StdErr.Trim())" }
    Write-Host "      PCK 已还原" -ForegroundColor DarkGray
} elseif (-not $overlaySaved) {
    Write-Host "      [跳过] 未能保护 PCK，不修改 PE；保留可启动原始导出" -ForegroundColor Yellow
} else {
    Write-Host "      [跳过] 未找到 rcedit；保留可启动原始导出" -ForegroundColor Yellow
}

if ($Python -and (Test-Path -LiteralPath $OverlayTool)) {
    $check = Invoke-Captured $Python @($OverlayTool, "check", $OutExe)
    if ($check.ExitCode -eq 0) {
        Write-Host "      PCK 完整性校验通过" -ForegroundColor Green
    } else {
        Write-Host "      [WARN] PCK 校验失败，请勿分发该 exe" -ForegroundColor Yellow
        $check.StdOut.TrimEnd() | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
}
if (Test-Path -LiteralPath $OverlayBin) { [System.IO.File]::Delete($OverlayBin) }

Write-Step "4/5" "部署 Steamworks 运行时"
$steamDll = Join-Path $ToolsDir "steam_api64.dll"
if (-not (Test-Path -LiteralPath $steamDll)) { $steamDll = Join-Path $ProjectDir "steam_api64.dll" }
if (Test-Path -LiteralPath $steamDll) { Copy-Item -LiteralPath $steamDll -Destination (Join-Path $BuildDir "steam_api64.dll") -Force }
$appid = Join-Path $ProjectDir "steam_appid.txt"
if (Test-Path -LiteralPath $appid) { Copy-Item -LiteralPath $appid -Destination (Join-Path $BuildDir "steam_appid.txt") -Force }

Write-Step "5/5" "完成"
$sizeMB = [math]::Round((Get-Item -LiteralPath $OutExe).Length / 1MB, 1)
Write-Host "     产物 : $OutExe" -ForegroundColor White
Write-Host "     大小 : $sizeMB MB" -ForegroundColor White
Write-Host "     AppID: 480  (Spacewar 测试值, 上架前必须替换)" -ForegroundColor Yellow
Write-Host ""
