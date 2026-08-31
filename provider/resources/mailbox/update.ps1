# update.ps1 - in-place Set-Mailbox. Its existence is what makes config changes
# update the mailbox instead of destroying and recreating it.
#
# No attribute on this resource is marked requires_replace, deliberately.
# `terraform import` populates only 'id' and the engine cannot write config
# attributes from a read script, so after an import every config attribute goes
# null -> value on the next plan. On a requires_replace attribute that is an
# immediate destroy-and-recreate of a live mailbox. Genuinely immutable fields
# are guarded here instead, where they can produce a named error.
#
# See create.ps1 for the full contract.
[CmdletBinding()]
param(
    # The planned config attributes, plus 'id' from prior state.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace([string]$_['id']) },
        ErrorMessage = 'update.ps1 requires a non-empty $InputData.id; the engine injects it from state.')]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$id = [string]$InputData.id

$current = Get-EXOMailboxOrNull -Identity $id
if (-not $current) {
    throw "Mailbox '$id' no longer exists, so it cannot be updated. Run `terraform refresh` (or any plan) to let Terraform notice it is gone and plan a recreate."
}

# --- immutable field guards --------------------------------------------------
# A no-op straight after an import (state null -> config value -> server already
# matches). A real change gets an actionable error at apply time.

if ($InputData.ContainsKey('user_principal_name') -and $InputData.user_principal_name) {
    $requested = [string]$InputData.user_principal_name
    if ([string]$current.UserPrincipalName -ne $requested) {
        throw (
            "Changing user_principal_name on an existing mailbox is not supported: the UPN is owned by " +
            "Entra ID, not by Set-Mailbox. Current: '$($current.UserPrincipalName)', requested: '$requested'. " +
            "Change the user in Entra ID and update the configuration to match, or force a recreate with " +
            "terraform apply -replace=<address> (which deletes the mailbox and its contents)."
        )
    }
}

# --- mailbox type conversion -------------------------------------------------
# Set-Mailbox -Type converts in place; 'user' is Exchange's 'Regular'.

if ($InputData.ContainsKey('type') -and $InputData.type) {
    $requestedType = [string]$InputData.type
    $exchangeType = switch ($requestedType) {
        'user' { 'Regular' }
        'shared' { 'Shared' }
        'room' { 'Room' }
        'equipment' { 'Equipment' }
        default { throw "Unknown mailbox type '$requestedType'. Valid values: shared, room, equipment, user." }
    }
    $currentDetails = [string]$current.RecipientTypeDetails
    if ($currentDetails -ne "${exchangeType}Mailbox" -and -not ($exchangeType -eq 'Regular' -and $currentDetails -eq 'UserMailbox')) {
        Set-Mailbox -Identity $id -Type $exchangeType -Confirm:$false -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    }
}

# --- everything else ---------------------------------------------------------
# password is deliberately absent from the splat: it applies only at creation.

$set = New-EXOMailboxSetSplat -InputData $InputData -Identity $id
if ($set.Count -gt 4) {
    Set-Mailbox @set | Out-Null
}

$updated = Get-EXOMailboxOrNull -Identity $id
if (-not $updated) {
    # Emitting nothing here would null every computed attribute rather than
    # signalling "gone" (only read.ps1 carries that meaning), so fail loudly.
    throw "Mailbox '$id' was updated but could not be read back; its Terraform state would be incomplete. Re-run to refresh."
}

ConvertTo-EXOMailboxState -Mailbox $updated -Id $id
