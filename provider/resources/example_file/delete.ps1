# delete.ps1 - called on `terraform destroy` (and for the delete half of a
# replacement). Deleting an already-missing object must succeed (idempotent
# destroy).
#
# See create.ps1 for the full script contract.
[CmdletBinding()]
param(
    # The config attributes from state plus 'id'.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'delete.ps1 requires a non-empty $InputData.id; the engine injects it from state.')]
    [hashtable]$InputData
)

if (Test-Path -LiteralPath $InputData.id) {
    Remove-Item -LiteralPath $InputData.id -Force
}

@{ id = $InputData.id }
