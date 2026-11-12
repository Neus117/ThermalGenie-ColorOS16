# Build Thermal Genie module zip from src\
# Usage:  pwsh -File .\build.ps1
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

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $src, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$fi = Get-Item $zip
Write-Host ("built : " + $fi.FullName)
Write-Host ("size  : " + $fi.Length + " bytes")
Write-Host ("sha256: " + (Get-FileHash $zip -Algorithm SHA256).Hash)

$arch = [System.IO.Compression.ZipFile]::OpenRead($zip)
Write-Host 'entries:'
$arch.Entries | ForEach-Object { Write-Host ("  {0,8}  {1}" -f $_.Length, $_.FullName) }
$arch.Dispose()
