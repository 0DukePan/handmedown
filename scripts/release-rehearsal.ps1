# Cut a release locally, without CI.
#
#   scripts\release-rehearsal.ps1 -Version v0.1.0
#
# This is the offline rehearsal of a tagged release: it builds the same six artefacts the workflow
# builds, names them the same way, writes the same checksum file, and then *verifies* the result.
# Everything downstream - the installers, the workflow, the README - depends on the naming and
# checksum contract defined here, so the contract is asserted rather than assumed.
#
# Why magic bytes: "the build exited 0 and the file is not empty" is not evidence that a cross-compiled
# artefact is the thing you think it is. A windows binary is checked for PE, a linux one for ELF with
# the right e_machine, a darwin one for Mach-O with the right cputype. A silently broken toolchain that
# emitted host binaries for every target would pass a size check and fail this one.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$Out = 'dist',

    # Skips the six cross-builds and only re-verifies whatever is already in -Out. Used by the
    # corruption self-test and by anyone re-running verification without paying for a rebuild.
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$agent = Join-Path $repo 'agent'
$versionSymbol = 'github.com/0DukePan/handmedown/agent/internal/version.Version'

# The single source of truth for what a release contains. The workflow asserts against this list, and
# the installers construct URLs from these names.
$targets = @(
    @{ GOOS = 'linux';   GOARCH = 'amd64'; Ext = '' }
    @{ GOOS = 'linux';   GOARCH = 'arm64'; Ext = '' }
    @{ GOOS = 'linux';   GOARCH = 'arm';   Ext = '' }
    @{ GOOS = 'darwin';  GOARCH = 'arm64'; Ext = '' }
    @{ GOOS = 'darwin';  GOARCH = 'amd64'; Ext = '' }
    @{ GOOS = 'windows'; GOARCH = 'amd64'; Ext = '.exe' }
)

$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

function Get-ArtifactName($target) {
    return "hand_{0}_{1}{2}" -f $target.GOOS, $target.GOARCH, $target.Ext
}

# Reads bytes without loading a whole binary: cross-compiled artefacts are several MB each.
function Read-Magic([string]$Path, [int]$Offset, [int]$Count) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt ($Offset + $Count)) { return $null }
        $buffer = New-Object byte[] $Count
        $stream.Position = $Offset
        [void]$stream.Read($buffer, 0, $Count)
        return $buffer
    } finally { $stream.Dispose() }
}

function Get-UInt32LE([byte[]]$Bytes, [int]$Offset) {
    return [uint32]$Bytes[$Offset] -bor ([uint32]$Bytes[$Offset + 1] -shl 8) -bor
           ([uint32]$Bytes[$Offset + 2] -shl 16) -bor ([uint32]$Bytes[$Offset + 3] -shl 24)
}

function Get-UInt16LE([byte[]]$Bytes, [int]$Offset) {
    return [uint16]$Bytes[$Offset] -bor ([uint16]$Bytes[$Offset + 1] -shl 8)
}

# Returns $null when the artefact is the right shape, or a human explanation when it is not.
function Test-ArtifactFormat([string]$Path, $target) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'file does not exist' }
    if ((Get-Item -LiteralPath $Path).Length -lt 1024) { return 'file is implausibly small for a binary' }

    switch ($target.GOOS) {
        'windows' {
            $magic = Read-Magic $Path 0 2
            if ($null -eq $magic) { return 'cannot read magic' }
            if ($magic[0] -ne 0x4D -or $magic[1] -ne 0x5A) {
                return ('not a PE image: expected MZ, got {0:x2} {1:x2}' -f $magic[0], $magic[1])
            }
            return $null
        }
        'linux' {
            $magic = Read-Magic $Path 0 4
            if ($null -eq $magic) { return 'cannot read magic' }
            if ($magic[0] -ne 0x7F -or $magic[1] -ne 0x45 -or $magic[2] -ne 0x4C -or $magic[3] -ne 0x46) {
                return ('not an ELF image: expected 7f 45 4c 46, got {0:x2} {1:x2} {2:x2} {3:x2}' -f $magic[0], $magic[1], $magic[2], $magic[3])
            }
            $header = Read-Magic $Path 18 2
            $machine = Get-UInt16LE $header 0
            $expected = @{ 'amd64' = 0x003E; 'arm64' = 0x00B7; 'arm' = 0x0028 }[$target.GOARCH]
            if ($machine -ne $expected) {
                return ('ELF for the wrong machine: {0:x4}, wanted {1:x4} ({2})' -f $machine, $expected, $target.GOARCH)
            }
            return $null
        }
        'darwin' {
            $magic = Read-Magic $Path 0 4
            if ($null -eq $magic) { return 'cannot read magic' }
            # Compare the four bytes rather than a 32-bit constant: PowerShell 5.1 parses 0xFEEDFACF as a
            # negative Int32, so `[uint32]value -ne 0xFEEDFACF` is always true and every valid binary is
            # rejected. Byte comparison has no such trap. Little-endian CF FA ED FE.
            if ($magic[0] -ne 0xCF -or $magic[1] -ne 0xFA -or $magic[2] -ne 0xED -or $magic[3] -ne 0xFE) {
                return ('not a 64-bit Mach-O: got {0:x2} {1:x2} {2:x2} {3:x2}' -f $magic[0], $magic[1], $magic[2], $magic[3])
            }
            $cpuBytes = Read-Magic $Path 4 4
            $cpu = Get-UInt32LE $cpuBytes 0
            $expected = @{ 'arm64' = 16777228; 'amd64' = 16777223 }[$target.GOARCH]
            if ($cpu -ne $expected) {
                return ('Mach-O for the wrong cpu: {0}, wanted {1} ({2})' -f $cpu, $expected, $target.GOARCH)
            }
            return $null
        }
    }
    return ('unknown target ' + $target.GOOS)
}

# --- build ------------------------------------------------------------------
$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $repo $Out }

if (-not $VerifyOnly) {
    Write-Host ("release rehearsal {0} -> {1}" -f $Version, $outPath) -ForegroundColor Cyan

    if (Test-Path -LiteralPath $outPath) { Remove-Item -Recurse -Force $outPath }
    New-Item -ItemType Directory -Force -Path $outPath | Out-Null

    $previousGoOS = $env:GOOS
    $previousGoArch = $env:GOARCH
    $previousCgo = $env:CGO_ENABLED

    Push-Location $agent
    try {
        foreach ($target in $targets) {
            $name = Get-ArtifactName $target
            $env:GOOS = $target.GOOS
            $env:GOARCH = $target.GOARCH
            $env:CGO_ENABLED = '0'

            $ldflags = "-s -w -X $versionSymbol=$Version"
            & go build -trimpath -ldflags $ldflags -o (Join-Path $outPath $name) .\cmd\hand
            if ($LASTEXITCODE -ne 0) { throw "go build failed for $($target.GOOS)/$($target.GOARCH)" }
        }
    } finally {
        $env:GOOS = $previousGoOS
        $env:GOARCH = $previousGoArch
        $env:CGO_ENABLED = $previousCgo
        Pop-Location
    }

    # Checksums are written from the built files, never from what we intended to build.
    $lines = foreach ($target in $targets) {
        $name = Get-ArtifactName $target
        $hash = (Get-FileHash -LiteralPath (Join-Path $outPath $name) -Algorithm SHA256).Hash.ToLower()
        # Two spaces: the format sha256sum -c expects.
        "$hash  $name"
    }
    $sumsPath = Join-Path $outPath 'SHA256SUMS.txt'
    [System.IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# --- verify -----------------------------------------------------------------
Write-Host ''
Write-Host 'verifying artefacts' -ForegroundColor Cyan

foreach ($target in $targets) {
    $name = Get-ArtifactName $target
    $path = Join-Path $outPath $name
    $problem = Test-ArtifactFormat $path $target

    if ($null -eq $problem) {
        $size = '{0:N2} MB' -f ((Get-Item -LiteralPath $path).Length / 1MB)
        Check ("{0} is a valid {1}/{2} binary ({3})" -f $name, $target.GOOS, $target.GOARCH, $size) $true
    } else {
        Check ("{0} is a valid {1}/{2} binary" -f $name, $target.GOOS, $target.GOARCH) $false $problem
    }
}

# The checksum file must reproduce from the files it claims to describe.
$sumsPath = Join-Path $outPath 'SHA256SUMS.txt'
Check 'SHA256SUMS.txt exists' (Test-Path -LiteralPath $sumsPath) $sumsPath

if (Test-Path -LiteralPath $sumsPath) {
    $sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { $_ -match '\S' })
    Check 'checksum file covers every artefact' ($sumLines.Count -eq $targets.Count) ("{0} lines for {1} artefacts" -f $sumLines.Count, $targets.Count)

    $mismatched = @()
    foreach ($line in $sumLines) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -ne 2) { $mismatched += "unparseable: $line"; continue }
        $expected = $parts[0]
        $file = Join-Path $outPath $parts[1]
        if (-not (Test-Path -LiteralPath $file)) { $mismatched += "missing: $($parts[1])"; continue }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) { $mismatched += "hash mismatch: $($parts[1])" }
    }
    Check 'every checksum reproduces' ($mismatched.Count -eq 0) ($mismatched -join '; ')
}

# The injected version is only real if the binary says it.
$native = Join-Path $outPath 'hand_windows_amd64.exe'
if (Test-Path -LiteralPath $native) {
    $reported = (& $native version) -join ' '
    Check ("native binary reports {0}" -f $Version) ($reported -match [regex]::Escape($Version)) $reported
    Check 'native binary reports its platform' ($reported -match 'windows/amd64') $reported
}

# Prove the verifier can fail: a corrupted copy must be rejected. A check that has never failed is not
# known to work.
$victim = $targets | Where-Object { $_.GOOS -eq 'linux' -and $_.GOARCH -eq 'arm64' } | Select-Object -First 1
$corruptDir = Join-Path ([System.IO.Path]::GetTempPath()) ('hand-corrupt-' + [guid]::NewGuid().ToString('n'))
try {
    New-Item -ItemType Directory -Force -Path $corruptDir | Out-Null
    $corruptPath = Join-Path $corruptDir (Get-ArtifactName $victim)
    Copy-Item -LiteralPath (Join-Path $outPath (Get-ArtifactName $victim)) -Destination $corruptPath

    $bytes = [System.IO.File]::ReadAllBytes($corruptPath)
    $bytes[1] = 0x00   # clobber the ELF magic
    [System.IO.File]::WriteAllBytes($corruptPath, $bytes)

    $rejection = Test-ArtifactFormat $corruptPath $victim
    Check 'a corrupted artefact is rejected' ($null -ne $rejection) 'the verifier accepted a clobbered file'
} finally {
    Remove-Item -Recurse -Force $corruptDir -ErrorAction SilentlyContinue
}

# --- summary ----------------------------------------------------------------
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host ("REHEARSAL OK: {0} artefacts in {1}" -f $targets.Count, $outPath) -ForegroundColor Green
    exit 0
}

Write-Host ("REHEARSAL FAILED: {0} check(s)" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
exit 1
