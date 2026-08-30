# update.ps1 - called when config changed and this file exists.
#
# DELETE THIS FILE to make every config change replace the resource instead
# (delete-then-create). Its presence alone enables in-place updates.
#
# See create.ps1 for the full script contract.
[CmdletBinding()]
param(
    # The PLANNED config attributes plus 'id'. Attributes marked
    # requires_replace in example_file.tfps.json (path) never change here - a
    # change to one of those replaces the resource - so only 'content' differs
    # from what read.ps1 last saw.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'update.ps1 requires a non-empty $InputData.id; the engine injects it from state.')]
    [hashtable]$InputData
)

Set-Content -LiteralPath $InputData.id -Value $InputData.content -NoNewline

$file = Get-Item -LiteralPath $InputData.id
@{
    id            = $file.FullName
    size          = [int]$file.Length
    last_modified = $file.LastWriteTimeUtc.ToString('o')
}
