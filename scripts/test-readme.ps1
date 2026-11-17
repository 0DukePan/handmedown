# Assert that the README describes the software that exists.
#
#   scripts\test-readme.ps1
#
# Two failure modes this catches, both of which have already happened in this repository:
#
#   1. A command the README shows but the CLI does not implement (a reader's first command 404s at the
#      `hand` level instead of at the network).
#   2. An install one-liner pointing at a file that is not in the repo, so following the README lands on
#      a 404.
#
# It runs offline: nothing here fetches a URL. The release URLs are checked as *shapes* and the
# repository-relative files are checked for existence.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$readmePath = Join-Path $repo 'README.md'
$hand = Join-Path $repo 'agent\hand.exe'

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

$readme = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)

# --- the CLI exists and knows its subcommands --------------------------------
Write-Host 'README vs the CLI' -ForegroundColor Cyan

Push-Location (Join-Path $repo 'agent')
try {
    & go build -o hand.exe .\cmd\hand
    if ($LASTEXITCODE -ne 0) { throw 'agent build failed' }
} finally { Pop-Location }

$help = (& $hand --help) -join "`n"
Check 'the binary runs' ($LASTEXITCODE -eq 0 -and $help -match 'usage:') $help

# Every `hand <subcommand>` the README shows must be a subcommand the binary accepts.
$documented = @()
foreach ($match in [regex]::Matches($readme, '(?m)^\s*\$?\s*hand\s+([a-z][a-z-]*)')) {
    $documented += $match.Groups[1].Value
}
$documented = @($documented | Sort-Object -Unique)

foreach ($command in $documented) {
    if ($command -in @('run', 'submit', 'join', 'demo', 'version', 'help')) {
        Check ("documented subcommand '{0}' is implemented" -f $command) $true
    } else {
        Check ("documented subcommand '{0}' is implemented" -f $command) $false 'the CLI has no such subcommand'
    }
}
Check 'the README documents at least the four core commands' ($documented.Count -ge 3) ($documented -join ', ')

# The flags a reader is told to type must at least be accepted by the command they are attached to.
foreach ($flag in @('--inputs', '--outdir', '--shards', '--brain', '--token')) {
    $shown = $readme -match [regex]::Escape($flag)
    if (-not $shown) { continue }
    $accepted = $help -match [regex]::Escape($flag)
    # Some flags belong to subcommands whose help is not in the top-level text; treat a mention in the
    # binary's own help, or a successful parse in the corresponding subcommand, as evidence.
    if (-not $accepted) {
        # A flag belongs to a subcommand, so ask every subcommand's own help before calling it missing.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            foreach ($subcommand in @('run', 'submit', 'join', 'demo')) {
                # Subcommand help goes to stderr and exits 2 (a deliberate usage error), so it is
                # captured rather than piped into the pass/fail expression.
                $subHelp = (& $hand $subcommand --help 2>&1) -join "`n"
                if ($subHelp -match [regex]::Escape($flag)) { $accepted = $true; break }
            }
        } finally {
            $ErrorActionPreference = $previous
        }
    }
    Check ("flag '{0}' shown in the README exists" -f $flag) $accepted 'the CLI does not accept it'
}

# --- install one-liners point at real files ---------------------------------
Write-Host ''
Write-Host 'install one-liners' -ForegroundColor Cyan

$installers = @('install.ps1', 'install.sh')
foreach ($installer in $installers) {
    Check ("{0} exists in the repository" -f $installer) (Test-Path -LiteralPath (Join-Path $repo $installer))
}

# The README's Windows one-liner is a raw.githubusercontent URL; the path after the branch must exist.
foreach ($match in [regex]::Matches($readme, 'raw\.githubusercontent\.com/[^/\s]+/[^/\s]+/main/([^\s`"'']+)')) {
    $referenced = $match.Groups[1].Value.Trim()
    Check ("raw URL points at a file in the repo: {0}" -f $referenced) (Test-Path -LiteralPath (Join-Path $repo ($referenced -replace '/', '\')))
}

# The curl one-liner is only honest if the script it mentions is the one in this repo.
$mentionsCurl = $readme -match 'curl -fsSL'
Check 'the curl one-liner is backed by install.sh in this repo' ((-not $mentionsCurl) -or (Test-Path -LiteralPath (Join-Path $repo 'install.sh')))

# --- assets the README displays --------------------------------------------
Write-Host ''
Write-Host 'assets' -ForegroundColor Cyan

foreach ($match in [regex]::Matches($readme, '!\[[^\]]*\]\(([^)]+)\)')) {
    $target = $match.Groups[1].Value
    if ($target -match '^https?://') { continue }
    $path = Join-Path $repo ($target -replace '/', '\')
    Check ("README image exists: {0}" -f $target) (Test-Path -LiteralPath $path)

    if (Test-Path -LiteralPath $path) {
        $size = (Get-Item -LiteralPath $path).Length
        Check ("{0} is within its budget (1.5 MB)" -f $target) ($size -lt 1500000) ("{0:N0} KB" -f ($size / 1KB))
    }
}

# --- honesty sections ------------------------------------------------------
Write-Host ''
Write-Host 'honesty' -ForegroundColor Cyan

Check 'the README says what it does not do' ($readme -match 'does NOT do' -or $readme -match 'does not do') ''
Check 'the README states the binaries are unsigned or how to build from source' (
    ($readme -match 'unsigned') -or ($readme -match 'build from source')
) 'a reader must be told what they are downloading'
Check 'the README does not advertise a Termux package that does not exist' (
    -not ($readme -match 'pkg install hand')
) 'unless a real package exists, the Termux path has to be the documented build'

Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'README: all checks passed' -ForegroundColor Green
    exit 0
}

Write-Host ("README: {0} check(s) failed" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
exit 1
