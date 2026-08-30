# read.ps1 - called on `terraform plan`/`refresh` and after import.
#
# Emitting NOTHING tells Terraform the object no longer exists, so it plans
# recreation. Only computed attributes are refreshed from the emitted object;
# config attributes always come from state.
#
# See create.ps1 for the full script contract.
[CmdletBinding()]
param(
    # The config attributes from state (path, content) PLUS 'id' - the value
    # create.ps1 emitted, or the argument to `terraform import`. After an
    # import 'id' is all you get: the config attributes are absent until the
    # first refresh, so read from 'id' rather than from 'path' here.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'read.ps1 requires a non-empty $InputData.id; the engine injects it from state or from the terraform import argument.')]
    [hashtable]$InputData
)

if (-not (Test-Path -LiteralPath $InputData.id)) {
    return
}

$file = Get-Item -LiteralPath $InputData.id
@{
    id            = $file.FullName
    size          = [int]$file.Length
    last_modified = $file.LastWriteTimeUtc.ToString('o')
}
