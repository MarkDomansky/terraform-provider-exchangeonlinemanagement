# Shared test doubles for the Exchange Online cmdlets.
#
# Why stub functions rather than Pester's Mock: the CRUD scripts are executed by
# the ScriptUnit harness with [scriptblock]::Create + & INSIDE the harness
# module, so a plain `Mock Get-Mailbox { }` in a test file is never seen by the
# script and the test passes for the wrong reason. Functions registered at
# global scope are visible from both the test's scope (where startup.ps1 is
# dot-sourced) and the harness module's scope, so one mechanism covers both.
#
# Failures are always simulated with `throw`, never Write-Error: the engine
# fails any operation that writes to the error stream, and a mock body's
# Write-Error ignores -ErrorAction entirely.

$ErrorActionPreference = 'Stop'

# The cmdlets the provider calls, with the parameters its scripts actually pass
# named explicitly so tests can assert on them. Anything else (the
# additional_parameters escape hatch, CustomAttribute1..15) lands in $Extra and
# is parsed back out by ConvertFrom-EXOStubArgument.
$script:StubCommands = @{
    'Get-Mailbox'               = @('Identity')
    'New-Mailbox'               = @('Name', 'Alias', 'DisplayName', 'Shared', 'Room', 'Equipment', 'MicrosoftOnlineServicesID', 'Password')
    'Set-Mailbox'               = @('Identity', 'Name', 'Alias', 'DisplayName', 'WindowsEmailAddress', 'Type', 'EmailAddresses', 'GrantSendOnBehalfTo', 'HiddenFromAddressListsEnabled', 'RetentionPolicy', 'LitigationHoldEnabled', 'LitigationHoldDuration', 'IssueWarningQuota', 'ProhibitSendQuota', 'ProhibitSendReceiveQuota', 'MaxSendSize', 'MaxReceiveSize', 'ForwardingSmtpAddress', 'DeliverToMailboxAndForward', 'ResourceCapacity')
    'Remove-Mailbox'            = @('Identity', 'PermanentlyDelete')
    'Get-CASMailbox'            = @('Identity')
    'Set-CASMailbox'            = @('Identity', 'ActiveSyncEnabled', 'OWAEnabled', 'OWAforDevicesEnabled', 'PopEnabled', 'ImapEnabled', 'MAPIEnabled', 'EwsEnabled', 'PopUseProtocolDefaults', 'ImapUseProtocolDefaults', 'SmtpClientAuthenticationDisabled', 'ActiveSyncMailboxPolicy', 'OwaMailboxPolicy', 'ActiveSyncAllowedDeviceIDs', 'ActiveSyncBlockedDeviceIDs', 'EwsAllowOutlook', 'EwsAllowMacOutlook', 'EwsApplicationAccessPolicy', 'EwsAllowList', 'EwsBlockList')
    'Connect-ExchangeOnline'    = @('AppId', 'Organization', 'ExchangeEnvironmentName', 'ShowBanner', 'SkipLoadingFormatData', 'CertificateThumbprint', 'CertificateFilePath', 'CertificatePassword', 'CommandName')
    'Disconnect-ExchangeOnline' = @()
}

function ConvertFrom-EXOStubArgument {
    # ValueFromRemainingArguments hands back alternating "-Name:" / value
    # tokens. Turn them back into a hashtable.
    param([object[]]$Tokens)

    $extra = @{}
    if (-not $Tokens) { return $extra }

    $name = $null
    foreach ($token in $Tokens) {
        if ($null -ne $name) {
            $extra[$name] = $token
            $name = $null
            continue
        }
        $text = [string]$token
        if ($text -match '^-(?<n>[A-Za-z_][A-Za-z0-9_]*):?$') {
            $name = $Matches['n']
        }
    }
    # A trailing name with no value is a switch given on its own.
    if ($null -ne $name) { $extra[$name] = $true }
    return $extra
}

function Initialize-EXOStub {
    <#
    .SYNOPSIS
        Register the Exchange Online cmdlet stubs at global scope and reset the
        recorded call log. Call this from BeforeEach so each test starts clean.
    #>
    [CmdletBinding()]
    param()

    $global:EXOCalls = [System.Collections.ArrayList]::new()
    $global:EXOBehavior = @{}

    foreach ($entry in $script:StubCommands.GetEnumerator()) {
        $command = $entry.Key
        $parameters = $entry.Value

        $declarations = @($parameters | ForEach-Object { "        `$$_" }) -join ",`n"
        if ($declarations) { $declarations += ",`n" }

        # SupportsShouldProcess makes -Confirm a common parameter, so the
        # provider's mandatory `Confirm = $false` binds instead of landing in
        # $Extra. ErrorAction/WarningAction come from CmdletBinding.
        $body = @"
[CmdletBinding(SupportsShouldProcess)]
param(
$declarations        [Parameter(ValueFromRemainingArguments)]`$Extra
)

`$captured = @{}
foreach (`$pair in `$PSBoundParameters.GetEnumerator()) {
    if (`$pair.Key -eq 'Extra') { continue }
    `$captured[`$pair.Key] = `$pair.Value
}
foreach (`$pair in (ConvertFrom-EXOStubArgument -Tokens `$Extra).GetEnumerator()) {
    `$captured[`$pair.Key] = `$pair.Value
}

`$null = `$global:EXOCalls.Add([pscustomobject]@{ Command = '$command'; Parameters = `$captured })

if (`$global:EXOBehavior.ContainsKey('$command')) {
    & `$global:EXOBehavior['$command'] `$captured
}
"@
        Set-Item -Path "function:global:$command" -Value ([scriptblock]::Create($body)) -Force
    }
}

function Remove-EXOStub {
    <# .SYNOPSIS Unregister the stubs and clear the recorded state. #>
    [CmdletBinding()]
    param()

    foreach ($command in $script:StubCommands.Keys) {
        Remove-Item -Path "function:global:$command" -Force -ErrorAction SilentlyContinue
    }
    $global:EXOCalls = $null
    $global:EXOBehavior = $null
}

function Set-EXOBehavior {
    <#
    .SYNOPSIS
        Define what a stubbed cmdlet does. The body receives the captured
        parameter hashtable as $args[0]. Throw to simulate a failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $global:EXOBehavior[$Command] = $Body
}

function Get-EXOCall {
    <# .SYNOPSIS The recorded calls, optionally filtered to one cmdlet. #>
    [CmdletBinding()]
    param([string]$Command)

    $calls = @($global:EXOCalls)
    if ($Command) { $calls = @($calls | Where-Object { $_.Command -eq $Command }) }
    return $calls
}

function New-EXONotFoundBehavior {
    <#
    .SYNOPSIS
        A body that fails the way Exchange reports a missing recipient, so
        Test-EXONotFound recognises it and read.ps1 reports "gone".
    #>
    [CmdletBinding()]
    param()
    return { throw "The operation couldn't be performed because object 'missing' couldn't be found on 'DB.contoso.com'." }
}

function New-EXOThrottledBehavior {
    <#
    .SYNOPSIS
        A body that fails the way a throttled or expired-token call does. This
        must NOT be mistaken for "not found" - that would make Terraform destroy
        and recreate a live mailbox.
    #>
    [CmdletBinding()]
    param()
    return { throw 'The operation was throttled: too many concurrent requests (429).' }
}

function New-EXOFakeMailbox {
    <# .SYNOPSIS A stand-in for a Get-Mailbox result. #>
    [CmdletBinding()]
    param(
        [string]$Guid = '11111111-1111-1111-1111-111111111111',
        [string]$Name = 'sales',
        [string]$DisplayName = 'Sales',
        [string]$Alias = 'sales',
        [string]$PrimarySmtpAddress = 'sales@contoso.com',
        [string]$UserPrincipalName = 'sales@contoso.com',
        [string]$RecipientTypeDetails = 'SharedMailbox',
        [string[]]$EmailAddresses = @('SMTP:sales@contoso.com'),
        [bool]$IsDirSynced = $false
    )

    $mailbox = [pscustomobject]@{
        Guid                          = $Guid
        ExchangeGuid                  = '22222222-2222-2222-2222-222222222222'
        ExternalDirectoryObjectId     = '33333333-3333-3333-3333-333333333333'
        Name                          = $Name
        DisplayName                   = $DisplayName
        Alias                         = $Alias
        PrimarySmtpAddress            = $PrimarySmtpAddress
        UserPrincipalName             = $UserPrincipalName
        EmailAddresses                = $EmailAddresses
        RecipientType                 = 'UserMailbox'
        RecipientTypeDetails          = $RecipientTypeDetails
        DistinguishedName             = "CN=$Name,OU=contoso"
        IsDirSynced                   = $IsDirSynced
        WhenCreatedUTC                = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
        HiddenFromAddressListsEnabled = $false
        LitigationHoldEnabled         = $false
        DeliverToMailboxAndForward    = $false
        ForwardingSmtpAddress         = ''
        RetentionPolicy               = ''
        IssueWarningQuota             = '49 GB (52,613,349,376 bytes)'
        ProhibitSendQuota             = '49.5 GB (53,150,220,288 bytes)'
        ProhibitSendReceiveQuota      = '50 GB (53,687,091,200 bytes)'
        MaxSendSize                   = '35 MB (36,700,160 bytes)'
        MaxReceiveSize                = '36 MB (37,748,736 bytes)'
    }
    foreach ($index in 1..15) {
        $mailbox | Add-Member -NotePropertyName "CustomAttribute$index" -NotePropertyValue ''
    }
    return $mailbox
}

function New-EXOFakeCASMailbox {
    <# .SYNOPSIS A stand-in for a Get-CASMailbox result. #>
    [CmdletBinding()]
    param(
        [string]$Guid = '11111111-1111-1111-1111-111111111111',
        [object]$OWAEnabled = $true,
        [object]$PopEnabled = $true,
        [object]$ImapEnabled = $true,
        [object]$ActiveSyncEnabled = $true,
        [object]$EwsEnabled = $null,
        [object]$SmtpClientAuthenticationDisabled = $null,
        [string]$PrimarySmtpAddress = 'sales@contoso.com'
    )

    return [pscustomobject]@{
        Guid                             = $Guid
        ExternalDirectoryObjectId        = '33333333-3333-3333-3333-333333333333'
        PrimarySmtpAddress               = $PrimarySmtpAddress
        DisplayName                      = 'Sales'
        ActiveSyncEnabled                = $ActiveSyncEnabled
        OWAEnabled                       = $OWAEnabled
        OWAforDevicesEnabled             = $true
        PopEnabled                       = $PopEnabled
        ImapEnabled                      = $ImapEnabled
        MAPIEnabled                      = $true
        EwsEnabled                       = $EwsEnabled
        PopUseProtocolDefaults           = $true
        ImapUseProtocolDefaults          = $true
        SmtpClientAuthenticationDisabled = $SmtpClientAuthenticationDisabled
        ActiveSyncMailboxPolicy          = 'Default'
        OwaMailboxPolicy                 = 'OwaMailboxPolicy-Default'
        ActiveSyncAllowedDeviceIDs       = @()
        ActiveSyncBlockedDeviceIDs       = @()
    }
}

function New-EXOProviderConfig {
    <#
    .SYNOPSIS
        A minimal, valid $global:ProviderData.Config for startup.ps1. Splat
        overrides in to vary one setting.
    .NOTES
        Tests dot-source provider/scripts/startup.ps1 themselves rather than
        going through a helper here: dot-sourcing from inside this module would
        run it in module scope, where a test's Pester mocks do not reach.
    #>
    [CmdletBinding()]
    param([hashtable]$Override = @{})

    # certificate_path rather than certificate_thumbprint so the default works
    # on Linux and macOS too (the thumbprint branch is Windows-only by design).
    # startup.ps1 checks the file exists before handing it to the stubbed
    # Connect-ExchangeOnline, so a placeholder has to be on disk; its contents
    # never matter.
    if (-not $script:PlaceholderCertificate -or -not (Test-Path -LiteralPath $script:PlaceholderCertificate)) {
        $script:PlaceholderCertificate = Join-Path ([System.IO.Path]::GetTempPath()) 'exo-provider-unit-tests.pfx'
        Set-Content -LiteralPath $script:PlaceholderCertificate -Value 'placeholder' -NoNewline
    }

    $config = @{
        organization     = 'contoso.onmicrosoft.com'
        app_id           = '44444444-4444-4444-4444-444444444444'
        certificate_path = $script:PlaceholderCertificate
    }
    foreach ($pair in $Override.GetEnumerator()) { $config[$pair.Key] = $pair.Value }
    return $config
}

Export-ModuleMember -Function Initialize-EXOStub, Remove-EXOStub, Set-EXOBehavior, Get-EXOCall,
New-EXONotFoundBehavior, New-EXOThrottledBehavior, New-EXOFakeMailbox, New-EXOFakeCASMailbox,
New-EXOProviderConfig, ConvertFrom-EXOStubArgument
