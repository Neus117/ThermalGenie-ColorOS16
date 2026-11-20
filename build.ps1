# Build Thermal Genie module zip from src\
# Usage:  powershell -File .\build.ps1   （Windows PowerShell 5.1 或 pwsh 7 均可）
#
# 注意：zip 条目必须用 "/" 分隔。
# Windows 的 [ZipFile]::CreateFromDirectory 会写 "\"，在 Android 上反斜杠会变成
# 文件名的普通字符（解出来是 "bin\genie.sh" 这个文件），安装器就找不到 bin/genie.sh。
# 所以这里手工建条目，并在打包后自检。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root 'src'
$dist = Join-Path $root 'dist'

if (-not (Test-Path (Join-Path $src 'module.prop')))   { throw 'src\module.prop not found' }
if (-not (Test-Path (Join-Path $src 'bin\genie.sh')))  { throw 'src\bin\genie.sh not found' }

$prop = Get-Content (Join-Path $src 'module.prop') -Raw
$m = [regex]::Match($prop, '(?m)^\s*version\s*=\s*(.+)$')
if (-not $m.Success) { throw 'version not found in module.prop' }
$ver = $m.Groups[1].Value.Trim()

New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist ("Thermal-Genie-$ver.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::Create)
try {
    $arch = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $files = Get-ChildItem -Path $src -Recurse -File | Sort-Object FullName
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($src.Length + 1).Replace('\', '/')
            $entry = $arch.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $f.LastWriteTime
            $es  = $entry.Open()
            $ins = [System.IO.File]::OpenRead($f.FullName)
            try { $ins.CopyTo($es) } finally { $ins.Dispose(); $es.Dispose() }
        }
    } finally { $arch.Dispose() }
} finally { $fs.Dispose() }

# ---- 打包后自检：不许有反斜杠，必须有 bin/genie.sh ----
$chk = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $bad = @($chk.Entries | Where-Object { $_.FullName.Contains('\') })
    if ($bad.Count -gt 0) { throw ('zip 条目里有反斜杠: ' + ($bad.FullName -join ', ')) }
    $need = @('module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'action.sh', 'uninstall.sh', 'config.conf', 'bin/genie.sh')
    $have = @($chk.Entries | ForEach-Object { $_.FullName })
    foreach ($n in $need) { if (-not ($have -contains $n)) { throw ("zip 里缺少条目 $n") } }
} finally { $chk.Dispose() }

$fi = Get-Item $zip
Write-Host ("built : " + $fi.FullName)
Write-Host ("size  : " + $fi.Length + " bytes")
Write-Host ("sha256: " + (Get-FileHash $zip -Algorithm SHA256).Hash)

$arch = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    Write-Host 'entries:'
    $arch.Entries | ForEach-Object { Write-Host ("  {0,8}  {1}" -f $_.Length, $_.FullName) }
} finally { $arch.Dispose() }
