# Keep the size figures in the docs honest.
#
#   scripts\measure-sizes.ps1            # report the measured sizes and what the docs claim
#   scripts\measure-sizes.ps1 -Check     # exit non-zero if they disagree
#   scripts\measure-sizes.ps1 -Update    # rewrite the docs with the measured values
#
# The figures appear inside HTML comments so they render as plain values but can be found and replaced:
#
#   | `hand.exe` (agent, stripped) | <!-- size:agent -->7.08 MB<!-- /size:agent --> |
#
# Why this exists: the numbers are an argument (Go ships small, OTP does not), and an argument with a
# stale number is just a claim. They had already drifted once before this script existed.

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$agent = Join-Path $repo 'agent'
$brain = Join-Path $repo 'brain'

if (-not (Get-Command go -ErrorAction SilentlyContinue) -or -not (Get-Command mix -ErrorAction SilentlyContinue)) {
    $envPs1 = Join-Path (Split-Path -Parent $repo) '_bootstrap\env.ps1'
    if (Test-Path -LiteralPath $envPs1) { . $envPs1 | Out-Null }
}

# Both documents cite the figures; both are updated from the same measurement so they cannot disagree.
$documents = @(
    (Join-Path $repo 'docs\WHY-TWO-LANGUAGES.md')
    (Join-Path $repo 'CHANGELOG.md')
)

function Measure-AgentMB {
    Push-Location $agent
    try {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('hand-measure-' + [guid]::NewGuid().ToString('n') + '.exe')
        # The release shape: stripped, trimmed, no debug info. Measuring a debug build would flatter
        # nothing and mislead the reader.
        & go build -trimpath -ldflags '-s -w' -o $out .\cmd\hand
        if ($LASTEXITCODE -ne 0) { throw 'agent build failed' }
        $mb = (Get-Item -LiteralPath $out).Length / 1MB
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        return $mb
    } finally { Pop-Location }
}

function Measure-BrainMB {
    Push-Location $brain
    try {
        # prod, because that is what the release workflow ships. Measuring dev would report a size
        # that no user ever downloads.
        $env:MIX_ENV = 'prod'
        try {
            & mix deps.get --only prod 2>&1 | Out-Null
            & mix release --overwrite 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'brain release build failed' }
        } finally {
            $env:MIX_ENV = $null
        }
        $release = Join-Path $brain '_build\prod\rel\handmedown'
        if (-not (Test-Path -LiteralPath $release)) { throw "release directory not found: $release" }
        $bytes = (Get-ChildItem -LiteralPath $release -Recurse -File | Measure-Object -Property Length -Sum).Sum
        return $bytes / 1MB
    } finally { Pop-Location }
}

function Format-Size([double]$MB) {
    return ('{0:N2} MB' -f $MB)
}

Write-Host 'measuring' -ForegroundColor Cyan
$agentMB = Measure-AgentMB
Write-Host ("  agent (stripped): {0}" -f (Format-Size $agentMB))

$brainMB = Measure-BrainMB
Write-Host ("  brain release:    {0}" -f (Format-Size $brainMB))

$measured = @{
    'agent' = Format-Size $agentMB
    'brain' = Format-Size $brainMB
    # The ratio is the actual argument in the prose, so it is measured too rather than remembered.
    'ratio' = ('{0:N1}x' -f ($brainMB / $agentMB))
}

$mismatches = New-Object 'System.Collections.Generic.List[string]'
$updated = 0

foreach ($document in $documents) {
    if (-not (Test-Path -LiteralPath $document)) { throw "missing document: $document" }
    $text = [System.IO.File]::ReadAllText($document, [System.Text.Encoding]::UTF8)
    $original = $text

    foreach ($key in $measured.Keys) {
        $pattern = "(?s)(<!-- size:$key -->)(.*?)(<!-- /size:$key -->)"
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $claimed = $match.Groups[2].Value
            $wanted = $measured[$key]
            if ($claimed -ne $wanted) {
                if ($Update) {
                    $text = [regex]::Replace($text, $pattern, ('${1}' + $wanted + '${3}'))
                } else {
                    $mismatches.Add(("{0}: {1} claims '{2}', measured '{3}'" -f [System.IO.Path]::GetFileName($document), $key, $claimed, $wanted))
                }
            }
        }
    }

    if ($Update -and $text -ne $original) {
        [System.IO.File]::WriteAllText($document, $text, (New-Object System.Text.UTF8Encoding($false)))
        $updated++
    }
}

Write-Host ''
if ($Update) {
    Write-Host ("updated {0} document(s)" -f $updated) -ForegroundColor Green
    exit 0
}

if ($mismatches.Count -gt 0) {
    Write-Host 'SIZES DRIFTED' -ForegroundColor Red
    foreach ($mismatch in $mismatches) { Write-Host "  - $mismatch" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Run: scripts\measure-sizes.ps1 -Update' -ForegroundColor Yellow
    exit 1
}

Write-Host 'SIZES: docs match the build' -ForegroundColor Green
exit 0
