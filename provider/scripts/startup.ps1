# Provider startup script. Runs once per terraform run, after the engine is
# configured, BEFORE the practitioner's startup_script.
#
# CONTRACT: no param block. A lifecycle script runs flat at the runspace scope
# (that is what lets it create globals that outlive the call) and the engine
# prepends its own param block, so a second one is a parse error. Inputs come
# from $global:ProviderData.Config, which holds the attributes declared in
# provider/provider.tfps.json.
#
# Nothing may reach the error stream and at most one object may reach the
# success stream, or provider configuration fails. Every cmdlet call below is
# therefore assigned or piped to Out-Null, and failures are raised with `throw`.
#
# This script also defines the `function global:` helpers shared by every CRUD
# script. That is not a style choice: scripts are embedded in the Go binary and
# $PSScriptRoot is empty at runtime, so dot-sourcing a library file is
# impossible. Globals persist for the whole run because the PowerShell process
# is persistent.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$cfg = if ($global:ProviderData) { $global:ProviderData.Config } else { $null }

# Trimmed string accessor: absent, null and whitespace-only all collapse to ''.
$getSetting = {
    param($Name)
    if (-not $cfg) { return '' }
    $value = [string]$cfg.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { '' } else { $value.Trim() }
}

$organization = & $getSetting 'organization'
$appId        = & $getSetting 'app_id'
$authMethod   = & $getSetting 'auth_method'
$thumbprint   = & $getSetting 'certificate_thumbprint'
$certPath     = & $getSetting 'certificate_path'
$certPassword = & $getSetting 'certificate_password'
$modulePath   = & $getSetting 'module_path'
$environment  = & $getSetting 'exchange_environment_name'
if (-not $environment) { $environment = 'O365Default' }

# ---------------------------------------------------------------------------
# 1. The ExchangeOnlineManagement module must already be installed.
# ---------------------------------------------------------------------------
# The provider bundles a PowerShell host, not a PowerShell module library. The
# module has to be on the PSModulePath of the process running terraform.

if ($modulePath) {
    $env:PSModulePath = $modulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath
}

if (-not (Get-Command -Name 'Connect-ExchangeOnline' -ErrorAction Ignore)) {
    try {
        Import-Module -Name 'ExchangeOnlineManagement' -MinimumVersion '3.0.0' -ErrorAction Stop | Out-Null
    }
    catch {
        throw (
            "The exchangeonlinemanagement provider requires the ExchangeOnlineManagement PowerShell module " +
            "(3.0.0 or later) to be installed on the machine running terraform, and it could not be loaded: " +
            "$($_.Exception.Message)`n`n" +
            "Install it with:`n" +
            "    Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion 3.0.0`n`n" +
            "The provider hosts PowerShell in-process rather than launching pwsh, so the module must be on " +
            "the PSModulePath that the terraform process itself sees. If it is installed somewhere else, set " +
            "the provider's module_path attribute (or EXO_MODULE_PATH) to the directory containing it."
        )
    }
}

$connectCommand = Get-Command -Name 'Connect-ExchangeOnline' -ErrorAction Ignore
if (-not $connectCommand) {
    throw 'ExchangeOnlineManagement was imported but Connect-ExchangeOnline is not available.'
}
# $null when a unit test has stubbed the cmdlet with a plain function.
$moduleVersion = if ($connectCommand.Module) { [string]$connectCommand.Module.Version } else { 'unknown' }

# ---------------------------------------------------------------------------
# 2. Pick the authentication mode.
# ---------------------------------------------------------------------------
# The two certificate modes are mutually exclusive, and a Terraform provider
# schema cannot express mutual exclusivity, so the provider enforces it here.

$supplied = @()
if ($thumbprint) { $supplied += 'certificate_thumbprint' }
if ($certPath) { $supplied += 'certificate_path' }

$modeHelp = "certificate_thumbprint (Windows only), or certificate_path (+ certificate_password, all platforms)"

if ($authMethod) {
    $mode = $authMethod
}
elseif ($supplied.Count -eq 1) {
    $mode = $supplied[0]
}
elseif ($supplied.Count -gt 1) {
    throw (
        "Ambiguous Exchange Online authentication: both certificate_thumbprint and certificate_path are set, " +
        "and they are mutually exclusive. Remove one, or set auth_method (EXO_AUTH_METHOD) to the one you " +
        "want: $modeHelp."
    )
}
else {
    throw (
        "No Exchange Online certificate configured. This provider uses certificate-based app-only " +
        "authentication; set exactly one of: $modeHelp. See the 'Registering the Entra application' guide " +
        "for how to create the app registration and its certificate."
    )
}

if (-not $appId) {
    throw "app_id is required for app-only Exchange Online authentication. Set the provider's app_id attribute or EXO_APP_ID to the Entra application (client) ID."
}
if (-not $organization) {
    throw "organization is required for app-only Exchange Online authentication. Set the provider's organization attribute or EXO_ORGANIZATION to the tenant's domain, for example contoso.onmicrosoft.com."
}

# ---------------------------------------------------------------------------
# 3. Build the connection.
# ---------------------------------------------------------------------------
# Startup runs on every plan, apply, refresh and destroy, so connect cost is a
# tax on every command: skip the banner and the format data, and honour
# command_names when the practitioner has narrowed the cmdlet set.

$connect = @{
    AppId                   = $appId
    Organization            = $organization
    ExchangeEnvironmentName = $environment
    ShowBanner              = $false
    SkipLoadingFormatData   = $true
    ErrorAction             = 'Stop'
}

$commandNames = @()
if ($cfg -and $cfg.command_names) {
    $commandNames = @($cfg.command_names) | ForEach-Object { [string]$_ } | Where-Object { $_ }
}
if ($commandNames.Count -gt 0) {
    $connect.CommandName = [string[]]$commandNames
}

switch ($mode) {
    'certificate_thumbprint' {
        if (-not $thumbprint) {
            throw "auth_method 'certificate_thumbprint' requires certificate_thumbprint (or EXO_CERTIFICATE_THUMBPRINT)."
        }
        if (-not $IsWindows) {
            throw (
                "auth_method 'certificate_thumbprint' is Windows-only: Connect-ExchangeOnline reads the " +
                "certificate from the Windows certificate store, and Microsoft documents no cross-platform " +
                "equivalent. This provider is running on a non-Windows platform. Use certificate_path " +
                "(+ certificate_password) with a PFX file instead."
            )
        }
        $connect.CertificateThumbprint = $thumbprint
    }

    'certificate_path' {
        if (-not $certPath) {
            throw "auth_method 'certificate_path' requires certificate_path (or EXO_CERTIFICATE_PATH)."
        }
        if (-not (Test-Path -LiteralPath $certPath)) {
            throw (
                "certificate_path '$certPath' does not exist. The path is resolved on the machine running " +
                "the provider, which is the machine running terraform - not on any remote system."
            )
        }
        $connect.CertificateFilePath = (Resolve-Path -LiteralPath $certPath).ProviderPath
        if ($certPassword) {
            $connect.CertificatePassword = ConvertTo-SecureString -String $certPassword -AsPlainText -Force
        }
    }

    default {
        throw "Unknown auth_method '$mode'. Valid values: certificate_thumbprint, certificate_path."
    }
}

Connect-ExchangeOnline @connect | Out-Null

$global:EXOProviderState = @{
    AuthMethod     = $mode
    Organization   = $organization
    Environment    = $environment
    ModuleVersion  = $moduleVersion
    ConnectedAtUtc = (Get-Date).ToUniversalTime()
}

# ---------------------------------------------------------------------------
# 4. Shared helpers for the CRUD scripts.
# ---------------------------------------------------------------------------

function global:Test-EXONotFound {
    # Distinguishes "the recipient does not exist" from "the call failed".
    #
    # This is the highest-consequence predicate in the provider: read.ps1 turns
    # a true result into "emit nothing", which tells Terraform the object is
    # gone and makes it plan a recreate. A match that is too broad would turn a
    # throttling response or an expired token into the destruction of a live
    # mailbox, so it stays deliberately narrow and everything else rethrows.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ($ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound') { return $true }

    $probe = "$($ErrorRecord.FullyQualifiedErrorId) $($ErrorRecord.Exception.Message)"
    return ($probe -match "ManagementObjectNotFound|couldn't be found|wasn't found|does not exist")
}

function global:Get-EXOMailboxOrNull {
    # Get-Mailbox, with "not found" as $null instead of a terminating error.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)

    try { return Get-Mailbox -Identity $Identity -ErrorAction Stop }
    catch {
        if (Test-EXONotFound -ErrorRecord $_) { return $null }
        throw
    }
}

function global:Get-EXOCASMailboxOrNull {
    # Get-CASMailbox, with "not found" as $null instead of a terminating error.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)

    try { return Get-CASMailbox -Identity $Identity -ErrorAction Stop }
    catch {
        if (Test-EXONotFound -ErrorRecord $_) { return $null }
        throw
    }
}

function global:Add-EXOParam {
    # Copy an $InputData key into a cmdlet splat only when the practitioner
    # actually set it. Attributes without a manifest `default` are absent from
    # $InputData when left unconfigured, so ContainsKey is an exact "this
    # resource manages that setting" signal - which is why almost nothing in
    # this provider declares a default.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Splat,
        [Parameter(Mandatory)][hashtable]$InputData,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Parameter
    )

    if (-not $InputData.ContainsKey($Key)) { return }
    if ($null -eq $InputData[$Key]) { return }
    $Splat[$Parameter] = $InputData[$Key]
}

function global:ConvertTo-EXOSplat {
    # A `json` attribute arrives decoded as a nested hashtable. Normalise it to
    # a plain [hashtable] that is safe to splat onto a cmdlet.
    [CmdletBinding()]
    param([object]$Value)

    $splat = @{}
    if ($null -eq $Value) { return $splat }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $splat[[string]$key] = $Value[$key] }
        return $splat
    }
    foreach ($property in $Value.PSObject.Properties) { $splat[$property.Name] = $property.Value }
    return $splat
}

function global:ConvertTo-EXOStringArray {
    # Project any multi-valued Exchange property to a real string array.
    #
    # The leading comma matters: without it a single-element result unrolls to
    # a bare string, and the engine rejects a `set`/`list` attribute that is not
    # an array.
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return , @() }
    return , @(@($Value) | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function global:ConvertTo-EXONullableBool {
    # [bool]$null is $false, which would silently report "disabled" for a
    # setting Exchange left unset. Keep null as null.
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    return [bool]$Value
}

function global:ConvertTo-EXODateString {
    # The sidecar stringifies unknown types with .ToString(), which is
    # culture-dependent and would churn state between machines. Pin ISO 8601.
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    return ([datetime]$Value).ToUniversalTime().ToString('o')
}

function global:ConvertTo-EXOMailboxState {
    # The single projection from a mailbox object to the resource's computed
    # attributes, shared by create.ps1, read.ps1 and update.ps1 so the three can
    # never drift apart. Emits nothing when the mailbox is absent, which is the
    # engine's "this object is gone" signal.
    [CmdletBinding()]
    param([object]$Mailbox, [Parameter(Mandatory)][string]$Id)

    if (-not $Mailbox) { return }

    @{
        id                             = $Id
        exchange_guid                  = [string]$Mailbox.ExchangeGuid
        external_directory_object_id   = [string]$Mailbox.ExternalDirectoryObjectId
        effective_primary_smtp_address = [string]$Mailbox.PrimarySmtpAddress
        effective_alias                = [string]$Mailbox.Alias
        effective_display_name         = [string]$Mailbox.DisplayName
        effective_user_principal_name  = [string]$Mailbox.UserPrincipalName
        effective_email_addresses      = (ConvertTo-EXOStringArray -Value $Mailbox.EmailAddresses)
        recipient_type_details         = [string]$Mailbox.RecipientTypeDetails
        distinguished_name             = [string]$Mailbox.DistinguishedName
        is_directory_synced            = (ConvertTo-EXONullableBool -Value $Mailbox.IsDirSynced)
        when_created                   = (ConvertTo-EXODateString -Value $Mailbox.WhenCreatedUTC)
    }
}

function global:New-EXOMailboxSetSplat {
    # Build the Set-Mailbox splat for the mailbox resource. Shared by create.ps1
    # and update.ps1 so a setting can never be applied on create but forgotten
    # on update.
    #
    # Returns the splat; the caller decides whether it is worth invoking (the
    # four fixed keys below mean an unconfigured mailbox still yields Count 4).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$InputData,
        [Parameter(Mandatory)][string]$Identity,
        # Attribute names to leave out. create.ps1 excludes the ones New-Mailbox
        # already applied, so a freshly created mailbox needing nothing else
        # skips the redundant Set-Mailbox call entirely.
        [string[]]$Exclude = @()
    )

    if ($Exclude.Count -gt 0) {
        $filtered = @{}
        foreach ($pair in $InputData.GetEnumerator()) {
            if ($Exclude -notcontains $pair.Key) { $filtered[$pair.Key] = $pair.Value }
        }
        $InputData = $filtered
    }

    # -Confirm:$false is mandatory throughout: Set-Mailbox has a high
    # ConfirmImpact and a prompt in the sidecar's non-interactive host would
    # block until the operation timeout and then fail opaquely.
    $splat = @{
        Identity      = $Identity
        Confirm       = $false
        ErrorAction   = 'Stop'
        WarningAction = 'SilentlyContinue'
    }

    Add-EXOParam -Splat $splat -InputData $InputData -Key 'name'                           -Parameter 'Name'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'alias'                          -Parameter 'Alias'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'display_name'                   -Parameter 'DisplayName'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'primary_smtp_address'           -Parameter 'WindowsEmailAddress'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'hidden_from_address_lists'      -Parameter 'HiddenFromAddressListsEnabled'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'litigation_hold_enabled'        -Parameter 'LitigationHoldEnabled'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'litigation_hold_duration_days'  -Parameter 'LitigationHoldDuration'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'retention_policy'               -Parameter 'RetentionPolicy'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'issue_warning_quota'            -Parameter 'IssueWarningQuota'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'prohibit_send_quota'            -Parameter 'ProhibitSendQuota'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'prohibit_send_receive_quota'    -Parameter 'ProhibitSendReceiveQuota'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'max_send_size'                  -Parameter 'MaxSendSize'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'max_receive_size'               -Parameter 'MaxReceiveSize'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'forwarding_smtp_address'        -Parameter 'ForwardingSmtpAddress'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'deliver_to_mailbox_and_forward' -Parameter 'DeliverToMailboxAndForward'
    Add-EXOParam -Splat $splat -InputData $InputData -Key 'resource_capacity'              -Parameter 'ResourceCapacity'

    # Authoritative multi-valued settings: cast so a single element stays an array.
    if ($InputData.ContainsKey('email_addresses') -and $null -ne $InputData['email_addresses']) {
        $splat.EmailAddresses = [string[]]@($InputData['email_addresses'] | ForEach-Object { [string]$_ })
    }
    if ($InputData.ContainsKey('grant_send_on_behalf_to') -and $null -ne $InputData['grant_send_on_behalf_to']) {
        $splat.GrantSendOnBehalfTo = [string[]]@($InputData['grant_send_on_behalf_to'] | ForEach-Object { [string]$_ })
    }

    # custom_attributes: { "3" = "finance" } -> -CustomAttribute3 'finance'.
    if ($InputData.ContainsKey('custom_attributes') -and $null -ne $InputData['custom_attributes']) {
        $custom = $InputData['custom_attributes']
        foreach ($key in @($custom.Keys)) {
            $index = 0
            if (-not [int]::TryParse([string]$key, [ref]$index) -or $index -lt 1 -or $index -gt 15) {
                throw "custom_attributes key '$key' is invalid: Exchange has custom attributes 1 through 15, so every key must be a number from 1 to 15, written as a string."
            }
            $splat["CustomAttribute$index"] = [string]$custom[$key]
        }
    }

    # The escape hatch goes on last so it can override anything above.
    foreach ($entry in (ConvertTo-EXOSplat -Value $InputData['additional_parameters']).GetEnumerator()) {
        $splat[$entry.Key] = $entry.Value
    }

    return $splat
}

function global:Get-EXOCASDefault {
    # Exchange Online's default for each client access setting cas_mailbox can
    # manage, as a map of manifest attribute name -> @(Set-CASMailbox parameter,
    # default value). Used both to build the Set-CASMailbox splat and, on
    # destroy, to revert only the settings this resource actually managed.
    #
    # $null is a meaningful default, not "unknown": it is how Exchange records
    # "this mailbox inherits the organisation or tenant setting".
    [CmdletBinding()]
    param()

    return [ordered]@{
        activesync_enabled                  = @('ActiveSyncEnabled', $true)
        owa_enabled                         = @('OWAEnabled', $true)
        owa_for_devices_enabled             = @('OWAforDevicesEnabled', $true)
        pop_enabled                         = @('PopEnabled', $true)
        imap_enabled                        = @('ImapEnabled', $true)
        mapi_enabled                        = @('MAPIEnabled', $true)
        ews_enabled                         = @('EwsEnabled', $null)
        pop_use_protocol_defaults           = @('PopUseProtocolDefaults', $true)
        imap_use_protocol_defaults          = @('ImapUseProtocolDefaults', $true)
        smtp_client_authentication_disabled = @('SmtpClientAuthenticationDisabled', $null)
        activesync_mailbox_policy           = @('ActiveSyncMailboxPolicy', 'Default')
        owa_mailbox_policy                  = @('OwaMailboxPolicy', 'OwaMailboxPolicy-Default')
        activesync_allowed_device_ids       = @('ActiveSyncAllowedDeviceIDs', $null)
        activesync_blocked_device_ids       = @('ActiveSyncBlockedDeviceIDs', $null)
        ews_allow_outlook                   = @('EwsAllowOutlook', $null)
        ews_allow_mac_outlook               = @('EwsAllowMacOutlook', $null)
        ews_application_access_policy       = @('EwsApplicationAccessPolicy', $null)
        ews_allow_list                      = @('EwsAllowList', $null)
        ews_block_list                      = @('EwsBlockList', $null)
    }
}

function global:New-EXOCASSetSplat {
    # Build the Set-CASMailbox splat for cas_mailbox, shared by create.ps1 and
    # update.ps1. Only settings present in $InputData are included: none of
    # these attributes declares a manifest default, so ContainsKey means "this
    # resource manages that setting" exactly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$InputData,
        [Parameter(Mandatory)][string]$Identity
    )

    $splat = @{
        Identity      = $Identity
        Confirm       = $false
        ErrorAction   = 'Stop'
        WarningAction = 'SilentlyContinue'
    }

    $collections = @(
        'activesync_allowed_device_ids',
        'activesync_blocked_device_ids',
        'ews_allow_list',
        'ews_block_list'
    )

    foreach ($entry in (Get-EXOCASDefault).GetEnumerator()) {
        $key = $entry.Key
        $parameter = $entry.Value[0]
        if (-not $InputData.ContainsKey($key)) { continue }
        if ($null -eq $InputData[$key]) { continue }

        if ($collections -contains $key) {
            $splat[$parameter] = [string[]]@($InputData[$key] | ForEach-Object { [string]$_ })
        }
        else {
            $splat[$parameter] = $InputData[$key]
        }
    }

    # The escape hatch goes on last so it can override anything above.
    foreach ($entry in (ConvertTo-EXOSplat -Value $InputData['additional_parameters']).GetEnumerator()) {
        $splat[$entry.Key] = $entry.Value
    }

    return $splat
}

function global:ConvertTo-EXOCASState {
    # The equivalent projection for cas_mailbox. These mirrors are the only
    # drift Terraform can see: the engine refreshes computed attributes from
    # read.ps1 and never refreshes config attributes.
    [CmdletBinding()]
    param([object]$CASMailbox, [Parameter(Mandatory)][string]$Id)

    if (-not $CASMailbox) { return }

    @{
        id                                            = $Id
        external_directory_object_id                  = [string]$CASMailbox.ExternalDirectoryObjectId
        effective_primary_smtp_address                = [string]$CASMailbox.PrimarySmtpAddress
        effective_display_name                        = [string]$CASMailbox.DisplayName
        effective_activesync_enabled                  = (ConvertTo-EXONullableBool -Value $CASMailbox.ActiveSyncEnabled)
        effective_owa_enabled                         = (ConvertTo-EXONullableBool -Value $CASMailbox.OWAEnabled)
        effective_pop_enabled                         = (ConvertTo-EXONullableBool -Value $CASMailbox.PopEnabled)
        effective_imap_enabled                        = (ConvertTo-EXONullableBool -Value $CASMailbox.ImapEnabled)
        effective_mapi_enabled                        = (ConvertTo-EXONullableBool -Value $CASMailbox.MAPIEnabled)
        effective_ews_enabled                         = (ConvertTo-EXONullableBool -Value $CASMailbox.EwsEnabled)
        effective_smtp_client_authentication_disabled = (ConvertTo-EXONullableBool -Value $CASMailbox.SmtpClientAuthenticationDisabled)
        effective_activesync_mailbox_policy           = [string]$CASMailbox.ActiveSyncMailboxPolicy
        effective_owa_mailbox_policy                  = [string]$CASMailbox.OwaMailboxPolicy
        effective_activesync_blocked_device_ids       = (ConvertTo-EXOStringArray -Value $CASMailbox.ActiveSyncBlockedDeviceIDs)
        effective_activesync_allowed_device_ids       = (ConvertTo-EXOStringArray -Value $CASMailbox.ActiveSyncAllowedDeviceIDs)
    }
}
