# create.ps1 - there is no New-CASMailbox. Client access settings exist on a
# mailbox that already exists, so "create" means: resolve the mailbox, then
# apply the configured settings with Set-CASMailbox.
#
# Contract: the engine binds $InputData BY NAME and supplies no other argument,
# so any extra parameter you declare must be optional. $Action ('create',
# 'read', ...) arrives as an enclosing-scope variable - declaring it as a
# parameter shadows it with $null. Emit EXACTLY ONE object; error-stream output
# fails the operation; pipe unwanted cmdlet output to Out-Null.
[CmdletBinding()]
param(
    # Every non-null config attribute from the manifest. There is no 'id' yet -
    # create is what mints it.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$identity = [string]$InputData.identity

$cas = Get-EXOCASMailboxOrNull -Identity $identity
if (-not $cas) {
    throw (
        "No mailbox matches identity '$identity'. This resource configures an existing mailbox rather than " +
        "creating one - create the mailbox first (with exchangeonlinemanagement_mailbox, or by licensing a " +
        "user in Entra ID) and add depends_on if Terraform cannot infer the ordering."
    )
}

# The mailbox GUID, not the practitioner's identity string: it survives renames
# and address changes, so the resource stays bound to the same mailbox.
$id = [string]$cas.Guid
if ([string]::IsNullOrWhiteSpace($id)) {
    throw "Get-CASMailbox returned no Guid for '$identity', so there is no stable identifier to record as the Terraform id."
}

$set = New-EXOCASSetSplat -InputData $InputData -Identity $id
# Anything beyond the four fixed keys (Identity, Confirm, ErrorAction,
# WarningAction) means the practitioner actually configured something.
if ($set.Count -gt 4) {
    Set-CASMailbox @set | Out-Null
    $cas = Get-EXOCASMailboxOrNull -Identity $id
}

ConvertTo-EXOCASState -CASMailbox $cas -Id $id
