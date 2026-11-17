# One entry point for the things you do to this repo.
#
#   scripts\tasks.ps1 check        format check, vet, compile, test - both halves
#   scripts\tasks.ps1 fmt          format both halves in place
#   scripts\tasks.ps1 build        hand.exe + brain release
#   scripts\tasks.ps1 agent        run the agent from source
#   scripts\tasks.ps1 brain        run the brain (dev)
#   scripts\tasks.ps1 proof        behavioural proofs: crash-resume, lease expiry, digest conflict
#
# There is deliberately no Makefile: `make` is not on Windows by default, and a task runner that only
# half the contributors can run is worse than none.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'fmt', 'build', 'agent', 'brain', 'proof', 'help')]
    [string]$Task = 'help',

    # Everything after the task name, passed through to `go run` for the `agent` task.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$agent = Join-Path $repo 'agent'
$brain = Join-Path $repo 'brain'

function Need-Toolchains {
    if (-not (Get-Command go -ErrorAction SilentlyContinue) -or -not (Get-Command mix -ErrorAction SilentlyContinue)) {
        $env_ps1 = Join-Path (Split-Path -Parent $repo) '_bootstrap\env.ps1'
        if (Test-Path -LiteralPath $env_ps1) {
            . $env_ps1 | Out-Null
        }
    }
    foreach ($tool in 'go', 'mix') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool not found. Run: . $((Split-Path -Parent $repo))\_bootstrap\env.ps1  (or install the toolchain)"
        }
    }
}

function Step([string]$Name, [scriptblock]$Body) {
    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
    & $Body
    if ($LASTEXITCODE -ne 0) { throw "$Name failed (exit $LASTEXITCODE)" }
}

function Invoke-Check {
    Need-Toolchains
    Push-Location $agent
    try {
        # gofmt -l prints files; any output at all is a failure.
        $unformatted = & gofmt -l . 2>&1
        if ($unformatted) { throw "gofmt: these files need formatting ->`n$unformatted" }
        "gofmt: clean"
        Step 'go vet' { go vet ./... }
        Step 'go test' { go test ./... }
        Step 'go build' { go build -o hand.exe .\cmd\hand }
    } finally { Pop-Location }

    Push-Location $brain
    try {
        Step 'mix deps.get' { mix deps.get }
        Step 'mix format --check-formatted' { mix format --check-formatted }
        Step 'mix compile --warnings-as-errors' { mix compile --warnings-as-errors }
        Step 'mix test' { mix test }
    } finally { Pop-Location }
    Write-Host ''
    Write-Host 'check: ok' -ForegroundColor Green
}

function Invoke-Fmt {
    Need-Toolchains
    Push-Location $agent;  try { Step 'gofmt -w' { gofmt -w . } } finally { Pop-Location }
    Push-Location $brain;  try { Step 'mix format' { mix format } } finally { Pop-Location }
}

function Invoke-Build {
    Need-Toolchains
    Push-Location $agent
    try {
        Step 'go build (release)' { go build -trimpath -ldflags "-s -w" -o hand.exe .\cmd\hand }
        $exe = Get-Item .\hand.exe
        "hand.exe: {0:N2} MB" -f ($exe.Length / 1MB)
    } finally { Pop-Location }
    Push-Location $brain
    try { Step 'mix release' { mix release --overwrite } } finally { Pop-Location }
}

function Invoke-Proof {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\proofs.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "scripts\proofs.ps1 does not exist yet: the behavioural proofs are built in M2 and M5."
    }
    & $script
    if ($LASTEXITCODE -ne 0) { throw "proofs failed (exit $LASTEXITCODE)" }
}

switch ($Task) {
    'check' { Invoke-Check }
    'fmt'   { Invoke-Fmt }
    'build' { Invoke-Build }
    'agent' {
        Need-Toolchains
        Push-Location $agent; try { & go run .\cmd\hand @Rest } finally { Pop-Location }
    }
    'brain' {
        Need-Toolchains
        Push-Location $brain; try { mix phx.server } finally { Pop-Location }
    }
    'proof' { Invoke-Proof }
    default {
        @'
handmedown tasks

  scripts\tasks.ps1 check     format check, vet, compile, test - both halves
  scripts\tasks.ps1 fmt       format both halves in place
  scripts\tasks.ps1 build     hand.exe + brain release
  scripts\tasks.ps1 agent ..  run the agent from source (args are passed through)
  scripts\tasks.ps1 brain     run the brain in dev
  scripts\tasks.ps1 proof     behavioural proofs: crash-resume, lease expiry, digest conflict

Toolchains: _bootstrap\env.ps1 is loaded automatically when go/mix are not on PATH.
'@ | Write-Host
    }
}
