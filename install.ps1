param(
    [string]$LeaseHost,
    [string]$LeaseBin = 'device-lease',
    [string]$Serials,
    [string]$Models,
    [string]$AdbPath,
    [string]$IdEnv = 'ADB_LEASE_ID',
    [string]$Version = 'latest',
    [string]$AssetDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $LeaseHost) { $LeaseHost = Read-Host 'SSH alias for the existing lease server' }
if (-not $Serials -and -not $Models) {
    $Serials = Read-Host 'Device serial(s), comma separated'
    $Models = Read-Host 'Device model(s), comma separated (optional)'
}
if (-not $LeaseHost -or (-not $Serials -and -not $Models)) {
    throw 'LeaseHost and Serials or Models are required.'
}
if ($LeaseHost.StartsWith('-') -or $LeaseBin.StartsWith('-')) {
    throw 'Invalid SSH host or lease command.'
}
if ($IdEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw 'Invalid IdEnv.'
}
if (-not $AdbPath) {
    $found = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (-not $found) { throw 'Existing adb.exe not found. Pass -AdbPath.' }
    $AdbPath = $found.Source
}
$AdbPath = [IO.Path]::GetFullPath($AdbPath)
if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw "Existing adb.exe not found: $AdbPath"
}
$directory = Split-Path -Parent $AdbPath
$real = Join-Path $directory 'adb-real.exe'
$config = Join-Path $directory 'adb-lease.json'
$moved = $false
if ((Test-Path -LiteralPath $real) -and -not (Test-Path -LiteralPath $config)) {
    throw "adb-real.exe already exists without adb-lease.json; refusing to overwrite $AdbPath"
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$asset = "adb-lease-guard-windows-$arch.exe"
$base = if ($Version -eq 'latest') {
    'https://github.com/megamen32/adb-lease-guard/releases/latest/download'
} else {
    "https://github.com/megamen32/adb-lease-guard/releases/download/$Version"
}
$stage = Join-Path $directory ('.adb-lease-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $sumPath = Join-Path $stage 'SHA256SUMS'
    $assetPath = Join-Path $stage $asset
    if ($AssetDirectory) {
        Copy-Item -LiteralPath (Join-Path $AssetDirectory 'SHA256SUMS') -Destination $sumPath
        Copy-Item -LiteralPath (Join-Path $AssetDirectory $asset) -Destination $assetPath
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sumPath
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $assetPath
    }
    $line = Get-Content -LiteralPath $sumPath | Where-Object {
        $_ -match ('^[A-Fa-f0-9]{64}\s+\*?' + [regex]::Escape($asset) + '$')
    } | Select-Object -First 1
    if (-not $line) { throw "Checksum for $asset is missing." }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
    if ($expected -ne $actual) { throw "Checksum mismatch for $asset." }

    $splitCsv = { param($value) if ($value) { @($value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } }
    $configuration = [ordered]@{
        real_adb = $real
        lease_command = @('ssh', '-n', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', $LeaseHost, $LeaseBin)
        device_serials = @(& $splitCsv $Serials)
        device_models = @(& $splitCsv $Models)
        id_env = $IdEnv
    }
    $newConfig = Join-Path $stage 'adb-lease.json'
    $json = $configuration | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($newConfig, $json, [Text.UTF8Encoding]::new($false))

    if (-not (Test-Path -LiteralPath $real)) {
        Move-Item -LiteralPath $AdbPath -Destination $real
        $moved = $true
    }
    Copy-Item -LiteralPath $assetPath -Destination $AdbPath -Force
    Copy-Item -LiteralPath $newConfig -Destination $config -Force
    & $AdbPath version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Installed ADB guard did not start.' }
    Write-Output "Installed: $AdbPath"
    Write-Output "Original adb: $real"
    Write-Output "Config: $config"
    Write-Output "Set `$env:$IdEnv to a valid lease ID before using the selected device."
} catch {
    if ($moved) {
        if (Test-Path -LiteralPath $AdbPath) { Remove-Item -LiteralPath $AdbPath -Force }
        Move-Item -LiteralPath $real -Destination $AdbPath
    }
    throw
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
