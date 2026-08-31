# read.ps1 - the only script a data source has. A data source carries no state,
# so there is no 'id' in $InputData.
#
# Contract: the engine binds $InputData BY NAME and supplies no other argument,
# so any extra parameter you declare must be optional. $Action arrives as an
# enclosing-scope variable - declaring it as a parameter shadows it with $null.
# Emit EXACTLY ONE object; error-stream output fails the operation; pipe
# unwanted cmdlet output to Out-Null.
[CmdletBinding()]
param(
    # The lookup attributes the practitioner set. All three are optional in the
    # manifest and exactly one must be present - a rule enforced below.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$InputData
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# A Terraform provider schema cannot express "exactly one of", and this engine
# builds attributes straight from the manifest with no cross-attribute
# validators, so the rule is enforced here rather than at plan time.
$lookupKeys = @('user_principal_name', 'object_id', 'email_address')
$supplied = @($lookupKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$InputData[$_]) })

if ($supplied.Count -eq 0) {
    throw "Set exactly one of user_principal_name, object_id or email_address on data.exchangeonlinemanagement_mailbox; none was set."
}
if ($supplied.Count -gt 1) {
    throw "Set exactly one of user_principal_name, object_id or email_address on data.exchangeonlinemanagement_mailbox; got $($supplied -join ' and '). They are alternative ways to find the same mailbox, so combining them is ambiguous."
}

# Get-Mailbox -Identity resolves a UPN, an ExternalDirectoryObjectId and any
# SMTP address on the mailbox, so all three lookups take the same path.
$mailbox = Get-EXOMailboxOrNull -Identity ([string]$InputData[$supplied[0]])

if (-not $mailbox) {
    # An empty emission would just null every computed attribute, which is
    # indistinguishable from a mailbox with no properties. Say so explicitly.
    @{ found = $false }
    return
}

# custom_attributes: CustomAttribute1..15 -> { "1" = "finance" }, empties dropped.
$customAttributes = @{}
foreach ($index in 1..15) {
    $value = [string]$mailbox."CustomAttribute$index"
    if (-not [string]::IsNullOrWhiteSpace($value)) { $customAttributes["$index"] = $value }
}

# mailbox_json must be built from nested hashtables. The sidecar passes
# hashtables, strings, bools, numbers and lists through and calls .ToString()
# on everything else, so a nested PSCustomObject would land in state as the
# literal string "System.Management.Automation.PSCustomObject". Dates and
# collections are normalised too, otherwise state churns between refreshes and
# between machines with different cultures.
$json = @{}
foreach ($property in $mailbox.PSObject.Properties) {
    $value = $property.Value
    $json[$property.Name] =
    if ($null -eq $value) { $null }
    elseif ($value -is [bool]) { $value }
    elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) { $value }
    elseif ($value -is [string]) { $value }
    elseif ($value -is [datetime]) { ([datetime]$value).ToUniversalTime().ToString('o') }
    elseif ($value -is [System.Collections.IEnumerable]) { ConvertTo-EXOStringArray -Value $value }
    else { [string]$value }
}

@{
    found                          = $true
    mailbox_guid                   = [string]$mailbox.Guid
    exchange_guid                  = [string]$mailbox.ExchangeGuid
    external_directory_object_id   = [string]$mailbox.ExternalDirectoryObjectId
    effective_user_principal_name  = [string]$mailbox.UserPrincipalName
    primary_smtp_address           = [string]$mailbox.PrimarySmtpAddress
    email_addresses                = (ConvertTo-EXOStringArray -Value $mailbox.EmailAddresses)
    name                           = [string]$mailbox.Name
    display_name                   = [string]$mailbox.DisplayName
    alias                          = [string]$mailbox.Alias
    recipient_type                 = [string]$mailbox.RecipientType
    recipient_type_details         = [string]$mailbox.RecipientTypeDetails
    hidden_from_address_lists      = (ConvertTo-EXONullableBool -Value $mailbox.HiddenFromAddressListsEnabled)
    litigation_hold_enabled        = (ConvertTo-EXONullableBool -Value $mailbox.LitigationHoldEnabled)
    is_directory_synced            = (ConvertTo-EXONullableBool -Value $mailbox.IsDirSynced)
    deliver_to_mailbox_and_forward = (ConvertTo-EXONullableBool -Value $mailbox.DeliverToMailboxAndForward)
    forwarding_smtp_address        = [string]$mailbox.ForwardingSmtpAddress
    retention_policy               = [string]$mailbox.RetentionPolicy
    issue_warning_quota            = [string]$mailbox.IssueWarningQuota
    prohibit_send_quota            = [string]$mailbox.ProhibitSendQuota
    prohibit_send_receive_quota    = [string]$mailbox.ProhibitSendReceiveQuota
    max_send_size                  = [string]$mailbox.MaxSendSize
    max_receive_size               = [string]$mailbox.MaxReceiveSize
    custom_attributes              = $customAttributes
    when_created                   = (ConvertTo-EXODateString -Value $mailbox.WhenCreatedUTC)
    mailbox_json                   = $json
}
