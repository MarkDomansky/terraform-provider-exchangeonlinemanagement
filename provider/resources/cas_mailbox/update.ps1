# update.ps1 - in-place Set-CASMailbox. Its existence is what makes config
# changes update the settings instead of destroying and recreating the resource.
#
# `identity` is not marked requires_replace, because `terraform import`
# populates only 'id' and the engine cannot write config attributes from a read
# script - so after an import identity would go null -> value and a
# requires_replace attribute would plan a destroy. Repointing the resource at a
# different mailbox is caught here instead, with a named error.
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

$cas = Get-EXOCASMailboxOrNull -Identity $id
if (-not $cas) {
    throw "The mailbox this resource configures (id $id) no longer exists. Run `terraform refresh` (or any plan) to let Terraform notice it is gone."
}

# Repointing guard. A no-op straight after an import (state null -> config
# value -> already resolves to the same mailbox).
if ($InputData.ContainsKey('identity') -and $InputData.identity) {
    $requested = [string]$InputData.identity
    $target = Get-EXOCASMailboxOrNull -Identity $requested
    if (-not $target) {
        throw "No mailbox matches identity '$requested'. Create it first, or correct the identity."
    }
    if ([string]$target.Guid -ne $id) {
        throw (
            "identity now resolves to a different mailbox than this resource manages. It was created against " +
            "the mailbox with GUID $id ('$($cas.PrimarySmtpAddress)') and '$requested' resolves to " +
            "$($target.Guid) ('$($target.PrimarySmtpAddress)'). Client access settings belong to a specific " +
            "mailbox, so this is a different resource: declare a separate exchangeonlinemanagement_cas_mailbox " +
            "for it, or force a recreate with terraform apply -replace=<address> (which leaves the original " +
            "mailbox's settings untouched unless revert_on_destroy is set)."
        )
    }
}

$set = New-EXOCASSetSplat -InputData $InputData -Identity $id
if ($set.Count -gt 4) {
    Set-CASMailbox @set | Out-Null
}

$updated = Get-EXOCASMailboxOrNull -Identity $id
if (-not $updated) {
    # Emitting nothing here would null every computed attribute rather than
    # signalling "gone" (only read.ps1 carries that meaning), so fail loudly.
    throw "Client access settings for mailbox $id were updated but could not be read back; its Terraform state would be incomplete. Re-run to refresh."
}

ConvertTo-EXOCASState -CASMailbox $updated -Id $id
