# MANAGED FILE - do not edit in your fork.
#
# Builds terraform-provider-<name> (name from provider/settings.tfps.json) for this
# machine and stages the pshost sidecar next to it, producing a directory you
# can point dev_overrides (or the E2E harness) at:
#
#   ./.template/build/Build-Provider.ps1  -> dist/local/terraform-provider-<name>[.exe] + pshost[.exe]
#
# Sidecar staging order: $env:PSHOST_PATH if set (local engine development),
# otherwise downloaded from the engine release matching go.mod.
#Requires -Version 7
[CmdletBinding()]
param(
    [string]$OutputDir = 'dist/local',
    # Version stamped into the binary (release builds use the semantic-release version).
    [string]$Version = '0.1-dev',
    # Skip Update-Engine.ps1 (e.g. when CI already ran it).
    [switch]$SkipEngineResolve,
    # Skip sidecar staging (e.g. when only compiling).
    [switch]$SkipSidecar
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $SkipEngineResolve) {
    & (Join-Path $PSScriptRoot 'Update-Engine.ps1')
}

$settings = Get-Content (Join-Path $repoRoot 'provider/settings.tfps.json') -Raw | ConvertFrom-Json
$name = $settings.name
if (-not $name) { throw 'provider/settings.tfps.json has no "name"' }

$exe = if ($IsWindows) { '.exe' } else { '' }
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $repoRoot $OutputDir
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$binaryPath = Join-Path $OutputDir "terraform-provider-$name$exe"

Push-Location $repoRoot
try {
    Write-Host "[build] go build -> $binaryPath"
    go build -trimpath -ldflags "-s -w -X main.version=$Version" -o $binaryPath .
    if ($LASTEXITCODE -ne 0) { throw "go build failed (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

if (-not $SkipSidecar) {
    $sidecarName = "pshost$exe"
    $target = Join-Path $OutputDir $sidecarName
    if ($env:PSHOST_PATH) {
        if (-not (Test-Path -LiteralPath $env:PSHOST_PATH)) {
            throw "PSHOST_PATH is set but does not exist: $env:PSHOST_PATH"
        }
        # Copy the whole sidecar directory: RID-specific dotnet builds need
        # their sibling runtime files, and single-file publishes are just one
        # file so the copy stays cheap either way.
        $srcDir = Split-Path -Parent $env:PSHOST_PATH
        Write-Host "[build] staging sidecar from PSHOST_PATH ($srcDir)"
        Copy-Item -Path (Join-Path $srcDir '*') -Destination $OutputDir -Recurse -Force
    }
    elseif (-not (Test-Path -LiteralPath $target)) {
        & (Join-Path $PSScriptRoot 'Get-EngineSidecars.ps1') -CurrentPlatform -Destination (Join-Path $OutputDir 'sidecar-stage')
        $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
        $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
            'Arm64' { 'arm64' }
            default { 'amd64' }
        }
        Copy-Item -LiteralPath (Join-Path $OutputDir 'sidecar-stage' "$os-$arch" $sidecarName) -Destination $target -Force
        Remove-Item -Recurse -Force (Join-Path $OutputDir 'sidecar-stage')
    }
    else {
        Write-Host "[build] sidecar already staged at $target"
    }
}

Write-Host "[build] done: $OutputDir"
