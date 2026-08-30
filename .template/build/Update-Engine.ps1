# MANAGED FILE - do not edit in your fork.
#
# Resolves the engine (terraform-provider-powershell) version into go.mod.
#
#   provider/settings.tfps.json "engine_version": "latest"  -> newest GA release
#                                            "0.4.2"   -> that exact version
#                                            "0.5.0-beta.3" -> exact prerelease
#
# go.mod in git is only a last-known-good baseline; CI and Build-Provider.ps1
# run this first so every build compiles against the resolved version, and
# Get-EngineSidecars.ps1 then reads the same version back from go.mod - the Go
# code and the pshost sidecar binaries can never diverge within one build.
#Requires -Version 7
[CmdletBinding()]
param(
    # Override provider/settings.tfps.json (e.g. -EngineVersion 0.4.2 or latest).
    [string]$EngineVersion
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engineModule = 'github.com/markdomansky/terraform-provider-powershell'

$settings = Get-Content (Join-Path $repoRoot 'provider/settings.tfps.json') -Raw | ConvertFrom-Json
$version = if ($EngineVersion) { $EngineVersion } elseif ($settings.engine_version) { $settings.engine_version } else { 'latest' }

if ($env:GOWORK -or (go env GOWORK)) {
    Write-Host "[update-engine] go workspace active ($(go env GOWORK)) - the workspace's engine checkout wins; not touching go.mod."
    return
}

Push-Location $repoRoot
try {
    if ($version -eq 'latest') {
        # Go's @latest never selects prereleases, so this always lands on GA.
        go get "$engineModule@latest"
    }
    else {
        $v = $version.TrimStart('v')
        go get "$engineModule@v$v"
    }
    if ($LASTEXITCODE -ne 0) { throw "go get $engineModule failed (exit $LASTEXITCODE)" }

    go mod tidy
    if ($LASTEXITCODE -ne 0) { throw "go mod tidy failed (exit $LASTEXITCODE)" }

    $resolved = go list -m -f '{{.Version}}' $engineModule
    if ($LASTEXITCODE -ne 0) { throw "go list -m $engineModule failed (exit $LASTEXITCODE)" }
    Write-Host "[update-engine] engine resolved to $resolved"
}
finally {
    Pop-Location
}
