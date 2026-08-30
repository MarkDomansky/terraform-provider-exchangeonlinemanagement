# MANAGED FILE - do not edit in your fork.
#
# Scaffolds a new resource or data source:
#
#   ./.template/build/New-Resource.ps1 -Name mailbox              -> provider/resources/mailbox/
#   ./.template/build/New-Resource.ps1 -Name mailbox -DataSource  -> provider/data-sources/mailbox/
#
# Creates the manifest (resource.tfps.json / datasource.tfps.json), the CRUD
# script stubs, a Pester unit-test stub, and a registry docs page stub. Edit the
# manifest first; the stubs reference the attributes you declare there.
#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9_]*$')]
    [string]$Name,
    [switch]$DataSource
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$settings = Get-Content (Join-Path $repoRoot 'provider/settings.tfps.json') -Raw | ConvertFrom-Json
$providerName = $settings.name

$kindDir = if ($DataSource) { 'data-sources' } else { 'resources' }
$dir = Join-Path $repoRoot 'provider' $kindDir $Name
if (Test-Path -LiteralPath $dir) { throw "$dir already exists" }
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'tests') | Out-Null

$manifestName = if ($DataSource) { 'datasource.tfps.json' } else { 'resource.tfps.json' }
$schema = if ($DataSource) {
    @'
{
  "$schema": "https://json.schemastore.org/tfpowershell-datasource.json",
  "version": 1,
  "description": "TODO: describe what this data source reads.",
  "attributes": {
    "name": {
      "type": "string",
      "required": true,
      "description": "TODO: lookup key."
    },
    "example_output": {
      "type": "string",
      "computed": true,
      "description": "TODO: value returned by read.ps1."
    }
  }
}
'@
}
else {
    @'
{
  "$schema": "https://json.schemastore.org/tfpowershell-resource.json",
  "version": 1,
  "description": "TODO: describe what this resource manages.",
  "attributes": {
    "name": {
      "type": "string",
      "required": true,
      "requires_replace": true,
      "description": "TODO: identity attribute; changing it replaces the object."
    },
    "example_setting": {
      "type": "string",
      "optional": true,
      "description": "TODO: a mutable setting; changing it runs update.ps1."
    },
    "example_output": {
      "type": "string",
      "computed": true,
      "description": "TODO: server-assigned value emitted by the scripts."
    }
  }
}
'@
}
Set-Content -LiteralPath (Join-Path $dir $manifestName) -Value $schema

$contract = @'
# Contract: the engine binds $InputData BY NAME and supplies no other argument,
# so any extra parameter you declare must be optional. $Action ('create',
# 'read', ...) arrives as an enclosing-scope variable - declaring it as a
# parameter shadows it with $null. Emit EXACTLY ONE object; error-stream output
# fails the operation; pipe unwanted cmdlet output to Out-Null.
#
# Validate in the param block only what the manifest cannot already guarantee:
# required attributes, types and `one_of` validators are enforced by Terraform
# before the script runs.
'@

# param block for scripts that receive config attributes only.
$paramConfigOnly = @'
[CmdletBinding()]
param(
    # Every non-null config attribute from the manifest, naturally typed
    # (numbers, bools, arrays, hashtables; `json` attributes arrive decoded),
    # plus any `default` it declares.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$InputData
)
'@

# param block for read/update/delete, which additionally get the engine-injected
# 'id'. __SCRIPT__ is replaced with the file name so the failure names itself.
$paramWithIdTemplate = @'
[CmdletBinding()]
param(
    # The config attributes from state, plus 'id' - the value create.ps1
    # emitted, or the argument to `terraform import`.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = '__SCRIPT__ requires a non-empty $InputData.id; the engine injects it from state.')]
    [hashtable]$InputData
)
'@
function New-IdParamBlock([string]$ScriptName) { $paramWithIdTemplate.Replace('__SCRIPT__', $ScriptName) }

if ($DataSource) {
    Set-Content -LiteralPath (Join-Path $dir 'read.ps1') -Value @"
# read.ps1 - the only script a data source has. A data source carries no state,
# so there is no 'id' in `$InputData.
$contract
$paramConfigOnly
# TODO: look the object up and emit its computed attributes.
@{
    example_output = "TODO: value for `$(`$InputData.name)"
}
"@
}
else {
    Set-Content -LiteralPath (Join-Path $dir 'create.ps1') -Value @"
# create.ps1 - must emit a non-empty unique 'id'. No 'id' in `$InputData yet:
# create is what mints it.
$contract
$paramConfigOnly
# TODO: create the object.
@{
    id             = `$InputData.name
    example_output = 'TODO'
}
"@
    Set-Content -LiteralPath (Join-Path $dir 'read.ps1') -Value @"
# read.ps1 - emit NOTHING if the object is gone (Terraform plans recreation).
$contract
$(New-IdParamBlock 'read.ps1')
# TODO: look the object up by `$InputData.id.
# if (-not `$found) { return }
@{
    id             = `$InputData.id
    example_output = 'TODO'
}
"@
    Set-Content -LiteralPath (Join-Path $dir 'update.ps1') -Value @"
# update.ps1 - DELETE THIS FILE if every config change should replace the
# object instead; its presence alone enables in-place updates.
$contract
$(New-IdParamBlock 'update.ps1')
# TODO: apply the planned config in `$InputData to the object `$InputData.id.
@{
    id             = `$InputData.id
    example_output = 'TODO'
}
"@
    Set-Content -LiteralPath (Join-Path $dir 'delete.ps1') -Value @"
# delete.ps1 - keep destroy idempotent: deleting an already-missing object
# should succeed.
$contract
$(New-IdParamBlock 'delete.ps1')
# TODO: delete the object `$InputData.id.
@{ id = `$InputData.id }
"@
}

# Pester unit-test stub wired to the managed ScriptUnit harness.
$actionsLine = if ($DataSource) { "'read'" } else { "'create', 'read', 'update', 'delete'" }
Set-Content -LiteralPath (Join-Path $dir 'tests' "$Name.Tests.ps1") -Value @"
# Script-level unit tests for the '$Name' $(if ($DataSource) { 'data source' } else { 'resource' }).
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1   (or Invoke-Pester on this file)
BeforeAll {
    Import-Module (Join-Path `$PSScriptRoot '..' '..' '..' '..' '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force
    `$script:Kind = '$kindDir'
    `$script:Name = '$Name'
}

Describe '$Name scripts' {
    It 'declares a valid schema' {
        Get-ResourceManifest -Kind `$script:Kind -Name `$script:Name | Should -Not -BeNullOrEmpty
    }

    # TODO: real tests. Mock external cmdlets, invoke one script, assert on
    # the single emitted object. Example shape:
    #
    # It 'creates and emits an id' {
    #     `$result = Invoke-ResourceScript -Kind `$script:Kind -Name `$script:Name -Action create -InputData @{
    #         name = 'unit-test'
    #     }
    #     `$result.id | Should -Not -BeNullOrEmpty
    # }
    It 'has scripts for every action' -ForEach @($actionsLine) {
        Get-ResourceScriptPath -Kind `$script:Kind -Name `$script:Name -Action `$_ | Should -Exist
    }
}
"@

# Registry docs stub.
$docsDir = Join-Path $repoRoot 'docs' $kindDir
New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
$docKind = if ($DataSource) { 'Data Source' } else { 'Resource' }
Set-Content -LiteralPath (Join-Path $docsDir "$Name.md") -Value @"
---
page_title: "${providerName}_$Name $docKind"
description: |-
  TODO: one-line description.
---

# ${providerName}_$Name ($docKind)

TODO: describe it.

## Example Usage

``````terraform
$(if ($DataSource) { "data" } else { "resource" }) "${providerName}_$Name" "example" {
  name = "example"
}
``````

## Schema

Document each attribute you declared in $manifestName here (the registry renders
this page for the provider docs).
"@

Write-Host "[new-resource] scaffolded $dir"
Write-Host "[new-resource] next: edit $manifestName, fill in the scripts, write the tests, complete the docs page."
