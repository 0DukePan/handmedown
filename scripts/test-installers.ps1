# Installer tests: both installers, against a stubbed release served over loopback.
#
#   scripts\test-installers.ps1
#
# Nothing here touches the internet: Python's http.server serves a fixture release directory on an
# ephemeral port, and both installers are pointed at it with HAND_BASE_URL. The tests assert the
# behaviour a user depends on - a verified install, a refusal on mismatch, a readable failure when the
# release is unreachable - and nothing about how the scripts are written.
#
# Both installers are invoked as a *separate process*, the way a user runs them. That is not incidental:
# PowerShell does not set $LASTEXITCODE for a script called with &, and Write-Host writes to the
# information stream rather than stdout, so an in-process call cannot observe either the exit code or
# the output without contortions. A child process observes both honestly.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$agent = Join-Path $repo 'agent'
function Find-Python {
    # Discovered, not hard-coded: a fixed interpreter path makes this suite pass on exactly one machine.
    foreach ($candidate in @('python', 'python3', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Find-Bash {
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $command = Get-Command bash -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

$python = Find-Python
$bash = Find-Bash
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not $python) {
    throw 'no Python interpreter found: the installer tests need one to serve the stubbed release. Install Python, or test the installers by hand against a real release.'
}

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    $envPs1 = Join-Path (Split-Path -Parent $repo) '_bootstrap\env.ps1'
    if (Test-Path -LiteralPath $envPs1) { . $envPs1 | Out-Null }
}

$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " -> $Detail" } else { '' })) -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

# Runs install.ps1 the way a user would, and returns both the exit code and everything it printed.
#
# ErrorActionPreference is relaxed for the duration: in PowerShell 5.1, with 'Stop', anything a native
# command writes to stderr becomes a terminating NativeCommandError. An installer that correctly refuses
# a bad checksum writes to stderr, and that refusal is the expected result here, not a crash in the test.
function Invoke-PsInstaller {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Output = $output }
    } finally {
        $ErrorActionPreference = $previous
    }
}

# --- fixture release ----------------------------------------------------------
Write-Host 'building fixture release' -ForegroundColor Cyan
$work = Join-Path $env:TEMP ('hand-installers-' + [guid]::NewGuid().ToString('n'))
$dist = Join-Path $work 'release'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$ldflags = '-s -w -X github.com/0DukePan/handmedown/agent/internal/version.Version=v9.9.9-test'

Push-Location $agent
try {
    & go build -trimpath -ldflags $ldflags -o (Join-Path $dist 'hand_windows_amd64.exe') .\cmd\hand
    if ($LASTEXITCODE -ne 0) { throw 'fixture build (windows) failed' }

    $previousGoos = $env:GOOS; $previousGoarch = $env:GOARCH
    $env:GOOS = 'linux'; $env:GOARCH = 'arm64'; $env:CGO_ENABLED = '0'
    & go build -trimpath -ldflags $ldflags -o (Join-Path $dist 'hand_linux_arm64') .\cmd\hand
    $env:GOOS = $previousGoos; $env:GOARCH = $previousGoarch; $env:CGO_ENABLED = ''
    if ($LASTEXITCODE -ne 0) { throw 'fixture build (linux/arm64) failed' }
} finally { Pop-Location }

function Write-Sums([string]$Directory, [hashtable]$Hashes) {
    $lines = foreach ($name in ($Hashes.Keys | Sort-Object)) { "$($Hashes[$name])  $name" }
    [System.IO.File]::WriteAllText((Join-Path $Directory 'SHA256SUMS.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

$assets = @('hand_windows_amd64.exe', 'hand_linux_arm64')
$goodHashes = @{}
foreach ($asset in $assets) { $goodHashes[$asset] = (Get-FileHash -LiteralPath (Join-Path $dist $asset) -Algorithm SHA256).Hash.ToLower() }
Write-Sums $dist $goodHashes

# A release whose checksums are all wrong, but which is otherwise well formed: the installer must still
# refuse, and must not fall back to "no checksum found, carry on".
$mismatchDir = Join-Path $work 'release-mismatch'
New-Item -ItemType Directory -Force -Path $mismatchDir | Out-Null
$badHashes = @{}
foreach ($asset in $assets) {
    Copy-Item -LiteralPath (Join-Path $dist $asset) -Destination (Join-Path $mismatchDir $asset)
    $badHashes[$asset] = ('0' * 64)
}
Write-Sums $mismatchDir $badHashes

$port = Get-FreePort
$server = Start-Process -FilePath $python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $work `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'server.out') -RedirectStandardError (Join-Path $work 'server.err')

$baseUrl = "http://127.0.0.1:$port/release"
$mismatchUrl = "http://127.0.0.1:$port/release-mismatch"

# The installers read these from the environment, so set them once, restore afterwards.
$saved = @{
    HAND_BASE_URL = $env:HAND_BASE_URL; HAND_INSTALL_DIR = $env:HAND_INSTALL_DIR
    HAND_NO_PATH = $env:HAND_NO_PATH; HAND_USER_PATH = $env:HAND_USER_PATH; HAND_TARGET = $env:HAND_TARGET
}
$env:HAND_NO_PATH = '1'

try {
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            if ((Invoke-WebRequest -Uri "$baseUrl/SHA256SUMS.txt" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw "fixture server did not start on $baseUrl" }

    # ---------------- install.ps1 ----------------
    Write-Host ''
    Write-Host 'install.ps1' -ForegroundColor Cyan

    $psInstallDir = Join-Path $work 'ps-install'
    $env:HAND_BASE_URL = $baseUrl
    $env:HAND_INSTALL_DIR = $psInstallDir

    $result = Invoke-PsInstaller
    Check 'installs and exits zero' ($result.Code -eq 0) "exit=$($result.Code) $($result.Output.Trim())"
    $installedExe = Join-Path $psInstallDir 'hand.exe'
    Check 'the installed file exists' (Test-Path -LiteralPath $installedExe)

    if (Test-Path -LiteralPath $installedExe) {
        $reported = (& $installedExe version) -join ' '
        Check 'the installed binary runs and reports the release version' ($reported -match 'v9\.9\.9-test') $reported
    }

    $result = Invoke-PsInstaller
    $count = @(Get-ChildItem -LiteralPath $psInstallDir -File).Count
    Check 're-installing is idempotent' (($result.Code -eq 0) -and ($count -eq 1)) "exit=$($result.Code) files=$count"

    $env:HAND_BASE_URL = $mismatchUrl
    $badDir = Join-Path $work 'ps-bad'
    $env:HAND_INSTALL_DIR = $badDir
    $result = Invoke-PsInstaller
    Check 'a checksum mismatch is refused' ($result.Code -ne 0) "exit=$($result.Code)"
    Check 'the mismatch message names the problem' ($result.Output -match 'checksum mismatch') $result.Output.Trim()
    Check 'nothing is installed on mismatch' (-not (Test-Path -LiteralPath (Join-Path $badDir 'hand.exe')))

    $env:HAND_BASE_URL = "http://127.0.0.1:$port/nowhere"
    $env:HAND_INSTALL_DIR = (Join-Path $work 'ps-unreachable')
    $result = Invoke-PsInstaller
    Check 'an unreachable release fails with a readable message' (($result.Code -ne 0) -and ($result.Output -match 'could not download')) $result.Output.Trim()

    # PATH behaviour, driven through the test hook so a test run cannot modify the real user environment.
    $env:HAND_BASE_URL = $baseUrl
    $env:HAND_INSTALL_DIR = $psInstallDir
    $env:HAND_NO_PATH = ''

    $env:HAND_USER_PATH = 'C:\existing'
    $result = Invoke-PsInstaller
    Check 'a missing PATH entry is added' ($result.Output -match 'would set to') $result.Output.Trim()

    $env:HAND_USER_PATH = "C:\existing;$psInstallDir"
    $result = Invoke-PsInstaller
    Check 'an existing PATH entry is not duplicated' (($result.Output -match 'already contains') -and -not ($result.Output -match 'would set to')) $result.Output.Trim()

    # ---------------- install.sh ----------------
    Write-Host ''
    Write-Host 'install.sh' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $bash)) {
        Write-Host '  SKIP  install.sh tests (git bash not found)' -ForegroundColor Yellow
    } else {
        $env:HAND_NO_PATH = ''
        $env:HAND_USER_PATH = ''

        $posixWork = & $bash -c "cygpath -u '$($work -replace '\\','/')'"
        $posixWork = $posixWork.Trim()
        $posixScript = & $bash -c "cygpath -u '$((Join-Path $repo 'install.sh') -replace '\\','/')'"
        $posixScript = $posixScript.Trim()
        $shInstallDir = "$posixWork/sh-install"

        # A shim set that runs the script with a clean environment for the variables under test.
        # Same relaxation as above: a refusal is a non-zero exit with a message on stderr, which is the
        # behaviour under test, not a failure of the harness.
        $runSh = {
            param($Url)
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $bash -c "HAND_BASE_URL='$Url' HAND_INSTALL_DIR='$shInstallDir' HAND_TARGET='linux/arm64' sh '$posixScript'" 2>&1 | Out-String
            } finally {
                $ErrorActionPreference = $previous
            }
        }

        $output = & $runSh $baseUrl
        Check 'install.sh installs the matching artefact' ($LASTEXITCODE -eq 0) $output.Trim()
        $shBinary = Join-Path $work 'sh-install\hand'
        Check 'install.sh created the binary' (Test-Path -LiteralPath $shBinary) $output.Trim()

        if (Test-Path -LiteralPath $shBinary) {
            $installedHash = (Get-FileHash -LiteralPath $shBinary -Algorithm SHA256).Hash.ToLower()
            Check 'install.sh installed bytes identical to the published artefact' ($installedHash -eq $goodHashes['hand_linux_arm64'])
        }

        $output = & $runSh $mismatchUrl
        Check 'install.sh refuses a checksum mismatch' ($LASTEXITCODE -ne 0) $output.Trim()
        Check 'install.sh mismatch message names the problem' ($output -match 'checksum mismatch') $output.Trim()

        $output = & $runSh "http://127.0.0.1:$port/nowhere"
        Check 'install.sh reports an unreachable release' (($LASTEXITCODE -ne 0) -and ($output -match 'could not download')) $output.Trim()
    }
} finally {
    foreach ($key in $saved.Keys) { Set-Item -Path "env:$key" -Value $saved[$key] -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'INSTALLERS: all checks passed' -ForegroundColor Green
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    exit 0
}

Write-Host ("INSTALLERS: {0} check(s) failed" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
Write-Host "  work directory: $work" -ForegroundColor DarkGray
exit 1
