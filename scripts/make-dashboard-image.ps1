# Capture docs/dashboard.png from a real, running brain.
#
#   scripts\make-dashboard-image.ps1
#
# The picture is a capture of the dashboard the product actually serves, with a real agent connected and
# a real job in flight. Nothing is mocked or drawn: if the dashboard breaks, this script fails, which is
# the point - the README image cannot depict a UI that no longer exists.
#
# It starts a private brain and agent on an ephemeral port and cleans both up afterwards. Edge provides
# the headless browser; if it is missing the script says so rather than producing a fake.

[CmdletBinding()]
param(
    [int]$ClipCount = 6,
    [int]$ShardCount = 2,
    [int]$ShotWidth = 1180,
    [int]$ShotHeight = 620
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$brainDir = Join-Path $repo 'brain'
$agentDir = Join-Path $repo 'agent'
$helper = Join-Path $repo 'scripts\proof-helper.ps1'
$output = Join-Path $repo 'docs\dashboard.png'

$bootstrap = Join-Path (Split-Path -Parent $repo) '_bootstrap'
if (-not (Get-Command go -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $bootstrap 'env.ps1'))) {
    . (Join-Path $bootstrap 'env.ps1') | Out-Null
}

$edgeCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
)
$edge = $edgeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $edge) {
    throw 'Microsoft Edge not found: this machine has no headless browser, so the dashboard cannot be captured. A hand-made image is not an acceptable substitute.'
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

function Get-Text([string]$Url) {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
    if ($response.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($response.Content) }
    return [string]$response.Content
}

$work = Join-Path $env:TEMP ('hand-dashboard-' + [guid]::NewGuid().ToString('n'))
$inDir = Join-Path $work 'in'
New-Item -ItemType Directory -Force -Path $inDir | Out-Null
for ($i = 1; $i -le $ClipCount; $i++) {
    Set-Content -LiteralPath (Join-Path $inDir ("clip-{0:d2}.mov" -f $i)) -Value ("frame $i") -NoNewline
}

$port = Get-FreePort
$token = 'dashboard-capture'
$base = "http://127.0.0.1:$port"

$brainProcess = $null
$agentProcess = $null

try {
    Write-Host 'building hand.exe' -ForegroundColor Cyan
    Push-Location $agentDir
    try { & go build -o hand.exe .\cmd\hand; if ($LASTEXITCODE -ne 0) { throw 'go build failed' } } finally { Pop-Location }
    $hand = Join-Path $agentDir 'hand.exe'

    Write-Host "starting brain on $base" -ForegroundColor Cyan
    $previousPort = $env:HAND_PORT; $previousData = $env:HAND_DATA; $previousToken = $env:HAND_TOKEN
    $env:HAND_PORT = "$port"
    $env:HAND_DATA = (Join-Path $work 'data')
    $env:HAND_TOKEN = $token

    $mix = (Get-Command mix.bat -ErrorAction SilentlyContinue)
    if (-not $mix) { throw 'mix.bat not found: run _bootstrap\env.ps1 first' }
    $brainProcess = Start-Process -FilePath $mix.Source -ArgumentList 'run', '--no-halt' -WorkingDirectory $brainDir `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'brain.out') -RedirectStandardError (Join-Path $work 'brain.err')

    $up = $false
    for ($i = 0; $i -lt 120; $i++) {
        try { if ((Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $up = $true; break } } catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $up) { throw "brain did not start: $(Get-Content (Join-Path $work 'brain.err') -Raw -ErrorAction SilentlyContinue)" }

    Write-Host 'joining an agent' -ForegroundColor Cyan
    # A slow command keeps the job visibly in flight while the screenshot is taken; a job that finishes
    # instantly would be captured as a row of "done" and would show nothing about the scheduler.
    $env:HAND_PROOF_DELAY_MS = '2500'
    $agentProcess = Start-Process -FilePath $hand -ArgumentList 'join', '--brain', $base, '--token', $token `
        -WorkingDirectory $repo -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $work 'agent.out') -RedirectStandardError (Join-Path $work 'agent.err')

    $joined = $false
    for ($i = 0; $i -lt 100; $i++) {
        try { if ((Get-Text "$base/api/state" | ConvertFrom-Json).nodes.Count -ge 1) { $joined = $true; break } } catch { }
        Start-Sleep -Milliseconds 300
    }
    if (-not $joined) { throw 'the agent did not join; cannot capture a fleet that is not there' }

    Write-Host 'submitting a job' -ForegroundColor Cyan
    $body = @{
        cmd = @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper)
        inputs = @(Get-ChildItem -LiteralPath $inDir -File | ForEach-Object { $_.FullName })
        shards = $ShardCount
        outdir = (Join-Path $work 'out')
    } | ConvertTo-Json -Compress
    Invoke-WebRequest -Uri "$base/api/jobs" -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 | Out-Null

    # Wait until work is visibly in progress: at least one shard leased, and progress recorded.
    $inFlight = $false
    for ($i = 0; $i -lt 100; $i++) {
        $state = Get-Text "$base/api/state" | ConvertFrom-Json
        $shards = @($state.state.shards)
        if (@($shards | Where-Object { $_.status -eq 'leased' }).Count -ge 1) { $inFlight = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $inFlight) { throw 'no shard became leased; the dashboard would show an idle fleet' }

    # A shard that is leased but has not reported progress looks stalled. Wait for a completed input so
    # the progress bar in the picture is non-empty.
    for ($i = 0; $i -lt 100; $i++) {
        $state = Get-Text "$base/api/state" | ConvertFrom-Json
        if (@(@($state.state.shards) | Where-Object { $_.done -gt 0 }).Count -ge 1) { break }
        Start-Sleep -Milliseconds 200
    }

    Write-Host 'capturing' -ForegroundColor Cyan
    Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    $profileDir = Join-Path $work 'edge-profile'
    # The dashboard keeps an SSE connection open, so a headless browser never considers the page
    # "finished" and `--screenshot` alone can hang forever waiting for idle network. Start it, wait for
    # the PNG to appear, then kill the browser: the screenshot is written as soon as layout settles.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $browser = $null
    try {
        $browserArgs = @(
            '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
            '--hide-scrollbars', '--disable-extensions', '--disable-background-networking',
            "--user-data-dir=$profileDir",
            "--window-size=$ShotWidth,$ShotHeight",
            '--virtual-time-budget=3500',
            "--screenshot=$output",
            "$base/?live=0"
        )
        $browser = Start-Process -FilePath $edge -ArgumentList $browserArgs -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $work 'edge.out') -RedirectStandardError (Join-Path $work 'edge.err')

        $captured = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            if ((Test-Path -LiteralPath $output) -and ((Get-Item -LiteralPath $output).Length -gt 0)) {
                $captured = $true
                break
            }
            if ($browser.HasExited -and $i -gt 4) { break }
        }
    } finally {
        if ($browser -and -not $browser.HasExited) { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
        Get-Process -Name 'msedge' -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -gt (Get-Date).AddMinutes(-3) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $previous
    }

    # Edge can return before the file is flushed.
    for ($i = 0; $i -lt 40; $i++) {
        if ((Test-Path -LiteralPath $output) -and ((Get-Item -LiteralPath $output).Length -gt 0)) { break }
        Start-Sleep -Milliseconds 250
    }

    if (-not (Test-Path -LiteralPath $output)) { throw 'Edge produced no screenshot' }

    $size = (Get-Item -LiteralPath $output).Length
    Write-Host ("wrote {0} ({1:N0} KB)" -f $output, ($size / 1KB)) -ForegroundColor Green
    if ($size -lt 5000) { throw "screenshot is only $size bytes: it is almost certainly a blank page" }
} finally {
    $env:HAND_PORT = $previousPort; $env:HAND_DATA = $previousData; $env:HAND_TOKEN = $previousToken
    $env:HAND_PROOF_DELAY_MS = $null
    foreach ($process in @($agentProcess, $brainProcess)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    foreach ($vm in @(Get-Process -Name 'erl*', 'beam*', 'werl*' -ErrorAction SilentlyContinue)) {
        if ($vm.StartTime -gt (Get-Date).AddMinutes(-5)) { Stop-Process -Id $vm.Id -Force -ErrorAction SilentlyContinue }
    }
}
