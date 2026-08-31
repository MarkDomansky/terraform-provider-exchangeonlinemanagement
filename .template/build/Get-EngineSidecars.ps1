# MANAGED FILE - do not edit in your fork.
#
# Downloads the pshost sidecar binaries for the engine version pinned in
# go.mod, by pulling the engine's own release zips from GitHub and extracting
# just pshost(.exe). The sidecars are staged the way goreleaser.yml expects:
#
#   dist-pshost/<os>-<arch>/pshost[.exe]
#
# Release packaging downloads all six platforms; local builds pass
# -CurrentPlatform to fetch only the one this machine needs.
#Requires -Version 7
[CmdletBinding()]
param(
    # Engine version (no leading v). Default: read from go.mod via go list -m.
    [string]$Version,
    # Only fetch the sidecar for this machine's OS/arch.
    [switch]$CurrentPlatform,
    # Staging root. Created if missing.
    [string]$Destination = 'dist-pshost'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engineModule = 'github.com/markdomansky/terraform-provider-powershell'
$engineRepo = 'markdomansky/terraform-provider-powershell'

if (-not $Version) {
    Push-Location $repoRoot
    try {
        $Version = [string](go list -m -f '{{.Version}}' $engineModule)
        if ($LASTEXITCODE -ne 0) { throw "go list -m $engineModule failed" }
    }
    finally { Pop-Location }
    if (-not $Version -or $Version -match 'devel') {
        # A go workspace (local engine checkout) reports no version at all.
        throw "Could not resolve the engine version from go.mod (got '$Version'). Run .template/build/Update-Engine.ps1 first, pass -Version, or - when developing against a local engine checkout - set PSHOST_PATH to a built sidecar instead of downloading one."
    }
}
$Version = $Version.TrimStart('v')

function Get-CurrentPlatformPair {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'Arm64' { 'arm64' }
        default { 'amd64' }
    }
    , @($os, $arch)
}

# The outer @() is load-bearing. Assigning the value of an if statement
# collects its output stream, which unrolls one level of array - so a single
# pair comes back as the two loose strings 'linux','amd64' and the loop below
# then reads $os='linux', $arch=$null. Wrapping INSIDE the branch does not
# help; the if statement unrolls whatever the branch emits. Only six-platform
# runs survived that, which is why release packaging never hit it.
$platforms = @(
    if ($CurrentPlatform) {
        , (Get-CurrentPlatformPair)
    }
    else {
        @('windows', 'amd64'), @('windows', 'arm64'),
        @('linux', 'amd64'), @('linux', 'arm64'),
        @('darwin', 'amd64'), @('darwin', 'arm64')
    }
)

if (-not [System.IO.Path]::IsPathRooted($Destination)) {
    $Destination = Join-Path $repoRoot $Destination
}

foreach ($pair in $platforms) {
    $os, $arch = $pair
    if (-not $os -or -not $arch) {
        # Fail here rather than requesting ..._linux_.zip and reporting a 404,
        # which reads like a missing engine release instead of a bad pair.
        throw "Malformed platform entry '$($pair -join ',')' - expected an (os, arch) pair."
    }
    $binary = if ($os -eq 'windows') { 'pshost.exe' } else { 'pshost' }
    $zipName = "terraform-provider-powershell_${Version}_${os}_${arch}.zip"
    $url = "https://github.com/$engineRepo/releases/download/v$Version/$zipName"

    $stage = Join-Path $Destination "$os-$arch"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pstf-sidecar-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zipPath = Join-Path $tmp $zipName
        Write-Host "[sidecars] downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath

        Expand-Archive -LiteralPath $zipPath -DestinationPath (Join-Path $tmp 'x')
        $src = Join-Path $tmp 'x' $binary
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Engine release zip $zipName does not contain $binary - the engine's packaging layout changed?"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage $binary) -Force
        if ($os -ne 'windows') {
            # Preserve executability when staged on a POSIX host.
            & chmod +x (Join-Path $stage $binary) 2>$null
        }
        Write-Host "[sidecars] staged $os-$arch/$binary"
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
