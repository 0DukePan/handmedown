# One seam for the release contract.
#
#   . scripts\release-assets.ps1
#   $assets = Get-ReleaseAssets
#   Get-AssetName -Target $assets.agent_targets[0]     # hand_linux_amd64
#
# The manifest (release-assets.json at the repo root) is the single source of truth for artefact names,
# the checksum file name, the environment variables the installers read, and the asset size budgets.
# The rehearsal, the workflow check, the installers' tests and the README check all go through here, so
# renaming an artefact and forgetting a consumer is a failing test rather than a broken install.

param(
    # Optional: the repository root. Defaults to two levels above this file, which is where it lives.
    [string]$RepoRoot
)

Set-StrictMode -Version Latest

function Get-ReleaseManifestPath {
    param([string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))
    return (Join-Path $RepoRoot 'release-assets.json')
}

function Get-ReleaseAssets {
    param([string]$RepoRoot)

    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    $path = Join-Path $RepoRoot 'release-assets.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "release manifest not found: $path"
    }

    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

    # Normalised into the shape the rest of the scripts want, rather than making every caller know the
    # JSON field names.
    return [pscustomobject]@{
        Path          = $path
        AgentTargets  = @($manifest.agent_targets)
        AgentPattern  = $manifest.agent_pattern
        BrainPattern  = $manifest.brain_pattern
        Checksums     = $manifest.checksums
        Env           = $manifest.env
        Budgets       = $manifest.budgets
        Raw           = $manifest
    }
}

function Get-AssetName {
    param(
        [Parameter(Mandatory = $true)] $Target,
        [string]$Pattern = 'hand_{goos}_{goarch}{ext}'
    )

    $ext = ''
    if ($Target.PSObject.Properties.Name -contains 'ext' -and $Target.ext) { $ext = $Target.ext }

    return $Pattern.Replace('{goos}', $Target.goos).Replace('{goarch}', $Target.goarch).Replace('{ext}', $ext)
}

function Get-AgentAssetNames {
    param($Assets)

    foreach ($target in $Assets.AgentTargets) {
        Get-AssetName -Target $target -Pattern $Assets.AgentPattern
    }
}

# Which target matches this machine. The installers need this; so does anything that has to pick "the
# native artefact" without hard-coding a name.
function Get-HostTarget {
    param($Assets)

    $goos = 'linux'
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { $goos = 'windows' }
    elseif ($IsMacOS -or ($env:OSTYPE -and $env:OSTYPE -like 'darwin*')) { $goos = 'darwin' }

    $goarch = 'amd64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $goarch = 'arm64' }

    foreach ($target in $Assets.AgentTargets) {
        if ($target.goos -eq $goos -and $target.goarch -eq $goarch) { return $target }
    }
    return $null
}
