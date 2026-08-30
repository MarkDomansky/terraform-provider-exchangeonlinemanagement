# read.ps1 - the only script a data source has.
#
# Emit one object whose keys populate the computed attributes; omitted keys
# become null. Unlike a resource read, emitting nothing is not "gone" - it just
# leaves every computed attribute null - so emit an explicit marker like
# 'exists' when absence matters.
#
# A data source read runs under the same contract as a resource CRUD script
# (see provider/resources/example_file/create.ps1), with one difference: there
# is no 'id' in $InputData, because a data source has no state to carry one.
[CmdletBinding()]
param(
    # The config attributes from datasource.tfps.json:
    #   path [string] required
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$InputData
)

$path = $InputData.path
if (-not [System.IO.Path]::IsPathRooted($path) -and $global:YourProviderState.default_directory) {
    $path = Join-Path $global:YourProviderState.default_directory $path
}

if (-not (Test-Path -LiteralPath $path)) {
    @{ exists = $false }
    return
}

$file = Get-Item -LiteralPath $path
@{
    exists  = $true
    content = (Get-Content -LiteralPath $path -Raw)
    size    = [int]$file.Length
}
