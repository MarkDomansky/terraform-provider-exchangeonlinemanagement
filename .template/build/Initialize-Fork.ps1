# MANAGED FILE - do not edit in your fork.
#
# One-time fork setup: writes your provider identity into
# provider/settings.tfps.json (the ONLY file that names your provider) and prints
# the remaining checklist. Run it right after forking:
#
#   ./.template/build/Initialize-Fork.ps1 -Name exchangeonline -Namespace acme
#Requires -Version 7
[CmdletBinding()]
param(
    # Provider type name: lowercase, digits, underscores (e.g. exchangeonline).
    # Becomes the prefix of every resource: <name>_<resource>.
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9_]*$')]
    [string]$Name,
    # Your Terraform Registry namespace (usually your GitHub org/user).
    [Parameter(Mandatory)]
    [string]$Namespace,
    # Repository URL; defaults to github.com/<namespace>/terraform-provider-<name>.
    [string]$Repository,
    # Engine version policy: 'latest' (default) or an exact version like 0.4.2.
    [string]$EngineVersion = 'latest'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Repository) {
    $Repository = "https://github.com/$Namespace/terraform-provider-$Name"
}

$settings = [ordered]@{
    name           = $Name
    address        = "registry.terraform.io/$Namespace/$Name"
    repository     = $Repository
    engine_version = $EngineVersion
}
$settingsPath = Join-Path $repoRoot 'provider/settings.tfps.json'
($settings | ConvertTo-Json) + "`n" | Set-Content -LiteralPath $settingsPath -NoNewline

Write-Host "[init] wrote $settingsPath"
Write-Host "[init] provider type name : $Name  (resources will be ${Name}_<resource>)"
Write-Host "[init] registry address   : registry.terraform.io/$Namespace/$Name"
Write-Host ''
Write-Host 'Next steps (full detail in SETUP.md):'
Write-Host '  1. ./.template/build/New-Resource.ps1 -Name <resource>   # scaffold each resource'
Write-Host '  2. Fill in resource.tfps.json + scripts; study provider/resources/example_file first'
Write-Host '  3. pwsh ./.template/tests/unit/Invoke-UnitTests.ps1      # fast unit tests'
Write-Host '  4. ./.template/build/Build-Provider.ps1 then Invoke-Pester ./tests/e2e  # real terraform'
Write-Host '  5. Delete the example_file sample folders (resources, data-sources, tests, docs)'
Write-Host '     and REPO-NOTES.md (the template repo''s own notes; write your own or drop it)'
Write-Host '  6. Set GPG_PRIVATE_KEY / GPG_PASSPHRASE repo secrets; create the first wiki page'
Write-Host '  7. Merge PRs to beta (squash) for prereleases; merge beta->main (real merge) for GA'
