# MANAGED FILE - do not edit in your fork.
#
# Discovers and runs every script-level unit test:
#   provider/resources/*/tests/*.Tests.ps1
#   provider/data-sources/*/tests/*.Tests.ps1
#   provider/scripts/tests/*.Tests.ps1        (lifecycle scripts)
#
# Usage:  pwsh ./.template/tests/unit/Invoke-UnitTests.ps1 [-CI]
#Requires -Version 7
[CmdletBinding()]
param(
    # Exit the process with Pester's exit code (for CI).
    [switch]$CI
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

$testDirs = @(
    Get-ChildItem -Path (Join-Path $repoRoot 'provider' 'resources'), (Join-Path $repoRoot 'provider' 'data-sources') `
        -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'tests' } |
        Where-Object { Test-Path $_ }

    Join-Path $repoRoot 'provider' 'scripts' 'tests' | Where-Object { Test-Path $_ }
)

if (-not $testDirs) {
    Write-Host '[unit] no provider/**/tests directories found - nothing to run.'
    if ($CI) { exit 0 }
    return
}

if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge ([version]'5.0'))) {
    throw 'Pester >= 5.0 is required: Install-Module Pester -Force -SkipPublisherCheck -MinimumVersion 5.0'
}

$cfg = New-PesterConfiguration
$cfg.Run.Path = $testDirs
$cfg.Run.Exit = [bool]$CI
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
