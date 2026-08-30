# read.ps1 - refresh the client access settings from Exchange.
#
# Emitting NOTHING means "the mailbox is gone", so Terraform drops the resource
# and plans a recreate. Get-EXOCASMailboxOrNull returns $null only for a
# genuine not-found and rethrows everything else, so a throttling response can
# never be mistaken for a deleted mailbox.
#
# Only computed attributes are refreshed from what this emits; config
# attributes always come from state. That is why every managed setting has an
# effective_* mirror - those mirrors are the only drift Terraform can see.
#
# See create.ps1 for the full contract.
[CmdletBinding()]
param(
    # The config attributes from state, plus 'id' - the mailbox GUID create.ps1
    # emitted, or the argument to `terraform import`.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'read.ps1 requires a non-empty $InputData.id; the engine injects it from state or from the terraform import argument.')]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$id = [string]$InputData.id

$cas = Get-EXOCASMailboxOrNull -Identity $id
if (-not $cas) { return }

ConvertTo-EXOCASState -CASMailbox $cas -Id $id
