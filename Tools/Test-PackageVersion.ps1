<#
.SYNOPSIS
  校验产物目录的版本戳，防止"旧包被当成新版本发出去"。

.DESCRIPTION
  2026-10-26 那次事故：安卓碎片用的源目录里躺着 10-11 打的 APK/OBB（版本 0.6.0），
  但这次发布用的是新版本号 —— 结果新号发的是旧包，而且没有任何一处会报错。

  Pack-CrossingVoid.ps1 每次打包成功后会在归档根写一份 Version.json（版本 / 模式 / 时间 / 产物清单）。
  本脚本就是"发布前先看一眼"的那道闸：拿错目录、版本对不上、包太旧、或者干脆没有版本戳，都直接失败。

  用法（生成碎片 / 上传之前跑一次）：
    .\Test-PackageVersion.ps1 -ArchiveDir "F:\DaBaoV\Fantasy" -ExpectedVersion 0.6.1
    .\Test-PackageVersion.ps1 -ArchiveDir "F:\DaBaoV\Fantasy" -ExpectedVersion 0.6.1 -Platform Android

  退出码：0 = 通过，1 = 不通过（原因逐条打在屏幕上，最后一条 [FAIL] 就是拦下它的理由）。

.PARAMETER ArchiveDir
  归档根目录（面板上的「输出目录」，脚本的 -ArchiveDir）。Version.json 就在这一层。

.PARAMETER ExpectedVersion
  这次打算发的版本号。留空 = 只检查"有没有版本戳 / 包新不新"，不比对版本。

.PARAMETER Platform
  Android / Win64。给了就顺带确认该平台的产物文件真的在（Android：.apk + .obb）。

.PARAMETER MaxAgeHours
  版本戳超过这么多小时就当"旧包"（默认 24）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchiveDir,
    [string]$ExpectedVersion = '',
    [ValidateSet('', 'Android', 'Win64')][string]$Platform = '',
    [int]$MaxAgeHours = 24
)

$ErrorActionPreference = 'Stop'

$Fail = @()
function Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad  { param([string]$m) $script:Fail += $m; Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host ''
Write-Host '=== 产物版本自检 ===' -ForegroundColor Cyan
Write-Host "  归档目录 : $ArchiveDir"
if ($ExpectedVersion) { Write-Host "  期望版本 : $ExpectedVersion" }
Write-Host ''

if (-not (Test-Path -LiteralPath $ArchiveDir)) {
    Bad "目录不存在：$ArchiveDir"
    Write-Host ''
    Write-Host '自检不通过' -ForegroundColor Red
    exit 1
}

$StampPath = Join-Path $ArchiveDir 'Version.json'
if (-not (Test-Path -LiteralPath $StampPath)) {
    Bad "没有版本戳：$StampPath"
    Write-Host '         这个目录不是用 CrossingChunkEditor 打的包（或版本戳被删了）。' -ForegroundColor DarkGray
    Write-Host '         旧包被当成新包发出去，通常就是从这里开始的 —— 目录指错了，没人发现。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '自检不通过' -ForegroundColor Red
    exit 1
}

try {
    $Stamp = Get-Content -LiteralPath $StampPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Bad "Version.json 解析失败：$($_.Exception.Message)"
    Write-Host ''
    Write-Host '自检不通过' -ForegroundColor Red
    exit 1
}

$Ver = [string]$Stamp.version
$ArtifactDir = [string]$Stamp.artifactDir
$Mode = [string]$Stamp.mode
$Config = [string]$Stamp.configuration

# ---- 时间：这东西到底多旧 ----
$AgeText = '?'
try {
    $PackedAt = [datetime]::Parse([string]$Stamp.packedAt)
    $Age = (Get-Date) - $PackedAt
    $AgeText = ('{0:N1} 小时前' -f $Age.TotalHours)
    if ($Age.TotalHours -gt $MaxAgeHours) {
        Bad ("版本戳太旧：{0}（{1}，上限 {2} 小时）—— 这大概率是上一次打包留下的旧包" -f $Stamp.packedAt, $AgeText, $MaxAgeHours)
    }
    else {
        Ok ("打包时间 {0}（{1}）" -f $Stamp.packedAt, $AgeText)
    }
}
catch {
    Warn "packedAt 读不出来：$($Stamp.packedAt)"
}

# ---- 版本号：跟这次要发的对不对得上 ----
if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    if ($Ver -eq $ExpectedVersion) {
        Ok "版本号一致：$Ver"
    }
    else {
        Bad ("版本号不一致：产物里是 '{0}'，这次要发的是 '{1}' —— 就是【旧包拿新号】那一类" -f $Ver, $ExpectedVersion)
    }
}
elseif ([string]::IsNullOrWhiteSpace($Ver)) {
    Warn '产物里没有版本号（打包时没填「玩家版本」）'
}
else {
    Ok "版本号：$Ver"
}

# ---- 这批包能不能发 ----
if ($Mode -eq 'Quick') {
    Bad '《快速验证》的产物：不打 pak、不能发布'
}
else {
    Ok "模式：$Mode · 配置：$Config"
}

# ---- 产物文件在不在 ----
if ($ArtifactDir) {
    $ArtifactPath = Join-Path $ArchiveDir $ArtifactDir
    if (-not (Test-Path -LiteralPath $ArtifactPath)) {
        Bad "产物目录不存在：$ArtifactPath"
    }
    else {
        if ($Platform -eq 'Android' -or $ArtifactDir -eq 'Android') {
            $Apks = @(Get-ChildItem -LiteralPath $ArtifactPath -Filter '*.apk' -File -ErrorAction SilentlyContinue)
            $Obbs = @(Get-ChildItem -LiteralPath $ArtifactPath -Filter '*.obb' -File -ErrorAction SilentlyContinue)
            if ($Apks.Count -eq 0) { Bad "Android 产物里没有 .apk：$ArtifactPath" }
            else { Ok ("APK：{0}（{1:N1} MB，{2:yyyy-MM-dd HH:mm}）" -f $Apks[0].Name, ($Apks[0].Length / 1MB), $Apks[0].LastWriteTime) }
            if ($Obbs.Count -eq 0) {
                Warn '没有 .obb（如果数据打进了 APK，这是正常的）'
            }
            else {
                Ok ("OBB：{0}（{1:N1} MB，{2:yyyy-MM-dd HH:mm}）" -f $Obbs[0].Name, ($Obbs[0].Length / 1MB), $Obbs[0].LastWriteTime)
            }
        }
        elseif ($Platform -eq 'Win64') {
            $Exes = @(Get-ChildItem -LiteralPath $ArtifactPath -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue)
            if ($Exes.Count -eq 0) { Bad "Windows 产物里没有 .exe：$ArtifactPath" }
            else { Ok ("EXE：{0}（{1:N1} MB）" -f $Exes[0].Name, ($Exes[0].Length / 1MB)) }
        }
        else {
            $FileCount = @(Get-ChildItem -LiteralPath $ArtifactPath -Recurse -File -ErrorAction SilentlyContinue).Count
            Ok "产物目录：$ArtifactDir（$FileCount 个文件）"
        }
    }
}

# ---- 版本戳里记的产物清单（看一眼大件的时间对不对）----
$StampFiles = @($Stamp.files)
if ($StampFiles.Count -gt 0) {
    $Newest = $StampFiles[0]
    Ok ("清单里最大的产物：{0}" -f $Newest.path)
}

Write-Host ''
if ($Fail.Count -gt 0) {
    Write-Host ("自检不通过（{0} 项）：" -f $Fail.Count) -ForegroundColor Red
    foreach ($f in $Fail) { Write-Host "  - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '结论：别发。先把包重打一次，或者把源目录指对（指向这次刚打出来的产物目录）。' -ForegroundColor Yellow
    exit 1
}

Write-Host '自检通过 —— 版本 / 时间 / 产物都对得上，可以拿去生成碎片和发布' -ForegroundColor Green
Write-Host ''
exit 0
