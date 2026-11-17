# Assert that the release contract in the workflows matches the contract in the rehearsal script.
#
#   scripts\test-workflows.ps1
#
# Dependency-free on purpose: this parses the workflow files as text with tight patterns rather than
# loading YAML, so it runs identically on a developer machine and in CI without installing a parser.
# It asserts *shape*, not YAML semantics: enough to catch a dropped target, a missing checksum step, a
# version that stopped coming from the tag, or a guard that was removed.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$releasePath = Join-Path $repo '.github\workflows\release.yml'
$ciPath = Join-Path $repo '.github\workflows\ci.yml'

$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " -> $Detail" } else { '' })) -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

foreach ($path in @($releasePath, $ciPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "missing workflow: $path" }
}

$release = [System.IO.File]::ReadAllText($releasePath, [System.Text.Encoding]::UTF8)
$ci = [System.IO.File]::ReadAllText($ciPath, [System.Text.Encoding]::UTF8)

# The six targets, in the same spelling the rehearsal builds and the installers parse.
$expectedTargets = @(
    'linux/amd64'
    'linux/arm64'
    'linux/arm'
    'darwin/arm64'
    'darwin/amd64'
    'windows/amd64'
)

Write-Host 'release workflow' -ForegroundColor Cyan

$declared = @()
foreach ($match in [regex]::Matches($release, 'goos:\s*([a-z]+)\s*,\s*goarch:\s*([a-z0-9]+)')) {
    $declared += ('{0}/{1}' -f $match.Groups[1].Value, $match.Groups[2].Value)
}
$declared = @($declared | Sort-Object -Unique)
Check 'declares exactly the six artefact targets' (
    (@($declared | Sort-Object) -join ',') -eq (@($expectedTargets | Sort-Object) -join ',')
) ("declared: " + ($declared -join ', '))

Check 'names artefacts as hand_<goos>_<goarch>' (
    $release -match 'hand_\$\{GOOS\}_\$\{GOARCH\}'
) 'the asset name pattern is how the installers build their URL'

Check 'injects the version from the tag' (
    $release -match '-X\s+github\.com/\S+/internal/version\.Version=\$\{GITHUB_REF_NAME\}'
) 'the binary and the release title must not be able to disagree'

Check 'writes a checksum file' ($release -match 'SHA256SUMS\.txt') 'installers verify against this'

Check 'publishes the checksum file with the release' (
    $release -match 'gh release create' -and $release -match '\./\*'
) 'the checksum has to be an asset, not just a build artefact'

Check 'fails before publishing when an artefact is missing' (
    $release -match 'Verify every expected artefact is present' -and $release -match 'exit 1'
) 'a partial release must be impossible, not just unlikely'

Check 'the publish job depends on the verification' (
    $release -match '(?s)needs:\s*\[[^\]]*\]' -and
    $release -match 'download-artifact'
) 'the guard has to run in the job that publishes'

Check 'packages the brain as an archive' (
    $release -match 'handmedown-brain-' -and $release -match 'tar -czf'
) 'the brain is built for its host platform only'

Check 'maps the Termux path to linux/arm64' (
    $release -match 'Termux' -and $release -match 'linux/arm64'
) 'the comment that explains the missing android target must survive edits'

# The agent job has to run on the platforms the agent claims.
Write-Host ''
Write-Host 'ci workflow' -ForegroundColor Cyan

# The matrix may be written either as an inline array (`os: [a, b, c]`) or as list items; accept both
# rather than pinning the check to today's formatting.
$oses = @()
$osLine = ($ci -split "`r?`n" | Where-Object { $_ -match '^\s*os:\s*\[' } | Select-Object -First 1)
if ($osLine) {
    foreach ($match in [regex]::Matches($osLine, '(ubuntu|windows|macos)-latest')) { $oses += $match.Value }
} else {
    foreach ($match in [regex]::Matches($ci, '-\s*(ubuntu|windows|macos)-latest')) { $oses += $match.Value }
}
$oses = @($oses | Sort-Object -Unique)
Check 'tests the agent on three operating systems' ($oses.Count -eq 3) ("found: " + ($oses -join ', '))

Check 'runs the brain test suite' ($ci -match 'mix test') 'the other half needs a gate too'

Check 'compiles the brain with warnings as errors' ($ci -match 'mix compile --warnings-as-errors')

Check 'checks formatting on both halves' (($ci -match 'gofmt') -and ($ci -match 'mix format --check-formatted'))

Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'WORKFLOWS: all checks passed' -ForegroundColor Green
    exit 0
}

Write-Host ("WORKFLOWS: {0} check(s) failed" -f $script:failures.Count) -ForegroundColor Red
foreach ($failure in $script:failures) { Write-Host "  - $failure" -ForegroundColor Red }
exit 1
