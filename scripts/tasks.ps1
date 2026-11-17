# One entry point for the things you do to this repo.
#
#   scripts\tasks.ps1 check        format check, vet, compile, test - both halves
#   scripts\tasks.ps1 fmt          format both halves in place
#   scripts\tasks.ps1 build        hand.exe + brain release
#   scripts\tasks.ps1 agent        run the agent from source
#   scripts\tasks.ps1 brain        run the brain (dev)
#   scripts\tasks.ps1 proof        local proof: hard-kill a run, prove finished work is not repeated
#   scripts\tasks.ps1 e2e          end-to-end: brain, agent, lease, completion, brain crash
#   scripts\tasks.ps1 release-rehearsal [vX.Y.Z]   build + verify the six release artefacts offline
#   scripts\tasks.ps1 release-test                 test that rehearsal: names, formats, checksums, corruption
#
# There is deliberately no Makefile: `make` is not on Windows by default, and a task runner that only
# half the contributors can run is worse than none.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'fmt', 'build', 'agent', 'brain', 'proof', 'e2e', 'release-rehearsal', 'release-test', 'test-installers', 'test-workflows', 'measure-sizes', 'test-readme', 'demo-gif', 'dashboard-image', 'help')]
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
    # Offline and instant, so it belongs in the normal gate: a workflow that stopped matching the
    # artefact contract is a broken release waiting to happen.
    Step 'workflow contract' { Invoke-ChildScript (Join-Path $repo 'scripts\test-workflows.ps1') }

    # The README is documentation, and documentation that lies is a bug. This is offline and quick.
    Step 'readme claims' { Invoke-ChildScript (Join-Path $repo 'scripts\test-readme.ps1') }

    # The quoted sizes drift the moment anyone touches the build; catching that here is why the numbers
    # are measured instead of remembered.
    Step 'documented sizes' { Invoke-ChildScript (Join-Path $repo 'scripts\measure-sizes.ps1') -Arguments @('-Check') }

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

# Runs a proof script as a child PowerShell process.
#
# These scripts finish with `exit N`. Invoked with `&`, that exit would terminate *this* runner - a
# failing proof would kill the task runner silently instead of reporting the failure. A child process
# gives a real exit code and leaves the runner alive to explain what happened.
function Invoke-ChildScript([string]$Path, [string[]]$Arguments = @()) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Path is missing" }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # A proof script that fails writes to stderr on purpose. With 'Stop', PowerShell 5.1 would turn that
    # into a NativeCommandError and bury the exit code, so relax it just for the call and throw our own,
    # clearer message afterwards.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) { throw "$([System.IO.Path]::GetFileName($Path)) failed (exit $code)" }
}

function Invoke-DemoGif {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\make-demo-gif.py'
    if (-not (Test-Path -LiteralPath $script)) { throw 'scripts\make-demo-gif.py is missing' }

    # Pillow is not a project dependency; it is a tool for regenerating an asset. Say so clearly.
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw 'python is not on PATH: Pillow is needed to regenerate the demo GIF' }
    & $python.Source $script
    if ($LASTEXITCODE -ne 0) { throw "make-demo-gif.py failed (exit $LASTEXITCODE)" }
}

function Invoke-DashboardImage {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\make-dashboard-image.ps1'
    Invoke-ChildScript $script
}

function Invoke-TestReadme {
    $script = Join-Path $repo 'scripts\test-readme.ps1'
    Invoke-ChildScript $script
}

function Invoke-MeasureSizes {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\measure-sizes.ps1'
    # Passing "update" rewrites the docs; the default only reports, so a stale number fails rather
    # than being silently corrected.
    if ($Rest -and $Rest[0] -eq 'update') {
        Invoke-ChildScript $script @('-Update')
    } else {
        Invoke-ChildScript $script @('-Check')
    }
}

function Invoke-TestInstallers {
    Invoke-ChildScript (Join-Path $repo 'scripts\test-installers.ps1')
}

function Invoke-TestWorkflows {
    Invoke-ChildScript (Join-Path $repo 'scripts\test-workflows.ps1')
}

function Invoke-ReleaseRehearsal {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\release-rehearsal.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "scripts\release-rehearsal.ps1 is missing"
    }

    # The version is a tag-shaped argument because that is what a real release injects. Anything after
    # it is forwarded as-is: Invoke-ChildScript starts a new powershell process, so flags keep their
    # meaning instead of being bound by this parameter block.
    $arguments = @('-Version', 'v0.0.0-rehearsal')
    if ($Rest -and $Rest.Count -ge 1) {
        $arguments = @('-Version', $Rest[0])
        if ($Rest.Count -gt 1) { $arguments += $Rest[1..($Rest.Count - 1)] }
    }

    Invoke-ChildScript $script $arguments
}

# The rehearsal's own test. It lives in the normal task list rather than in check because it builds
# six binaries: cheap enough to run on purpose, too slow to run on every edit.
function Invoke-ReleaseTest {
    Need-Toolchains
    Invoke-ChildScript (Join-Path $repo 'scripts\release-test.ps1')
}

function Invoke-E2E {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\e2e.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "scripts\e2e.ps1 is missing"
    }
    Invoke-ChildScript $script
}

function Invoke-Proof {
    Need-Toolchains
    $script = Join-Path $repo 'scripts\proofs.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "scripts\proofs.ps1 does not exist yet: the behavioural proofs are built in M2 and M5."
    }
    Invoke-ChildScript $script
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
    'e2e'   { Invoke-E2E }
    'release-rehearsal' { Invoke-ReleaseRehearsal }
    'release-test'      { Invoke-ReleaseTest }
    'test-installers' { Invoke-TestInstallers }
    'test-workflows' { Invoke-TestWorkflows }
    'measure-sizes' { Invoke-MeasureSizes }
    'test-readme' { Invoke-TestReadme }
    'demo-gif' { Invoke-DemoGif }
    'dashboard-image' { Invoke-DashboardImage }
    default {
        @'
handmedown tasks

  scripts\tasks.ps1 check     format check, vet, compile, test - both halves
  scripts\tasks.ps1 fmt       format both halves in place
  scripts\tasks.ps1 build     hand.exe + brain release
  scripts\tasks.ps1 agent ..  run the agent from source (args are passed through)
  scripts\tasks.ps1 brain     run the brain in dev
  scripts\tasks.ps1 proof     local proof: hard-kill and resume a run
  scripts\tasks.ps1 e2e       end-to-end: brain, agent, lease, completion, brain crash
  scripts\tasks.ps1 release-rehearsal [vX.Y.Z]   build + verify the six release artefacts offline
  scripts\tasks.ps1 release-test      test that rehearsal: names, formats, checksums, corruption
  scripts\tasks.ps1 test-installers   both installers, against a stubbed release over loopback
  scripts\tasks.ps1 test-workflows    the release/CI workflows match the artefact contract
  scripts\tasks.ps1 measure-sizes [update]   the sizes quoted in the docs, measured from a real build
  scripts\tasks.ps1 test-readme     every command and link in the README is real
  scripts\tasks.ps1 demo-gif        regenerate docs/demo.gif from a real `hand demo`
  scripts\tasks.ps1 dashboard-image regenerate docs/dashboard.png from a real brain

Toolchains: _bootstrap\env.ps1 is loaded automatically when go/mix are not on PATH.
'@ | Write-Host
    }
}
