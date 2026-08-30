# MANAGED FILE - do not edit in your fork.
#
# File-level template sync: copies the managed file set from a checkout of
# the template repo over THIS repo's working tree and stages the result with
# git. Works for repos created with "Use this template" (no shared git
# history required) as well as real forks.
#
# The caller (.github/workflows/template-sync.yml) is responsible for
# branching, committing, and opening the PR. Run from the repo root:
#
#   ./.template/scripts/Sync-FromTemplate.ps1 -TemplateRoot ../template
#
# The workflow always runs the TEMPLATE's copy of this script, so the sync
# logic (including the managed-file list below) is the template's latest,
# not the possibly-stale copy in the repo being synced.
#Requires -Version 7
[CmdletBinding()]
param(
    # Root of a checkout of the template repo to sync from.
    [Parameter(Mandatory)][string]$TemplateRoot,
    # Also mirror .github/workflows/**. Requires the caller to push with a
    # token that has the workflow scope - the default GITHUB_TOKEN cannot
    # push workflow-file changes, so the workflow only passes this when a
    # TEMPLATE_SYNC_TOKEN secret is configured.
    [switch]$IncludeWorkflows
)

$ErrorActionPreference = 'Stop'
$TemplateRoot = (Resolve-Path -LiteralPath $TemplateRoot).Path

# The managed set: .template/** and .github/workflows/** mirrored exactly
# (deletions included), plus these path-constrained root files. Keep this
# list in step with the ownership table in README.md.
$managedRootFiles = @(
    'main.go'
    'main_test.go'
    'go.mod'
    '.releaserc.cjs'
    '.gitignore'
    'LICENSE'
    'README.md'
    'SETUP.md'
    'CLAUDE.md'
    'docs/guides/writing-resources.md'
)

function Sync-ManagedDir {
    # Mirror one directory at the git level: un-track everything (so files
    # the template deleted disappear), copy the template's tree in, re-add.
    # Untracked local files (e.g. the gitignored harness .bin) are untouched.
    param([string]$RelPath)
    git rm -r -q --ignore-unmatch -- $RelPath
    if ($LASTEXITCODE -ne 0) { throw "git rm $RelPath failed" }
    $src = Join-Path $TemplateRoot $RelPath
    if (Test-Path -LiteralPath $src) {
        $parent = Split-Path -Parent $RelPath
        $dest = if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null; $parent } else { '.' }
        Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
    }
    git add -A -- $RelPath
    if ($LASTEXITCODE -ne 0) { throw "git add $RelPath failed" }
}

Sync-ManagedDir '.template'
if ($IncludeWorkflows) {
    Sync-ManagedDir '.github/workflows'
}

foreach ($f in $managedRootFiles) {
    $src = Join-Path $TemplateRoot $f
    if (Test-Path -LiteralPath $src) {
        $parent = Split-Path -Parent $f
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $src -Destination $f -Force
        git add -- $f
    }
    else {
        # The template deleted a managed root file - mirror that too.
        git rm -q --ignore-unmatch -- $f
    }
    if ($LASTEXITCODE -ne 0) { throw "staging $f failed" }
}

# Report workflow drift the caller could not sync (no PAT), so the PR body
# can tell the user to update those files by hand.
if (-not $IncludeWorkflows) {
    $drift = @(
        Get-ChildItem (Join-Path $TemplateRoot '.github/workflows') -File | ForEach-Object {
            $local = Join-Path '.github/workflows' $_.Name
            if (-not (Test-Path -LiteralPath $local) -or
                (Get-FileHash -LiteralPath $local).Hash -ne (Get-FileHash -LiteralPath $_.FullName).Hash) {
                $_.Name
            }
        }
    )
    if ($drift) {
        Write-Host "workflow-drift: $($drift -join ', ')"
    }
}

Write-Host '[template-sync] staged changes:'
git status --porcelain
