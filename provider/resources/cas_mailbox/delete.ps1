# delete.ps1 - there is no Remove-CASMailbox. Client access settings are
# properties of a mailbox this resource does not own, so a destroy cannot
# "delete" anything.
#
# Default behaviour is therefore a deliberate no-op: Terraform drops the
# resource from state and the mailbox keeps whatever settings it has. That
# means hardening applied here SURVIVES a destroy. Set revert_on_destroy to
# have the destroy restore Exchange's defaults instead.
#
# The revert only touches settings this resource actually managed.
# $InputData carries the config attributes plus 'id' - and because none of the
# client access attributes declares a manifest default, ContainsKey is an exact
# "this resource managed that setting" signal. Computed attributes are NOT
# available here, which is also why the pre-existing values cannot be snapshot
# and restored, and why revert_values exists.
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

if (-not $InputData.revert_on_destroy) {
    @{ id = $id }
    return
}

# Idempotence: nothing to revert if the mailbox itself is gone.
$cas = Get-EXOCASMailboxOrNull -Identity $id
if (-not $cas) {
    @{ id = $id }
    return
}

$revert = @{
    Identity      = $id
    Confirm       = $false
    ErrorAction   = 'Stop'
    WarningAction = 'SilentlyContinue'
}

foreach ($entry in (Get-EXOCASDefault).GetEnumerator()) {
    # Never managed here, so never touched on the way out.
    if (-not $InputData.ContainsKey($entry.Key)) { continue }
    # $entry.Value[1] is often $null - that is Exchange's "inherit the
    # organisation setting" state, and a real revert target.
    $revert[$entry.Value[0]] = $entry.Value[1]
}

# Practitioner overrides of the built-in defaults table, for the settings whose
# correct default is tenant-specific (the policy names, mainly).
foreach ($entry in (ConvertTo-EXOSplat -Value $InputData['revert_values']).GetEnumerator()) {
    $revert[$entry.Key] = $entry.Value
}

if ($revert.Count -gt 4) {
    Set-CASMailbox @revert | Out-Null
}

@{ id = $id }
