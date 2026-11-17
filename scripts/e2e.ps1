# End-to-end proof: brain + agent + lease + completion + brain crash.
#
#   scripts\e2e.ps1
#
# This is the claim in docs/DESIGN.md walked through with real processes:
#
#   1. the brain boots and serves a dashboard
#   2. an agent dials in and is enrolled
#   3. a job is submitted, split into shards, leased, executed, and reported back with digests
#   4. the brain is hard-killed mid-life and restarted; its state comes back from disk
#   5. a second job runs after the restart, proving the recovered brain still schedules
#
# It starts its own brain and agent on private ports and cleans up after itself.

[CmdletBinding()]
param(
    [int]$Port = 4310,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$brainDir = Join-Path $repo 'brain'
$agentDir = Join-Path $repo 'agent'
$helper = Join-Path $repo 'scripts\proof-helper.ps1'

$bootstrap = Join-Path (Split-Path -Parent $repo) '_bootstrap'
if (Test-Path -LiteralPath (Join-Path $bootstrap 'env.ps1')) { . (Join-Path $bootstrap 'env.ps1') | Out-Null }

$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

function Wait-Http([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
            if ($response.StatusCode -eq 200) { return $true }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return $false
}

# PowerShell 5.1 hands back a byte array when the response has no charset in its content type, so
# `-match` and ConvertFrom-Json silently see numbers instead of text. Decode explicitly.
function Get-Text([string]$Url) {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    return [string]$response.Content
}

function Get-State([string]$Base) {
    Get-Text "$Base/api/state" | ConvertFrom-Json
}

$work = Join-Path $env:TEMP ('hand-e2e-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$base = "http://127.0.0.1:$Port"
$token = 'e2e-token'

$env:HAND_PORT = "$Port"
$env:HAND_DATA = Join-Path $work 'data'
$env:HAND_TOKEN = $token
$env:MIX_ENV = 'dev'

$brainProcess = $null
$agentProcess = $null

function Start-Brain {
    $out = Join-Path $work 'brain.out'
    $err = Join-Path $work 'brain.err'
    $mix = (Get-Command mix.bat -ErrorAction SilentlyContinue)
    if (-not $mix) { throw 'mix.bat not found: run _bootstrap\env.ps1 first' }

    Start-Process -FilePath $mix.Source -ArgumentList 'run', '--no-halt' -WorkingDirectory $brainDir `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
}

try {
    Write-Host 'building hand.exe' -ForegroundColor Cyan
    Push-Location $agentDir
    try {
        & go build -o hand.exe .\cmd\hand
        if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
    $hand = Join-Path $agentDir 'hand.exe'

    Write-Host ''
    Write-Host 'proof 1: brain boots and serves the dashboard' -ForegroundColor Cyan
    $brainProcess = Start-Brain
    $up = Wait-Http "$base/health" $TimeoutSeconds
    Check 'brain answers /health' $up "$base/health"

    if (-not $up) {
        $errText = Get-Content -LiteralPath (Join-Path $work 'brain.err') -Raw -ErrorAction SilentlyContinue
        throw "brain did not start. stderr:`n$errText"
    }

    $page = Get-Text "$base/"
    Check 'dashboard renders' ($page -match 'handmedown' -and $page -match 'devices')

    Write-Host ''
    Write-Host 'proof 2: an agent joins' -ForegroundColor Cyan
    $agentOut = Join-Path $work 'agent.out'
    $agentErr = Join-Path $work 'agent.err'
    $agentProcess = Start-Process -FilePath $hand `
        -ArgumentList 'join', '--brain', $base, '--token', $token `
        -WorkingDirectory $work -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $agentOut -RedirectStandardError $agentErr

    $deadline = (Get-Date).AddSeconds(30)
    $nodeCount = 0
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Get-State $base
            $nodeCount = @($state.nodes).Count
            if ($nodeCount -ge 1) { break }
        } catch { }
        Start-Sleep -Milliseconds 300
    }
    Check 'the fleet shows one device' ($nodeCount -eq 1) "nodes=$nodeCount"

    Write-Host ''
    Write-Host 'proof 3: a job is leased and completed' -ForegroundColor Cyan
    $submit = & $hand submit --brain $base --token $token `
        --inputs (Join-Path $repo 'fixtures\samples\*.txt') --shards 2 --outdir (Join-Path $work 'out') `
        -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper 2>&1
    Check 'submit accepted' ($LASTEXITCODE -eq 0) ($submit | Out-String).Trim()

    $jobId = $null
    if (($submit | Out-String) -match 'job\s+([0-9a-f]+)') { $jobId = $Matches[1] }
    Check 'submit returned a job id' ($null -ne $jobId) ($submit | Out-String).Trim()

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $job = $null
    while ((Get-Date) -lt $deadline) {
        $state = Get-State $base
        $job = @($state.state.jobs) | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
        if ($job -and $job.status -in @('done', 'partial', 'conflicted')) { break }
        Start-Sleep -Milliseconds 300
    }

    $jobShards = @(@($state.state.shards) | Where-Object { $_.job_id -eq $jobId })
    $doneShards = @($jobShards | Where-Object { $_.status -eq 'done' })
    Check 'the job completed' ($job -and $job.status -eq 'done') "status=$($job.status)"
    Check 'every shard reported done' ($doneShards.Count -eq 2) "done=$($doneShards.Count) of $($jobShards.Count)"
    Check 'every done shard has a digest' (@($doneShards | Where-Object { $_.digest }).Count -eq 2)

    $outputs = @(Get-ChildItem -LiteralPath (Join-Path $work 'out') -Recurse -File -ErrorAction SilentlyContinue)
    Check 'outputs landed on disk' ($outputs.Count -eq 5) "files=$($outputs.Count)"

    Write-Host ''
    Write-Host 'proof 4: the brain is hard-killed and restarts from disk' -ForegroundColor Cyan

    # Kill the VM itself, not the .bat wrapper that launched it: the wrapper exits immediately and
    # leaves the VM running, which would make this proof a lie. On Windows the OTP VM is erl.exe.
    # Kill the VMs themselves, not the .bat wrapper that launched them: the wrapper exits immediately
    # and leaves the VM running, which would make this proof a lie. On Windows the OTP VM is erl.exe,
    # and one launch can leave more than one of them behind, so this kills all of the recent ones.
    $vms = @(Get-Process -Name 'erl*', 'beam*', 'werl*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -gt (Get-Date).AddMinutes(-5) })
    if ($vms.Count -eq 0) { throw 'no Erlang VM process found to kill' }
    foreach ($vm in $vms) { Stop-Process -Id $vm.Id -Force -ErrorAction SilentlyContinue }

    $downAfterKill = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri "$base/health" -UseBasicParsing -TimeoutSec 1 | Out-Null
            Start-Sleep -Milliseconds 200
        } catch {
            $downAfterKill = $true
            break
        }
    }
    Check 'the brain really stopped' $downAfterKill

    $brainProcess = Start-Brain
    $backUp = Wait-Http "$base/health" $TimeoutSeconds
    Check 'the brain came back' $backUp

    $state = Get-State $base
    $reloaded = @($state.state.jobs) | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
    Check 'the finished job survived the restart' ($reloaded -and $reloaded.status -eq 'done') "status=$($reloaded.status)"
    $reloadedShards = @(@($state.state.shards) | Where-Object { $_.job_id -eq $jobId })
    Check 'shards survived with their digests' (@($reloadedShards | Where-Object { $_.digest }).Count -eq 2)

    Write-Host ''
    Write-Host 'proof 5: the recovered brain still schedules' -ForegroundColor Cyan
    # The agent reconnects on its own; give it a moment, then run one more job.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $state = Get-State $base
        if (@($state.nodes).Count -ge 1) { break }
        Start-Sleep -Milliseconds 300
    }

    $submit2 = & $hand submit --brain $base --token $token `
        --inputs (Join-Path $repo 'fixtures\samples\*.txt') --shards 1 --outdir (Join-Path $work 'out2') `
        -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper 2>&1
    Check 'second submit accepted' ($LASTEXITCODE -eq 0) ($submit2 | Out-String).Trim()

    $jobId2 = $null
    if (($submit2 | Out-String) -match 'job\s+([0-9a-f]+)') { $jobId2 = $Matches[1] }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $job2 = $null
    while ((Get-Date) -lt $deadline) {
        $state = Get-State $base
        $job2 = @($state.state.jobs) | Where-Object { $_.id -eq $jobId2 } | Select-Object -First 1
        if ($job2 -and $job2.status -in @('done', 'partial', 'conflicted')) { break }
        Start-Sleep -Milliseconds 300
    }
    Check 'the second job completed after the restart' ($job2 -and $job2.status -eq 'done') "status=$($job2.status)"
}
catch {
    Write-Host ''
    Write-Host ("e2e aborted: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $script:failures.Add('exception')
}
finally {
    foreach ($process in @($agentProcess, $brainProcess)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    foreach ($vm in @(Get-Process -Name 'erl*', 'beam*', 'werl*' -ErrorAction SilentlyContinue)) {
        if ($vm.StartTime -gt (Get-Date).AddMinutes(-5)) { Stop-Process -Id $vm.Id -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'E2E: all checks passed' -ForegroundColor Green
    Write-Host "  work directory kept for inspection: $work" -ForegroundColor DarkGray
    exit 0
}

Write-Host ("E2E: {0} check(s) failed" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
Write-Host "  work directory: $work" -ForegroundColor DarkGray
exit 1
