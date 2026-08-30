# create.ps1 - called on `terraform apply` for a new resource.
#
# Contract (applies to every CRUD script):
#   - Declare the param block below. The engine binds $InputData BY NAME
#     (-InputData), so it is the ONE parameter it ever supplies: any other
#     parameter you add must be optional and keeps its default. Never mark
#     another parameter Mandatory - nothing would bind it and the operation
#     fails with an opaque binding error.
#   - $Action ('create'/'read'/'update'/'delete') is a variable the engine sets
#     in the enclosing scope. Read it freely, but do NOT declare it as a
#     parameter: that shadows the real value with $null.
#   - Emit EXACTLY ONE object to the success stream. Pipe stray cmdlet output
#     to Out-Null. Anything on the error stream fails the operation.
#   - create.ps1 must emit an 'id' key: a non-empty string that uniquely
#     identifies the object. Terraform uses it for read/update/delete/import.
#   - Keys matching computed attributes (size, last_modified) populate state;
#     keys matching config attributes are ignored; unknown keys are ignored
#     with a warning in TF_LOG output.
#
# Validate in the param block only what the manifest cannot already guarantee.
# Required attributes, types and `one_of` validators are enforced by Terraform
# from example_file.tfps.json before the script runs - re-checking them here is
# noise. What the manifest does not cover is the engine-injected 'id', so
# read/update/delete assert on it.
[CmdletBinding()]
param(
    # Every non-null config attribute from example_file.tfps.json, naturally
    # typed (numbers, bools, arrays, hashtables; `json` attributes arrive
    # decoded), plus any `default` the manifest declares:
    #   path    [string] required, requires_replace
    #   content [string] optional, default ""
    # No 'id' key yet - create is what mints it.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$InputData
)

$path = $InputData.path
if (-not [System.IO.Path]::IsPathRooted($path) -and $global:YourProviderState.default_directory) {
    $path = Join-Path $global:YourProviderState.default_directory $path
}

$dir = Split-Path -Parent $path
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

Set-Content -LiteralPath $path -Value $InputData.content -NoNewline

$file = Get-Item -LiteralPath $path
@{
    id            = $file.FullName
    size          = [int]$file.Length
    last_modified = $file.LastWriteTimeUtc.ToString('o')
}
