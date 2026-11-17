# Cut a release locally, offline, to prove it can be cut at all.
#
#   scripts\tasks.ps1 release-rehearsal v0.1.0
#   scripts\release-rehearsal.ps1 -Version v0.1.0 [-Out dist]
#   scripts\release-rehearsal.ps1 -VerifyOnly -Out dist [-Version v0.1.0]
#
# A release that only CI can perform is a release you cannot debug. This is the same work the tagged
# workflow does, runnable on a laptop with no network, no remote and no `gh`:
#
#   1. build hand_<goos>_<goarch>[.exe] for the six advertised targets, statically, with -trimpath
#   2. inject the version at link time, so the binary and the tag cannot disagree
#   3. write SHA256SUMS.txt in sha256sum format, because the installers parse it
#   4. verify every artefact by its own bytes - ELF/Mach-O/PE *and* the architecture inside the
#      header - because "the file exists" is not evidence that the right binary was built
#   5. run the artefact for this machine and check it prints the injected version and its platform
#   6. damage a copy on purpose and require verification to reject it, so "verified" is not a word
#      this script earns by printing it
#
# The two contracts other work depends on and that must not change silently:
#
#   asset names   hand_<goos>_<goarch>, plus .exe and only .exe for windows. Installers build download
#                 URLs from these, so renaming is a breaking change to the install surface.
#   checksums     "<64 lowercase hex><two spaces><name>", LF line endings, no BOM. Two spaces and LF
#                 are what `sha256sum -c` expects; a CRLF checksum file fails on macOS and Linux
#                 because the carriage return becomes part of the file name.
#
# Termux is linux/arm64: it is an ordinary Linux userland on an arm64 kernel, and GOOS=android would
# demand cgo and an NDK for no benefit.
#
# Exit codes: 0 all checks passed, 1 a check failed, 2 the arguments were wrong.

[CmdletBinding()]
param(
    # The tag-like version to inject, e.g. v0.1.0. Required unless -VerifyOnly is used. A tag shape is
    # enforced because this string is both what the binary prints and what the release is called: two
    # spellings of one version is how a binary and a tag start to disagree.
    [Parameter(Position = 0)]
    [ValidatePattern('^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '',

    # Where the artefacts go. Defaults to dist\ in the repository.
    [string]$Out = '',

    # Verify a directory that already exists instead of building one. This is what the test points at
    # a corrupted copy, and it is what you run after moving a release between machines.
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$agent = Join-Path $repo 'agent'
$versionVar = $null

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    $envPs1 = Join-Path (Split-Path -Parent $repo) '_bootstrap\env.ps1'
    if (Test-Path -LiteralPath $envPs1) { . $envPs1 | Out-Null }
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Host 'release-rehearsal: go is not on PATH. Run: . _bootstrap\env.ps1' -ForegroundColor Red
    exit 2
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

# The matrix, in the order the checksums are written. Kept here rather than derived from the workflow
# so a rehearsal cannot inherit a workflow mistake; the two are compared by eye when either changes.
#
# The offsets below are the formats' own, confirmed against real cross-builds:
#   ELF      magic 7F 45 4C 46 at 0; EI_CLASS at 4 (1 = 32-bit, 2 = 64-bit); EI_DATA at 5 (1 = little
#            endian); e_machine, 2 bytes little-endian, at 18. 0x3E x86-64, 0xB7 aarch64, 0x28 arm.
#   Mach-O   64-bit little-endian magic CF FA ED FE at 0; cputype, 4 bytes little-endian, at 4.
#            0x0100000C arm64, 0x01000007 x86_64.
#   PE       "MZ" at 0; e_lfanew, 4 bytes little-endian, at 0x3C; "PE\0\0" and machine at that offset.
#            0x8664 x86-64.
$targets = @(
    @{ Goos = 'linux';   Goarch = 'amd64'; Kind = 'elf';   Machine = 0x3E; Class = 2; Want = 'ELF x86-64' }
    @{ Goos = 'linux';   Goarch = 'arm64'; Kind = 'elf';   Machine = 0xB7; Class = 2; Want = 'ELF aarch64' }
    @{ Goos = 'linux';   Goarch = 'arm';   Kind = 'elf';   Machine = 0x28; Class = 1; Want = 'ELF arm' }
    @{ Goos = 'darwin';  Goarch = 'arm64'; Kind = 'macho'; CpuType = 0x0100000C; Want = 'Mach-O arm64' }
    @{ Goos = 'darwin';  Goarch = 'amd64'; Kind = 'macho'; CpuType = 0x01000007; Want = 'Mach-O x86_64' }
    @{ Goos = 'windows'; Goarch = 'amd64'; Kind = 'pe';    Machine = 0x8664;       Want = 'PE x86-64' }
)

function Get-ArtifactName($Target) {
    if ($Target.Goos -eq 'windows') { return ("hand_{0}_{1}.exe" -f $Target.Goos, $Target.Goarch) }
    return ("hand_{0}_{1}" -f $Target.Goos, $Target.Goarch)
}

# 4096 bytes covers the MZ stub plus the PE header it points at (0x80 in a Go build); the ELF and
# Mach-O headers live in the first 64.
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
# [byte]0x01 -shl 24 is 0 rather than 0x01000000 and every 32-bit field would silently lose its top
# three bytes.
function Read-Le32([byte[]]$Bytes, [int]$Offset) {
    if ($Bytes.Length -lt ($Offset + 4)) { return -1 }
    return [int64]([int64]$Bytes[$Offset] -bor ([int64]$Bytes[$Offset + 1] -shl 8) -bor
        ([int64]$Bytes[$Offset + 2] -shl 16) -bor ([int64]$Bytes[$Offset + 3] -shl 24))
}

function Read-Le16([byte[]]$Bytes, [int]$Offset) {
    if ($Bytes.Length -lt ($Offset + 2)) { return -1 }
    return [int]([int]$Bytes[$Offset] -bor ([int]$Bytes[$Offset + 1] -shl 8))
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

# Strict parse: anything but "<64 lowercase hex><two spaces><name>" is a failure rather than something
# to skip, because an installer that skipped a line would install an unverified binary.
function Read-Sums([string]$Path) {
    $result = @{
        Present   = $false
        Entries   = @{}
        Malformed = New-Object 'System.Collections.Generic.List[string]'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $result.Present = $true
    foreach ($line in ((Get-Content -LiteralPath $Path -Raw) -split "`r?`n")) {
        if ($line -eq '') { continue }
        if ($line -match '^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$') {
            $result.Entries[$Matches['name']] = $Matches['hash']
            continue
        }
        $result.Malformed.Add($line)
    }
    return $result
}

# Read one artefact the way an installer after a download would: the bytes must say the format and
# the architecture that the file name claims, and the digest must match the published line.
#
# The two verdicts are computed independently and reported separately. Collapsing them into one
# "broken" answer would let a wrong-header file hide behind a matching digest, or the reverse, and
# those two failures have completely different causes: a build gone wrong versus a copy gone wrong.
# Every verdict is a sentence, because "hand_linux_arm64 is broken" is not a diagnosis.
function Test-Artifact([string]$Path, $Target, [string]$ExpectedSha256) {
    $verdict = @{ Format = ''; Hash = '' }

    if (-not (Test-Path -LiteralPath $Path)) {
        $verdict.Format = 'missing'
        $verdict.Hash = 'missing'
        return $verdict
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1MB) {
        $verdict.Format = ("only {0} bytes; a stripped Go binary is several MB, so this is a stub or a failed copy" -f $item.Length)
    }

    $head = Read-Head $Path
    if ($head.Count -lt 64) {
        $verdict.Format = ("only {0} bytes readable" -f $head.Count)
    } elseif (-not $verdict.Format) {
        $formatProblem = $null
        if ($Target.Kind -eq 'pe') {
            if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) {
                $first = ($head[0..3] | ForEach-Object { $_.ToString('x2') }) -join ' '
                $formatProblem = ("not a PE file: first bytes are {0}, want 4D 5A (MZ)" -f $first)
            } else {
                $peOffset = Read-Le32 $head 0x3C
                if ($peOffset -lt 0 -or ($peOffset + 6) -gt $head.Length) {
                    $formatProblem = ("not a PE file: e_lfanew {0} points past the header" -f $peOffset)
                } elseif ($head[$peOffset] -ne 0x50 -or $head[$peOffset + 1] -ne 0x45 -or
                          $head[$peOffset + 2] -ne 0x00 -or $head[$peOffset + 3] -ne 0x00) {
                    $formatProblem = 'not a PE file: no "PE\0\0" signature where e_lfanew points'
                } else {
                    $machine = Read-Le16 $head ($peOffset + 4)
                    if ($machine -ne $Target.Machine) {
                        $formatProblem = ("PE machine 0x{0:X4}, want 0x{1:X4} (x86-64)" -f $machine, $Target.Machine)
                    }
                }
            }
        } elseif ($Target.Kind -eq 'elf') {
            $first = ($head[0..3] | ForEach-Object { $_.ToString('x2') }) -join ' '
            if ($head[0] -ne 0x7F -or $head[1] -ne 0x45 -or $head[2] -ne 0x4C -or $head[3] -ne 0x46) {
                $formatProblem = ("not an ELF file: first bytes are {0}, want 7F 45 4C 46" -f $first)
            } elseif ($head[4] -ne $Target.Class) {
                $formatProblem = ("ELF class {0}, want {1}: the wrong word size for {2}" -f $head[4], $Target.Class, $Target.Goarch)
            } elseif ($head[5] -ne 1) {
                $formatProblem = ("ELF data encoding {0}, want 1 (little-endian): this CPU cannot run a big-endian binary" -f $head[5])
            } else {
                $machine = Read-Le16 $head 18
                if ($machine -ne $Target.Machine) {
                    $formatProblem = ("ELF e_machine 0x{0:X}, want 0x{1:X} ({2})" -f $machine, $Target.Machine, $Target.Want)
                }
            }
        } else {
            $first = ($head[0..3] | ForEach-Object { $_.ToString('x2') }) -join ' '
            if ($head[0] -ne 0xCF -or $head[1] -ne 0xFA -or $head[2] -ne 0xED -or $head[3] -ne 0xFE) {
                $formatProblem = ("not a 64-bit little-endian Mach-O file: first bytes are {0}, want CF FA ED FE" -f $first)
            } else {
                $cpu = Read-Le32 $head 4
                if ($cpu -ne $Target.CpuType) {
                    $formatProblem = ("Mach-O cputype 0x{0:X}, want 0x{1:X} ({2})" -f $cpu, $Target.CpuType, $Target.Want)
                }
            }
        }
        if ($formatProblem) { $verdict.Format = $formatProblem }
    }

    if (-not $ExpectedSha256) {
        $verdict.Hash = 'no line for this artefact in SHA256SUMS.txt'
    } else {
        $actual = Get-Sha256 $Path
        if ($actual -ne $ExpectedSha256) {
            $verdict.Hash = ("sha256 mismatch: SHA256SUMS.txt says {0}, the file hashes to {1}" -f $ExpectedSha256, $actual)
        }
    }

    return $verdict
}

# --- arguments --------------------------------------------------------------
if (-not $Out) { $Out = Join-Path $repo 'dist' }
$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)

if (-not $VerifyOnly -and -not $Version) {
    Write-Host 'release-rehearsal: a version is required, because the point of a rehearsal is that the' -ForegroundColor Red
    Write-Host 'binary and the tag agree. Example: scripts\tasks.ps1 release-rehearsal v0.1.0' -ForegroundColor Red
    exit 2
}

# go.mod is the single source of truth for the module path, so moving the module does not silently
# leave the -X target pointing at a package that no longer exists. A failed injection is caught by
# running the binary below, not by trusting this line.
$modulePath = $null
foreach ($line in (Get-Content -LiteralPath (Join-Path $agent 'go.mod'))) {
    if ($line -match '^module\s+(?<path>\S+)') { $modulePath = $Matches['path']; break }
}
if (-not $modulePath) {
    Write-Host 'release-rehearsal: agent\go.mod has no module line, so the -X target cannot be built.' -ForegroundColor Red
    exit 1
}
$versionVar = "$modulePath/internal/version.Version"

$sumsPath = Join-Path $outPath 'SHA256SUMS.txt'
$expectedNames = @($targets | ForEach-Object { Get-ArtifactName $_ })

# --- build ------------------------------------------------------------------
if (-not $VerifyOnly) {
    Write-Host ''
    Write-Host ("release-rehearsal: {0} -> {1}" -f $Version, $outPath) -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $outPath | Out-Null

    # Remove last run's artefacts and checksums first. A build that failed halfway would otherwise
    # leave a previous binary to be verified and shipped under the current tag.
    foreach ($name in $expectedNames) {
        $stale = Join-Path $outPath $name
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }
    if (Test-Path -LiteralPath $sumsPath) { Remove-Item -LiteralPath $sumsPath -Force }

    $saved = @{}
    foreach ($name in 'GOOS', 'GOARCH', 'CGO_ENABLED') {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    Write-Host ''
    Write-Host 'build' -ForegroundColor Cyan
    Push-Location $agent
    try {
        $env:CGO_ENABLED = '0'
        foreach ($target in $targets) {
            $name = Get-ArtifactName $target
            $path = Join-Path $outPath $name
            $env:GOOS = $target.Goos
            $env:GOARCH = $target.Goarch

            $buildOutput = & go build -trimpath -ldflags "-s -w -X $versionVar=$Version" -o $path ./cmd/hand 2>&1 | Out-String
            $built = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $path)
            Check ("built {0}" -f $name) $built $buildOutput.Trim()
            if (-not $built) {
                throw ("go build failed for {0}/{1}; the rest of the rehearsal would verify a mixture of old and new binaries" -f $target.Goos, $target.Goarch)
            }
        }
    } finally {
        Pop-Location
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }

    Write-Host ''
    Write-Host 'sizes' -ForegroundColor Cyan
    foreach ($name in $expectedNames) {
        $item = Get-Item -LiteralPath (Join-Path $outPath $name)
        Write-Host ("  {0,-26} {1,8:N2} MB" -f $item.Name, ($item.Length / 1MB)) -ForegroundColor DarkGray
    }

    # --- checksums ----------------------------------------------------------
    Write-Host ''
    Write-Host 'SHA256SUMS.txt' -ForegroundColor Cyan

    # Ordinal order, so the file is byte-identical between runs and a diff of two releases cannot be
    # noise.
    $names = @($expectedNames)
    [Array]::Sort($names, [System.StringComparer]::Ordinal)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $names) {
        $lines.Add(('{0}  {1}' -f (Get-Sha256 (Join-Path $outPath $name)), $name))
    }
    # LF endings and no BOM, exactly as sha256sum writes it: a CRLF file fails on macOS and Linux
    # because the carriage return becomes part of the file name being checked.
    [System.IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Check 'wrote SHA256SUMS.txt with one line per artefact' ($lines.Count -eq $expectedNames.Count) ("lines={0}" -f $lines.Count)
}

# --- verify -----------------------------------------------------------------
Write-Host ''
Write-Host 'verify' -ForegroundColor Cyan

# A leftover hand_* file is how a release ends up shipping something nobody rebuilt, so it is a
# failure rather than a warning.
$handFiles = @(Get-ChildItem -LiteralPath $outPath -File -Filter 'hand_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$extra = @($handFiles | Where-Object { $expectedNames -notcontains $_ })
$missing = @($expectedNames | Where-Object { $handFiles -notcontains $_ })
$namesDetail = ''
if ($missing.Count -gt 0) { $namesDetail = 'missing: ' + ($missing -join ', ') }
if ($extra.Count -gt 0) {
    if ($namesDetail) { $namesDetail += '; ' }
    $namesDetail += 'not one of the six targets: ' + ($extra -join ', ')
}
Check 'the directory holds exactly the six artefacts, no more and no fewer' ($missing.Count -eq 0 -and $extra.Count -eq 0) $namesDetail

$sums = Read-Sums $sumsPath
$sumsDetail = 'missing'
if ($sums.Present) { $sumsDetail = $sums.Malformed -join '; ' }
Check 'SHA256SUMS.txt exists and parses as sha256sum output' ($sums.Present -and $sums.Malformed.Count -eq 0) $sumsDetail

$sumNames = @($sums.Entries.Keys)
$sumsMissing = @($expectedNames | Where-Object { $sumNames -notcontains $_ })
$sumsExtra = @($sumNames | Where-Object { $expectedNames -notcontains $_ })
$sumsProblems = @()
foreach ($name in $sumsMissing) { $sumsProblems += "missing line: $name" }
foreach ($name in $sumsExtra) { $sumsProblems += "unknown line: $name" }
Check 'SHA256SUMS.txt has one line per artefact' ($sumsMissing.Count -eq 0 -and $sumsExtra.Count -eq 0) ($sumsProblems -join '; ')

$artifactOk = @{}
foreach ($target in $targets) {
    $name = Get-ArtifactName $target
    $expected = ''
    if ($sums.Entries.ContainsKey($name)) { $expected = $sums.Entries[$name] }
    $verdict = Test-Artifact -Path (Join-Path $outPath $name) -Target $target -ExpectedSha256 $expected
    $artifactOk[$name] = (-not $verdict.Format) -and (-not $verdict.Hash)
    Check ("{0} is {1}" -f $name, $target.Want) (-not $verdict.Format) $verdict.Format
    Check ("{0} matches its SHA256SUMS.txt line" -f $name) (-not $verdict.Hash) $verdict.Hash
}

# --- run the artefact for this machine --------------------------------------
Write-Host ''
Write-Host 'run' -ForegroundColor Cyan

$hostGoos = (& go env GOOS | Out-String).Trim()
$hostGoarch = (& go env GOARCH | Out-String).Trim()
$hostTarget = $targets | Where-Object { $_.Goos -eq $hostGoos -and $_.Goarch -eq $hostGoarch } | Select-Object -First 1

if (-not $hostTarget) {
    Check 'the artefact for this machine runs' $false `
        ("this host is {0}/{1}, which is not one of the six targets; run the rehearsal on a machine this release supports" -f $hostGoos, $hostGoarch)
} else {
    $nativeName = Get-ArtifactName $hostTarget
    $native = Join-Path $outPath $nativeName
    $platform = "$hostGoos/$hostGoarch"

    if (-not (Test-Path -LiteralPath $native)) {
        Check ("{0} prints the injected version" -f $nativeName) $false 'missing'
    } elseif (-not $artifactOk[$nativeName]) {
        # Do not execute a file that failed verification: the failure above already says why, and
        # running it would turn a verification failure into a confusing crash.
        Check ("{0} prints the injected version" -f $nativeName) $false 'the artefact failed verification, so it was not executed'
    } else {
        $printed = & $native version 2>&1 | Out-String
        $runCode = $LASTEXITCODE
        $reported = $printed.Trim()

        if ($Version) {
            Check ("{0} prints the version it was built with ({1})" -f $nativeName, $Version) `
                ($runCode -eq 0 -and $printed.Contains($Version)) ("exit={0} output={1}" -f $runCode, $reported)
        } else {
            # -VerifyOnly without a version: the injected string is unknown, but a release build must
            # not still be carrying the "dev" default.
            $notDev = ($printed -match '^hand (?<v>\S+) ') -and ($Matches['v'] -ne 'dev')
            Check ("{0} reports a release version, not the dev default" -f $nativeName) ($runCode -eq 0 -and $notDev) `
                ("exit={0} output={1}" -f $runCode, $reported)
        }
        Check ("{0} prints its platform ({1})" -f $nativeName, $platform) ($printed.Contains($platform)) $reported
    }
}

# --- self-test: does verification actually reject anything? -----------------
if (-not $VerifyOnly) {
    Write-Host ''
    Write-Host 'self-test' -ForegroundColor Cyan

    # A verifier that only ever says PASS is indistinguishable from no verifier. Copy two artefacts
    # into a scratch directory, damage them in the two ways a transfer damages a file, and require the
    # same code path to reject both.
    $scratch = Join-Path $env:TEMP ('hand-release-selftest-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    try {
        $payloadTarget = $targets[0]   # linux/amd64
        $magicTarget = $targets[3]     # darwin/arm64
        $payloadName = Get-ArtifactName $payloadTarget
        $magicName = Get-ArtifactName $magicTarget

        $payloadCopy = Join-Path $scratch $payloadName
        $magicCopy = Join-Path $scratch $magicName
        Copy-Item -LiteralPath (Join-Path $outPath $payloadName) -Destination $payloadCopy
        Copy-Item -LiteralPath (Join-Path $outPath $magicName) -Destination $magicCopy

        $payloadHash = Get-Sha256 $payloadCopy
        $intact = Test-Artifact -Path $payloadCopy -Target $payloadTarget -ExpectedSha256 $payloadHash
        $intactDetail = (@($intact.Format, $intact.Hash) | Where-Object { $_ }) -join '; '
        Check 'an untouched copy passes verification' ((-not $intact.Format) -and (-not $intact.Hash)) $intactDetail

        # One byte in the middle: the header still says ELF, so only the digest can catch this - which
        # is the reason a release publishes one at all. The format check staying quiet is the point.
        $size = (Get-Item -LiteralPath $payloadCopy).Length
        Flip-Byte $payloadCopy ([int64]($size / 2))
        $damaged = Test-Artifact -Path $payloadCopy -Target $payloadTarget -ExpectedSha256 $payloadHash
        $damagedDetail = (@($damaged.Format, $damaged.Hash) | Where-Object { $_ }) -join '; '
        Check 'a corrupted payload is rejected by the digest, not by the header' `
            ((-not $damaged.Format) -and ($damaged.Hash -match '^sha256 mismatch')) $damagedDetail

        # Clobbered magic: the digest of this copy matches the line computed above, so only the format
        # check can reject it. That is the check that catches a build for the wrong architecture.
        Flip-Byte $magicCopy ([int64]0)
        $clobbered = Test-Artifact -Path $magicCopy -Target $magicTarget -ExpectedSha256 (Get-Sha256 $magicCopy)
        $clobberedDetail = (@($clobbered.Format, $clobbered.Hash) | Where-Object { $_ }) -join '; '
        Check 'a clobbered header is rejected by the format check, not by the digest' `
            (($clobbered.Format -ne '') -and (-not $clobbered.Hash)) $clobberedDetail
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- summary ----------------------------------------------------------------
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'RELEASE-REHEARSAL: all checks passed' -ForegroundColor Green
    Write-Host ("  artefacts: {0}" -f $outPath) -ForegroundColor DarkGray
    exit 0
}

Write-Host ("RELEASE-REHEARSAL: {0} check(s) failed" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
Write-Host ("  artefacts: {0}" -f $outPath) -ForegroundColor DarkGray
exit 1
