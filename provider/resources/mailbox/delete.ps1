# delete.ps1 - Remove-Mailbox. Destroy must be idempotent: removing a mailbox
# that is already gone has to succeed.
#
# $InputData here carries the config attributes plus 'id'. Computed attributes
# are NOT available to a delete script.
#
# See create.ps1 for the full contract.
[CmdletBinding()]
param(
    # The config attributes from state, plus 'id'.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'delete.ps1 requires a non-empty $InputData.id; the engine injects it from state.')]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$id = [string]$InputData.id

# Idempotence: Get-EXOMailboxOrNull returns $null for a genuine not-found
# instead of writing to the error stream, which would fail the operation.
$mailbox = Get-EXOMailboxOrNull -Identity $id
if ($mailbox) {
    $remove = @{
        Identity      = $id
        # Mandatory: Remove-Mailbox has a high ConfirmImpact, and a prompt in
        # the sidecar's non-interactive host blocks until the operation times out.
        Confirm       = $false
        ErrorAction   = 'Stop'
        WarningAction = 'SilentlyContinue'
    }
    if ($InputData.permanently_delete) {
        $remove.PermanentlyDelete = $true
    }
    Remove-Mailbox @remove | Out-Null
}

@{ id = $id }
