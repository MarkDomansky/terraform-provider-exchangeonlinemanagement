# create.ps1 - New-Mailbox, then Set-Mailbox for everything New-Mailbox cannot
# take, then emit the mailbox's state.
#
# Contract: the engine binds $InputData BY NAME and supplies no other argument,
# so any extra parameter you declare must be optional. $Action ('create',
# 'read', ...) arrives as an enclosing-scope variable - declaring it as a
# parameter shadows it with $null. Emit EXACTLY ONE object; error-stream output
# fails the operation; pipe unwanted cmdlet output to Out-Null.
[CmdletBinding()]
param(
    # Every non-null config attribute from the manifest, naturally typed, plus
    # any `default` it declares. There is no 'id' yet - create is what mints it.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$type = if ($InputData.type) { [string]$InputData.type } else { 'shared' }

$new = @{
    Name          = [string]$InputData.name
    Confirm       = $false
    ErrorAction   = 'Stop'
    WarningAction = 'SilentlyContinue'
}

switch ($type) {
    'shared' { $new.Shared = $true }
    'room' { $new.Room = $true }
    'equipment' { $new.Equipment = $true }
    'user' {
        if (-not $InputData.user_principal_name) {
            throw 'type = "user" requires user_principal_name: New-Mailbox needs a MicrosoftOnlineServicesID to create a user mailbox. Consider licensing a user in Entra ID instead, which is the supported way to provision user mailboxes in Exchange Online.'
        }
        if (-not $InputData.password) {
            throw 'type = "user" requires password: New-Mailbox needs an initial password to create a user mailbox. It is used only at creation and never reconciled afterwards.'
        }
        $new.MicrosoftOnlineServicesID = [string]$InputData.user_principal_name
        $new.Password = ConvertTo-SecureString -String ([string]$InputData.password) -AsPlainText -Force
    }
    default { throw "Unknown mailbox type '$type'. Valid values: shared, room, equipment, user." }
}

# New-Mailbox accepts these directly, which avoids a window where the mailbox
# exists under a derived alias before Set-Mailbox corrects it.
if ($InputData.alias) { $new.Alias = [string]$InputData.alias }
if ($InputData.display_name) { $new.DisplayName = [string]$InputData.display_name }

# Assigned, not piped: the emitted object must be ours alone.
$created = New-Mailbox @new

$id = [string]$created.Guid
if ([string]::IsNullOrWhiteSpace($id)) {
    throw 'New-Mailbox returned no Guid, so there is no stable identifier to record as the Terraform id.'
}

# Exchange Online returns from New-Mailbox before the mailbox is addressable by
# Set-Mailbox. Without this poll, creates fail intermittently AFTER the mailbox
# exists, leaving a real mailbox with no Terraform state. The cap is well inside
# the resource's 300s timeout so the failure is ours and legible.
$deadline = (Get-Date).AddSeconds(120)
$backoffSeconds = 1
$mailbox = $null
while (-not $mailbox) {
    $mailbox = Get-EXOMailboxOrNull -Identity $id
    if ($mailbox) { break }
    if ((Get-Date) -ge $deadline) {
        throw "Mailbox '$($InputData.name)' was created (id $id) but did not become readable within 120 seconds; this is Exchange Online replication lag. The mailbox exists - import it with: terraform import <address> $id"
    }
    # Back off gently: the mailbox is usually ready within a second or two, so
    # a fixed long interval would tax every create for the sake of the slow case.
    Start-Sleep -Seconds $backoffSeconds
    if ($backoffSeconds -lt 10) { $backoffSeconds *= 2 }
}

# name, alias and display_name were already applied by New-Mailbox. Excluding
# them means a mailbox with nothing else configured skips Set-Mailbox entirely,
# rather than making a redundant call on every create.
$set = New-EXOMailboxSetSplat -InputData $InputData -Identity $id -Exclude @('name', 'alias', 'display_name')
# Anything beyond the four fixed keys (Identity, Confirm, ErrorAction,
# WarningAction) means there is something left to apply.
if ($set.Count -gt 4) {
    Set-Mailbox @set | Out-Null
    $mailbox = Get-EXOMailboxOrNull -Identity $id
}

ConvertTo-EXOMailboxState -Mailbox $mailbox -Id $id
