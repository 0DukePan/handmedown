# Behavioural proofs for the claims in docs/DESIGN.md.
#
#   scripts\proofs.ps1
#
# These are not unit tests. They spawn a real `hand run`, kill it with a hard terminate (the Windows
# equivalent of kill -9) in the middle, run it again, and check the promises the README makes:
#
#   1. every input ends up with exactly one output
#   2. an input finished before the kill is never executed again
#   3. the journal replays cleanly: contiguous sequence numbers, no corrupt lines
#   4. the resume is announced, not silent

[CmdletBinding()]
param(
    [int]$Inputs = 12,
    [int]$KillAfterMs = 2500
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$agent = Join-Path $repo 'agent'
$helper = Join-Path $repo 'scripts\proof-helper.ps1'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    $envPs1 = Join-Path (Split-Path -Parent $repo) '_bootstrap\env.ps1'
    if (Test-Path -LiteralPath $envPs1) { . $envPs1 | Out-Null }
}

$failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor Red
        $failures.Add($Name)
    }
}

# --- build -----------------------------------------------------------------
Write-Host 'building hand.exe' -ForegroundColor Cyan
Push-Location $agent
try {
    & go build -o hand.exe .\cmd\hand
    if ($LASTEXITCODE -ne 0) { throw "go build failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }
$hand = Join-Path $agent 'hand.exe'

# --- fixture ---------------------------------------------------------------
$work = Join-Path $env:TEMP ('hand-proof-' + [guid]::NewGuid().ToString('n'))
$inDir = Join-Path $work 'in'
$outDir = Join-Path $work 'out'
$journalDir = Join-Path $work 'journal'
$counter = Join-Path $work 'counter.txt'
foreach ($dir in $inDir, $outDir, $journalDir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

for ($i = 1; $i -le $Inputs; $i++) {
    Set-Content -LiteralPath (Join-Path $inDir ("input-{0:d3}.txt" -f $i)) -Value ("payload-$i") -NoNewline
}

$handArgs = @(
    'run'
    '--inputs', (Join-Path $inDir '*.txt')
    '--outdir', $outDir
    '--journal', $journalDir
    '--', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper
)

$env:HAND_COUNTER = $counter

Write-Host ''
Write-Host 'proof 1: killed mid-run, then resumed' -ForegroundColor Cyan

$stdout1 = Join-Path $work 'run1.out'
$stderr1 = Join-Path $work 'run1.err'
$process = Start-Process -FilePath $hand -ArgumentList $handArgs -PassThru -NoNewWindow `
    -RedirectStandardOutput $stdout1 -RedirectStandardError $stderr1

Start-Sleep -Milliseconds $KillAfterMs

# Snapshot what had already been executed *before* the kill: those inputs must never run again.
$doneBefore = @()
if (Test-Path -LiteralPath $counter) {
    $doneBefore = @(Get-Content -LiteralPath $counter | Where-Object { $_ -ne '' })
}

$wasRunning = -not $process.HasExited
if ($wasRunning) {
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
}
Write-Host ("  killed after {0} ms; {1} input(s) had finished" -f $KillAfterMs, $doneBefore.Count)

# Let the orphaned child command settle, so the counter cannot be appended to mid-check.
Start-Sleep -Milliseconds 800

Check 'the kill interrupted work in progress' ($wasRunning -and $doneBefore.Count -gt 0) `
    "running=$wasRunning finishedBeforeKill=$($doneBefore.Count)"

$stdout2 = Join-Path $work 'run2.out'
$stderr2 = Join-Path $work 'run2.err'
$second = Start-Process -FilePath $hand -ArgumentList $handArgs -PassThru -NoNewWindow -Wait `
    -RedirectStandardOutput $stdout2 -RedirectStandardError $stderr2

$resumeOutput = Get-Content -LiteralPath $stdout2 -Raw
$resumeErrors = Get-Content -LiteralPath $stderr2 -Raw

Check 'the resumed run succeeded' ($second.ExitCode -eq 0) "exit=$($second.ExitCode) stderr=$resumeErrors"
Check 'the resume is announced' ($resumeOutput -match 'resuming: \d+ of \d+') ''

# --- assertions ------------------------------------------------------------
Write-Host ''
Write-Host 'proof 2: every input has exactly one output' -ForegroundColor Cyan

$outputs = @(Get-ChildItem -LiteralPath (Join-Path $outDir '1-of-1') -File -ErrorAction SilentlyContinue)
Check ("outputs = {0}, want {1}" -f $outputs.Count, $Inputs) ($outputs.Count -eq $Inputs) ''

$emptyOutputs = @($outputs | Where-Object { $_.Length -le 3 })
Check 'no output is empty or truncated' ($emptyOutputs.Count -eq 0) ("empty: " + ($emptyOutputs.Name -join ', '))

Write-Host ''
Write-Host 'proof 3: finished work was not executed twice' -ForegroundColor Cyan

$executions = @(Get-Content -LiteralPath $counter | Where-Object { $_ -ne '' })
$repeated = @()
foreach ($path in $doneBefore) {
    $times = @($executions | Where-Object { $_ -eq $path }).Count
    if ($times -gt 1) { $repeated += ("{0} x{1}" -f (Split-Path -Leaf $path), $times) }
}
Check ("inputs finished before the kill were executed exactly once ({0} checked)" -f $doneBefore.Count) `
    ($repeated.Count -eq 0) ($repeated -join ', ')

$uniqueInputs = @($executions | Sort-Object -Unique)
Check 'every input was executed at least once' ($uniqueInputs.Count -eq $Inputs) `
    ("executed {0} of {1}" -f $uniqueInputs.Count, $Inputs)

# One extra execution is allowed: the input in flight when the kill landed had no journal record yet,
# so redoing it is correct behaviour, not a bug. Anything more means the resume point is wrong.
$worked = $executions.Count
Check ("total executions = {0}, want at most {1}" -f $worked, ($Inputs + 1)) ($worked -le ($Inputs + 1)) `
    ("{0} executions for {1} inputs; finished-before-kill were {2}" -f $worked, $Inputs, $doneBefore.Count)

Write-Host ''
Write-Host 'proof 4: the journal replays cleanly' -ForegroundColor Cyan

$journalFiles = @(Get-ChildItem -LiteralPath $journalDir -Recurse -Filter '*.jsonl')
Check 'exactly one journal file' ($journalFiles.Count -eq 1) ("found $($journalFiles.Count)")

$sequenceOk = $true
$parseOk = $true
$lastSeq = 0
$items = 0
$done = $false
foreach ($line in (Get-Content -LiteralPath $journalFiles[0].FullName)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $record = $line | ConvertFrom-Json } catch { $parseOk = $false; continue }
    if ($record.seq -ne ($lastSeq + 1)) { $sequenceOk = $false }
    $lastSeq = $record.seq
    if ($record.op -eq 'item') { $items++ }
    if ($record.op -eq 'done') { $done = $true }
}
Check 'every journal line parses' $parseOk ''
Check 'journal sequence numbers are contiguous' $sequenceOk "last seq = $lastSeq"
Check ("journal records one item per input ({0})" -f $items) ($items -eq $Inputs) ''
Check 'journal ends with a done record' $done ''

# --- summary ---------------------------------------------------------------
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'PROOF: all checks passed' -ForegroundColor Green
    Write-Host "  work directory kept for inspection: $work" -ForegroundColor DarkGray
    exit 0
}

Write-Host ("PROOF: {0} check(s) failed" -f $failures.Count) -ForegroundColor Red
foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
Write-Host "  work directory: $work" -ForegroundColor DarkGray
exit 1
