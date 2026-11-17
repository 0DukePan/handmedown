# Install hand on Windows.
#
#   irm https://raw.githubusercontent.com/0DukePan/handmedown/main/install.ps1 | iex
#
# Downloads the release binary, verifies it against the published SHA256SUMS.txt, and puts it under
# %LOCALAPPDATA%\handmedown\bin. No administrator rights, no machine-wide change, no registry.
#
# Environment:
#   HAND_VERSION      pin a release tag (default: latest)
#   HAND_REPO         override the source repository (default: 0DukePan/handmedown)
#   HAND_INSTALL_DIR  override the install directory
#   HAND_BASE_URL     override the release base URL (used by the installer tests)
#   HAND_NO_PATH      set to 1 to leave the user PATH alone
#   HAND_USER_PATH    read this instead of the real user PATH (used by the installer tests)

[CmdletBinding()]
param(
    # Accept the release base URL positionally-free style flags too, so the script can be called
    # directly during testing without setting the environment.
    [string]$BaseUrl = $env:HAND_BASE_URL,

    [switch]$NoPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:HAND_NO_PATH -eq '1') { $NoPath = $true }

$repo = if ($env:HAND_REPO) { $env:HAND_REPO } else { '0DukePan/handmedown' }
$version = if ($env:HAND_VERSION) { $env:HAND_VERSION } else { 'latest' }
$installDir = if ($env:HAND_INSTALL_DIR) { $env:HAND_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'handmedown\bin' }

# Windows only ships one target in v0.1. The guard is explicit so an arm64 Windows user gets a clear
# message instead of an x86 binary that will not start.
if ($env:PROCESSOR_ARCHITECTURE -and $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw "hand: this build targets windows/amd64; your architecture is $($env:PROCESSOR_ARCHITECTURE). Build from source instead."
}

$asset = 'hand_windows_amd64.exe'

if (-not $BaseUrl) {
    if ($version -eq 'latest') {
        $BaseUrl = "https://github.com/$repo/releases/latest/download"
    } else {
        $BaseUrl = "https://github.com/$repo/releases/download/$version"
    }
}
$BaseUrl = $BaseUrl.TrimEnd('/')

Write-Host 'handmedown installer' -ForegroundColor Yellow
Write-Host "  repository: $repo"
Write-Host "  version:    $version"
Write-Host "  asset:      $asset"
Write-Host "  target:     $installDir"

# Invoke-WebRequest hands back a byte array when the response has no charset, and splitting a byte array
# silently coerces it to the literal text "System.Byte[]". Decode explicitly or every parse below fails
# in a way that looks like "the release has no checksum for this asset".
function Get-Text([string]$Url) {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    return [string]$response.Content
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

# --- checksum first -----------------------------------------------------------
# The checksum is fetched before the binary, so a broken release fails before anything large is
# downloaded, and the expected hash is never derived from the thing being checked.
$sumsUrl = "$BaseUrl/SHA256SUMS.txt"
try {
    $sums = Get-Text $sumsUrl
} catch {
    throw "hand: could not download $sumsUrl`n  Check your connection, or pass HAND_VERSION to pin a release.`n  $($_.Exception.Message)"
}

$expected = $null
foreach ($line in ($sums -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '') { continue }
    # "<sha256>  <filename>": split on the first whitespace run only.
    $parts = $trimmed -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1] -eq $asset) { $expected = $parts[0].ToLower(); break }
}

if (-not $expected) {
    throw "hand: SHA256SUMS.txt has no entry for $asset.`n  The release is incomplete; do not install it."
}

$tempDir = Join-Path $env:TEMP ('hand-install-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $binaryPath = Join-Path $tempDir $asset

    Write-Host '  downloading...'
    try {
        Invoke-WebRequest -Uri "$BaseUrl/$asset" -OutFile $binaryPath -UseBasicParsing -TimeoutSec 300
    } catch {
        throw "hand: could not download $BaseUrl/$asset`n  $($_.Exception.Message)"
    }

    $actual = Get-Sha256 $binaryPath
    if ($actual -ne $expected) {
        throw "hand: checksum mismatch for $asset`n  expected: $expected`n  actual:   $actual`n  Refusing to install. The download is corrupt or was tampered with."
    }
    Write-Host '  checksum:   ok' -ForegroundColor Green

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $destination = Join-Path $installDir 'hand.exe'
    Copy-Item -LiteralPath $binaryPath -Destination $destination -Force

    $reported = (& $destination version) -join ' '
    Write-Host "  installed:  $destination ($reported)"
} finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

# --- PATH ---------------------------------------------------------------------
# Idempotent by construction: the entry is added only if it is absent, so installing twice is safe.
$currentPath = if ($env:HAND_USER_PATH -ne $null) { $env:HAND_USER_PATH } else { [Environment]::GetEnvironmentVariable('Path', 'User') }

if ($NoPath) {
    Write-Host '  PATH:       left alone (HAND_NO_PATH)'
} elseif ($currentPath -like "*$installDir*") {
    Write-Host '  PATH:       already contains the install directory'
} else {
    $updated = if ([string]::IsNullOrEmpty($currentPath)) { $installDir } else { "$currentPath;$installDir" }
    if ($env:HAND_USER_PATH -ne $null) {
        # Testing: do not mutate the real user environment.
        Write-Host "  PATH:       would set to $updated"
    } else {
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-Host "  PATH:       added $installDir (open a new terminal to pick it up)"
    }
}

Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host ''
Write-Host '  hand demo             prove the recovery guarantee on this machine'
Write-Host '  hand run --help       run one command across a list of inputs'
Write-Host '  hand --help           everything else'
Write-Host ''
