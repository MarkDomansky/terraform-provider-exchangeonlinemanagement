# read.ps1 - called on `terraform plan`/`refresh` and after import.
#
# Emitting NOTHING tells Terraform the mailbox no longer exists, so it plans
# recreation. That makes Get-EXOMailboxOrNull's "is this a not-found?" test
# load-bearing: a transient failure misread as not-found would destroy a live
# mailbox. It returns $null only for a genuine not-found and rethrows the rest.
#
# Only computed attributes are refreshed from what this emits; config
# attributes always come from state. See create.ps1 for the full contract.
[CmdletBinding()]
param(
    # The config attributes from state, plus 'id' - the mailbox GUID create.ps1
    # emitted, or the argument to `terraform import`. After an import 'id' is
    # all you get, so resolve from it rather than from 'name'.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'read.ps1 requires a non-empty $InputData.id; the engine injects it from state or from the terraform import argument.')]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$id = [string]$InputData.id

# 'id' is whatever -Identity accepted: the GUID create.ps1 minted, or the UPN
# or address someone imported with. The engine cannot rewrite an id after
# import, so never parse it - just pass it through.
$mailbox = Get-EXOMailboxOrNull -Identity $id
if (-not $mailbox) { return }

ConvertTo-EXOMailboxState -Mailbox $mailbox -Id $id
