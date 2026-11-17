# The command under test in scripts\proofs.ps1.
#
# It imitates real work: reads the input, takes a moment, writes content-addressed output through
# HAND_OUTPUT, and appends to a counter file so the proof can count *executions*, not just outputs.
#
# Kept as a script rather than an exe so the proof has no build step of its own.

$ErrorActionPreference = 'Stop'

$inputPath = $env:HAND_INPUT
$outputPath = $env:HAND_OUTPUT

if ([string]::IsNullOrEmpty($inputPath) -or [string]::IsNullOrEmpty($outputPath)) {
    Write-Error 'proof-helper: HAND_INPUT and HAND_OUTPUT must both be set'
    exit 9
}

$content = Get-Content -LiteralPath $inputPath -Raw

# Long enough that a kill lands mid-run, short enough that twelve inputs stay quick.
Start-Sleep -Milliseconds 250

$parent = Split-Path -Parent $outputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

Set-Content -LiteralPath $outputPath -Value ("out:" + $content) -NoNewline

# One line per execution. This is what distinguishes "the work was skipped" from "the work was redone
# and happened to produce the same bytes".
if (-not [string]::IsNullOrEmpty($env:HAND_COUNTER)) {
    Add-Content -LiteralPath $env:HAND_COUNTER -Value $inputPath
}

exit 0
