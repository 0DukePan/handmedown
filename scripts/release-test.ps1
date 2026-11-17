# Test for the release rehearsal: does one command really produce a release you would ship?
#
#   scripts\release-test.ps1 [-Version v0.1.0]
#
# The seam is the command itself. It runs scripts\release-rehearsal.ps1 into an empty directory and
# then re-derives every acceptance criterion from the files it left behind, using this file's own
# header parser and its own checksum comparison. That matters: a rehearsal that printed "PASS" without
# checking anything would pass a test that only read the rehearsal's output.
#
# The version is generated per run, so a binary left over from an earlier attempt cannot satisfy the
# link-time-injection check by coincidence.
#
# Then it proves verification fails when it should, from the outside: copy the directory, confirm the
# untouched copy verifies, damage one artefact past its header (only the checksum can catch that), and
# require the same command to reject it and name the file.
#
# No network, no CI, no git state.

[CmdletBinding()]
param(
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$rehearsal = Join-Path $repo 'scripts\release-rehearsal.ps1'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    $envPs1 = Join-Path (Split-Path -Parent $repo) '_bootstrap\env.ps1'
    if (Test-Path -LiteralPath $envPs1) { . $envPs1 | Out-Null }
}

$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

# The six advertised targets, written out here rather than imported from the rehearsal: these
# expectations are the acceptance criteria, and a test that shared the implementation's table would
# agree with the implementation even when both were wrong.
#   ELF: e_machine is a 2-byte little-endian field at offset 18 in both ELF32 and ELF64.
#        0x3E = x86-64, 0xB7 = AArch64, 0x28 = ARM. EI_CLASS at offset 4 is 2 for 64-bit, 1 for 32-bit.
#   Mach-O: 64-bit little-endian magic CF FA ED FE; cputype at offset 4, 0x0100000C = arm64,
#        0x01000007 = x86_64.
#   PE: "MZ" at offset 0, e_lfanew at offset 0x3C, "PE\0\0" there, machine 0x8664 = x86-64.
$targets = @(
    @{ Goos = 'linux';   Goarch = 'amd64'; Name = 'hand_linux_amd64';       Kind = 'elf';   Machine = 0x3E;       Class = 2 }
    @{ Goos = 'linux';   Goarch = 'arm64'; Name = 'hand_linux_arm64';       Kind = 'elf';   Machine = 0xB7;       Class = 2 }
    @{ Goos = 'linux';   Goarch = 'arm';   Name = 'hand_linux_arm';         Kind = 'elf';   Machine = 0x28;       Class = 1 }
    @{ Goos = 'darwin';  Goarch = 'arm64'; Name = 'hand_darwin_arm64';      Kind = 'macho'; CpuType = 0x0100000C }
    @{ Goos = 'darwin';  Goarch = 'amd64'; Name = 'hand_darwin_amd64';      Kind = 'macho'; CpuType = 0x01000007 }
    @{ Goos = 'windows'; Goarch = 'amd64'; Name = 'hand_windows_amd64.exe'; Kind = 'pe';    Machine = 0x8664 }
)

function Read-Head([string]$Path, [int]$Count = 4096) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $Count
        $read = $stream.Read($buffer, 0, $Count)
        if ($read -eq 0) { return @() }
        if ($read -lt $Count) { return $buffer[0..($read - 1)] }
        return $buffer
    } finally { $stream.Dispose() }
}

# The [int64] casts are not noise: PowerShell's -shl keeps the width of its left operand, so
# [byte]0x01 -shl 24 is 0 rather than 0x01000000. 4096 bytes is enough for the MZ stub plus the PE
# header it points at (0x80 in a Go build); the ELF and Mach-O headers are in the first 64.
function Read-Le32([byte[]]$Bytes, [int]$Offset) {
    if ($Bytes.Length -lt ($Offset + 4)) { return -1 }
    return [int64]([int64]$Bytes[$Offset] -bor ([int64]$Bytes[$Offset + 1] -shl 8) -bor
        ([int64]$Bytes[$Offset + 2] -shl 16) -bor ([int64]$Bytes[$Offset + 3] -shl 24))
}

function Read-Le16([byte[]]$Bytes, [int]$Offset) {
    if ($Bytes.Length -lt ($Offset + 2)) { return -1 }
    return [int]([int]$Bytes[$Offset] -bor ([int]$Bytes[$Offset + 1] -shl 8))
}

# What this file - not the rehearsal - says the artefact is.
function Get-BinaryShape([string]$Path) {
    $head = Read-Head $Path
    if ($head.Count -lt 64) { return @{ Kind = 'short' } }

    if ($head[0] -eq 0x4D -and $head[1] -eq 0x5A) {
        $peOffset = Read-Le32 $head 0x3C
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $head.Length) { return @{ Kind = 'pe'; Malformed = $true } }
        $signature = (($head[$peOffset..($peOffset + 3)] | ForEach-Object { $_.ToString('x2') }) -join '')
        return @{ Kind = 'pe'; Signature = $signature; Machine = (Read-Le16 $head ($peOffset + 4)) }
    }

    if ($head[0] -eq 0x7F -and $head[1] -eq 0x45 -and $head[2] -eq 0x4C -and $head[3] -eq 0x46) {
        return @{ Kind = 'elf'; Class = [int]$head[4]; Data = [int]$head[5]; Machine = (Read-Le16 $head 18) }
    }

    if ($head[0] -eq 0xCF -and $head[1] -eq 0xFA -and $head[2] -eq 0xED -and $head[3] -eq 0xFE) {
        return @{ Kind = 'macho'; CpuType = (Read-Le32 $head 4) }
    }

    if ($head[0] -eq 0xFE -and $head[1] -eq 0xED -and $head[2] -eq 0xFA -and $head[3] -eq 0xCF) {
        return @{ Kind = 'macho-be' }
    }

    return @{ Kind = 'unknown'; Magic = (($head[0..3] | ForEach-Object { $_.ToString('x2') }) -join '') }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Strict sha256sum parser, independent of the rehearsal's: an installer that accepted a sloppy line
# would install an unverified binary, so anything but "<64 lowercase hex><2 spaces><name>" is rejected.
function Read-Sums([string]$Path) {
    $result = @{ Present = $false; Entries = @{}; Malformed = New-Object 'System.Collections.Generic.List[string]' }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $result.Present = $true
    foreach ($line in ((Get-Content -LiteralPath $Path -Raw) -split "`r?`n")) {
        if ($line -eq '') { continue }
        if ($line -match '^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$') {
            $result.Entries[$Matches['name']] = $Matches['hash']
        } else {
            $result.Malformed.Add($line)
        }
    }
    return $result
}

function Flip-Byte([string]$Path, [int64]$Offset) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try {
        $stream.Position = $Offset
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw "offset $Offset is past the end of $Path" }
        $stream.Position = $Offset
        $stream.WriteByte([byte]($value -bxor 0xFF))
    } finally { $stream.Dispose() }
}

# Call the rehearsal the way a maintainer does, and never let a thrown error hide the other
# assertions: a command that throws instead of exiting with a code is itself a finding.
function Invoke-Rehearsal([hashtable]$Parameters) {
    try {
        $Text = & $rehearsal @Parameters *>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $Text = $_.Exception.Message
        $code = 1
    }
    return @{ Output = $Text; Code = $code }
}

if (-not (Test-Path -LiteralPath $rehearsal)) {
    Write-Host ("RELEASE-TEST: scripts\release-rehearsal.ps1 does not exist, so there is nothing to test: {0}" -f $rehearsal) -ForegroundColor Red
    exit 1
}

if (-not $Version) {
    $Version = 'v0.0.0-rehearsal.' + [guid]::NewGuid().ToString('n').Substring(0, 8)
}

$out = Join-Path $env:TEMP ('hand-release-test-' + [guid]::NewGuid().ToString('n'))

Write-Host ''
Write-Host ("release-test: rehearsing {0} into {1}" -f $Version, $out) -ForegroundColor Cyan

$run = Invoke-Rehearsal -Parameters @{ Version = $Version; Out = $out }
$output = $run.Output
$exitCode = $run.Code

Write-Host $output

# --- the command ------------------------------------------------------------
Write-Host ''
Write-Host 'the command' -ForegroundColor Cyan

Check 'the rehearsal exits zero' ($exitCode -eq 0) ("exit={0}" -f $exitCode)
Check 'the rehearsal reports no check failures' ($output -notmatch '  FAIL  ') ''

# --- names ------------------------------------------------------------------
Write-Host ''
Write-Host 'artefact names' -ForegroundColor Cyan

$expectedNames = @($targets | ForEach-Object { $_.Name })
$onDisk = @(Get-ChildItem -LiteralPath $out -File -Filter 'hand_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$missing = @($expectedNames | Where-Object { $onDisk -notcontains $_ })
$extra = @($onDisk | Where-Object { $expectedNames -notcontains $_ })

$namesOk = ($missing.Count -eq 0) -and ($extra.Count -eq 0)
$namesDetail = @()
if ($missing.Count -gt 0) { $namesDetail += ('missing: ' + ($missing -join ', ')) }
if ($extra.Count -gt 0) { $namesDetail += ('not one of the six targets: ' + ($extra -join ', ')) }
Check 'exactly the six hand_<goos>_<goarch> artefacts exist' $namesOk ($namesDetail -join '; ')

# .exe only for windows: the installers construct the download URL from the name, so the suffix is
# part of the contract rather than a local convention.
Check 'only the windows artefact carries .exe' `
    (@($onDisk | Where-Object { $_ -match '\.exe$' }).Count -eq 1 -and ($onDisk -contains 'hand_windows_amd64.exe')) `
    (($onDisk -join ', '))

$empty = @($targets | Where-Object {
    $path = Join-Path $out $_.Name
    (-not (Test-Path -LiteralPath $path)) -or ((Get-Item -LiteralPath $path).Length -lt 1MB)
} | ForEach-Object { $_.Name })
Check 'every artefact is a real binary, not a stub' ($empty.Count -eq 0) ($empty -join ', ')

# --- format and architecture, read from the bytes ---------------------------
Write-Host ''
Write-Host 'format and architecture (parsed by this test, not by the rehearsal)' -ForegroundColor Cyan

foreach ($target in $targets) {
    $path = Join-Path $out $target.Name
    if (-not (Test-Path -LiteralPath $path)) {
        Check ("{0} is the right format for {1}/{2}" -f $target.Name, $target.Goos, $target.Goarch) $false 'missing'
        continue
    }

    $shape = Get-BinaryShape $path
    $ok = $false
    $detail = ("shape={0}" -f $shape.Kind)

    if ($shape.Kind -ne $target.Kind) {
        $detail = ("format is {0}, want {1}" -f $shape.Kind, $target.Kind)
    } elseif ($target.Kind -eq 'pe') {
        $ok = ($shape.Signature -eq '50450000') -and ($shape.Machine -eq $target.Machine)
        $detail = ("PE signature={0} machine=0x{1:X}, want PE\0\0 and 0x{2:X}" -f $shape.Signature, $shape.Machine, $target.Machine)
    } elseif ($target.Kind -eq 'elf') {
        $ok = ($shape.Machine -eq $target.Machine) -and ($shape.Class -eq $target.Class) -and ($shape.Data -eq 1)
        $detail = ("e_machine=0x{0:X} class={1} data={2}, want 0x{3:X} class={4} little-endian" -f `
            $shape.Machine, $shape.Class, $shape.Data, $target.Machine, $target.Class)
    } elseif ($target.Kind -eq 'macho') {
        $ok = ($shape.CpuType -eq $target.CpuType)
        $detail = ("cputype=0x{0:X}, want 0x{1:X}" -f $shape.CpuType, $target.CpuType)
    }

    Check ("{0} is {1}/{2} ({3})" -f $target.Name, $target.Goos, $target.Goarch, $target.Kind) $ok $detail
}

# --- the checksum file ------------------------------------------------------
Write-Host ''
Write-Host 'SHA256SUMS.txt' -ForegroundColor Cyan

$sums = Read-Sums (Join-Path $out 'SHA256SUMS.txt')
Check 'SHA256SUMS.txt exists' $sums.Present ''
Check 'every line is "<64 hex>  <name>" (sha256sum format, two spaces)' ($sums.Present -and $sums.Malformed.Count -eq 0) ($sums.Malformed -join '; ')
# A release contains the six agent binaries and the brain archive. Re-deriving the expectation here
# (rather than trusting the rehearsal) is the point of this test; the archive is counted separately so
# an agent binary that went missing still fails.
# Entries is a name -> digest map, so the names are its keys.
$sumNames = @($sums.Entries.Keys)
$agentEntries = @($sumNames | Where-Object { $_ -like 'hand_*' })
$brainEntries = @($sumNames | Where-Object { $_ -like 'handmedown-brain_*.tar.gz' })
Check ("it has one line per agent artefact ({0})" -f $targets.Count) ($agentEntries.Count -eq $targets.Count) ("agent lines={0}" -f $agentEntries.Count)
Check 'it also covers the brain archive' ($brainEntries.Count -eq 1) ("brain lines={0}" -f $brainEntries.Count)

foreach ($target in $targets) {
    $path = Join-Path $out $target.Name
    if (($sums.Entries.ContainsKey($target.Name)) -and (Test-Path -LiteralPath $path)) {
        $actual = Get-Sha256 $path
        Check ("recomputing {0} reproduces its line" -f $target.Name) ($actual -eq $sums.Entries[$target.Name]) `
            ("line says {0}, file hashes to {1}" -f $sums.Entries[$target.Name], $actual)
    } else {
        Check ("recomputing {0} reproduces its line" -f $target.Name) $false 'no line in SHA256SUMS.txt'
    }
}

# --- the version really is inside the binary --------------------------------
Write-Host ''
Write-Host 'the injected version, run rather than inspected' -ForegroundColor Cyan

$hostGoos = (& go env GOOS | Out-String).Trim()
$hostGoarch = (& go env GOARCH | Out-String).Trim()
$hostTarget = $targets | Where-Object { $_.Goos -eq $hostGoos -and $_.Goarch -eq $hostGoarch } | Select-Object -First 1

if (-not $hostTarget) {
    Check 'the artefact for this machine runs' $false ("host is {0}/{1}, none of the six targets" -f $hostGoos, $hostGoarch)
} else {
    $native = Join-Path $out $hostTarget.Name
    try {
        $printed = & $native version 2>&1 | Out-String
        $nativeCode = $LASTEXITCODE
    } catch {
        $printed = $_.Exception.Message
        $nativeCode = 1
    }
    Check 'the native artefact reports the version it was built with' ($nativeCode -eq 0 -and $printed.Contains($Version)) `
        ("exit={0} output={1}" -f $nativeCode, $printed.Trim())
    Check 'it reports its own platform' ($printed.Contains("$hostGoos/$hostGoarch")) $printed.Trim()
}

# --- the verifier must fail when it should ----------------------------------
Write-Host ''
Write-Host 'verification fails on a corrupted artefact' -ForegroundColor Cyan

# Copy the directory so the damage lives where it cannot hide a later failure. The untouched copy is
# the control: without it, a verifier that rejected everything would pass this section.
$copy = Join-Path $env:TEMP ('hand-release-corrupt-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $copy | Out-Null
if (Test-Path -LiteralPath $out) { Copy-Item -Path (Join-Path $out '*') -Destination $copy -Force }

$intact = Invoke-Rehearsal -Parameters @{ VerifyOnly = $true; Out = $copy }
Check 'an untouched copy verifies' ($intact.Code -eq 0) ("exit={0} {1}" -f $intact.Code, $intact.Output.Trim())

# Damage one byte in the middle of a linux artefact. The header still says ELF, so only the checksum
# can reject it - which is the reason a release publishes one at all.
$victimName = 'hand_linux_amd64'
$victim = Join-Path $copy $victimName
if (Test-Path -LiteralPath $victim) {
    $size = (Get-Item -LiteralPath $victim).Length
    Flip-Byte $victim ([int64]($size / 2))
}

$corrupt = Invoke-Rehearsal -Parameters @{ VerifyOnly = $true; Out = $copy }
Check 'a corrupted artefact makes verification exit non-zero' ($corrupt.Code -ne 0) ("exit={0}" -f $corrupt.Code)
Check 'the failure names the corrupted file' ($corrupt.Output.Contains($victimName)) $corrupt.Output.Trim()

# Restore, then clobber the magic instead of the payload: that must be caught by the format check
# rather than by the hash, so the two mechanisms are shown to be independent.
$pristine = Join-Path $out $victimName
if ((Test-Path -LiteralPath $pristine) -and (Test-Path -LiteralPath $victim)) {
    Copy-Item -LiteralPath $pristine -Destination $victim -Force
}
$machoName = 'hand_darwin_arm64'
$macho = Join-Path $copy $machoName
if (Test-Path -LiteralPath $macho) { Flip-Byte $macho ([int64]0) }

$format = Invoke-Rehearsal -Parameters @{ VerifyOnly = $true; Out = $copy }
Check 'a clobbered header makes verification exit non-zero' ($format.Code -ne 0) ("exit={0}" -f $format.Code)
Check 'the failure names the file whose header is wrong' ($format.Output.Contains($machoName)) $format.Output.Trim()

# --- summary ----------------------------------------------------------------
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'RELEASE-TEST: all checks passed' -ForegroundColor Green
    Write-Host "  rehearsal output kept for inspection: $out" -ForegroundColor DarkGray
    if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

Write-Host ("RELEASE-TEST: {0} check(s) failed" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
Write-Host "  rehearsal output: $out" -ForegroundColor DarkGray
Write-Host "  corrupted copy:   $copy" -ForegroundColor DarkGray
exit 1
