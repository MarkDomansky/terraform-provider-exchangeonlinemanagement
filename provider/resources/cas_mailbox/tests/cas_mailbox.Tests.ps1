# Script-level unit tests for the 'cas_mailbox' resource.
#
# See provider/resources/mailbox/tests/mailbox.Tests.ps1 for why the Exchange
# cmdlets are replaced with global stub functions rather than Pester mocks.
#
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module (Join-Path $script:RepoRoot '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'tests' 'support' 'EXOTestStubs.psm1') -Force

    $script:Kind = 'resources'
    $script:Name = 'cas_mailbox'
    $script:Guid = '11111111-1111-1111-1111-111111111111'

    function Initialize-EXOTest {
        Initialize-EXOStub
        $global:ProviderData = @{ Config = New-EXOProviderConfig }
        . (Join-Path $script:RepoRoot 'provider' 'scripts' 'startup.ps1')

        Initialize-EXOStub    # discard startup's own Connect-ExchangeOnline call
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body { New-EXOFakeCASMailbox }
    }

    function Get-SetCASParameter {
        $calls = @(Get-EXOCall -Command 'Set-CASMailbox')
        if ($calls.Count -eq 0) { return $null }
        return $calls[-1].Parameters
    }
}

AfterAll {
    Remove-EXOStub
    $global:ProviderData = $null
    $global:EXOProviderState = $null
}

Describe 'cas_mailbox manifest' {
    BeforeEach { Initialize-EXOTest }

    It 'requires an identity and declares no requires_replace' {
        # Same reasoning as the mailbox resource: post-import state has null
        # config attributes, so requires_replace would plan a destroy.
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $manifest.attributes.identity.required | Should -BeTrue
        foreach ($property in $manifest.attributes.PSObject.Properties) {
            $property.Value.requires_replace | Should -Not -BeTrue -Because "$($property.Name) must not force replacement"
        }
    }

    It 'gives revert_on_destroy the only default' {
        # Load-bearing: delete.ps1 uses $InputData.ContainsKey(<setting>) to
        # decide what this resource actually managed, and a manifest default
        # would make every key present and so revert everything.
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $withDefaults = @(
            $manifest.attributes.PSObject.Properties |
                Where-Object { $null -ne $_.Value.default } |
                ForEach-Object { $_.Name }
        )
        $withDefaults | Should -Be @('revert_on_destroy')
    }

    It '<_>.ps1 declares the engine param contract' -ForEach @('create', 'read', 'update', 'delete') {
        $path = Get-ResourceScriptPath -Kind $script:Kind -Name $script:Name -Action $_
        $params = @(Get-ScriptParameter -Script (Get-Content -LiteralPath $path -Raw))

        $params.Name | Should -Contain 'InputData'
        $params.Name | Should -Not -Contain 'Action'
        @($params | Where-Object { $_.Mandatory -and $_.Name -ne 'InputData' }) | Should -BeNullOrEmpty
    }
}

Describe 'cas_mailbox create' {
    BeforeEach { Initialize-EXOTest }

    It 'resolves the mailbox and keys the resource on its GUID' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            identity    = 'sales@contoso.com'
            owa_enabled = $false
        }

        $result.id | Should -Be $script:Guid
        (Get-EXOCall -Command 'Get-CASMailbox')[0].Parameters.Identity | Should -Be 'sales@contoso.com'
        # Subsequent calls use the GUID, so a rename cannot detach the resource.
        (Get-SetCASParameter).Identity | Should -Be $script:Guid
    }

    It 'explains that the mailbox must already exist' {
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body (New-EXONotFoundBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
                identity = 'nope@contoso.com'
            } } | Should -Throw -ExpectedMessage '*configures an existing mailbox*depends_on*'
    }

    It 'applies only the settings the practitioner configured' {
        # Omitting a setting must mean "not managed", never "set it to false".
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            identity    = 'sales@contoso.com'
            owa_enabled = $false
            pop_enabled = $false
        } | Out-Null

        $set = Get-SetCASParameter
        $set.OWAEnabled | Should -BeFalse
        $set.PopEnabled | Should -BeFalse
        $set.ContainsKey('ImapEnabled') | Should -BeFalse
        $set.ContainsKey('ActiveSyncEnabled') | Should -BeFalse
        $set.Confirm | Should -BeFalse
    }

    It 'skips Set-CASMailbox entirely when nothing is configured' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            identity = 'sales@contoso.com'
        } | Out-Null

        Get-EXOCall -Command 'Set-CASMailbox' | Should -BeNullOrEmpty
    }

    It 'passes device ID lists as arrays' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            identity                      = 'sales@contoso.com'
            activesync_blocked_device_ids = @('DEVICE1')
        } | Out-Null

        , (Get-SetCASParameter).ActiveSyncBlockedDeviceIDs | Should -BeOfType [string[]]
    }

    It 'lets additional_parameters through and lets it win' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            identity              = 'sales@contoso.com'
            owa_enabled           = $true
            additional_parameters = @{ ShowGalAsDefaultView = $false; OWAEnabled = $false }
        } | Out-Null

        $set = Get-SetCASParameter
        $set.ShowGalAsDefaultView | Should -BeFalse
        $set.OWAEnabled | Should -BeFalse
    }
}

Describe 'cas_mailbox read' {
    BeforeEach { Initialize-EXOTest }

    It 'mirrors the live settings into the effective_* attributes' {
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body { New-EXOFakeCASMailbox -OWAEnabled $false }

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            id       = $script:Guid
            identity = 'sales@contoso.com'
        }
        $result.effective_owa_enabled | Should -BeFalse
        $result.effective_primary_smtp_address | Should -Be 'sales@contoso.com'
    }

    It 'keeps an unset nullable setting null rather than reporting it as false' {
        # [bool]$null is $false, which would claim SMTP AUTH is explicitly
        # enabled when the mailbox is actually inheriting the tenant setting.
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid }
        $result.effective_smtp_client_authentication_disabled | Should -BeNullOrEmpty
        $result.effective_ews_enabled | Should -BeNullOrEmpty
    }

    It 'emits nothing when the mailbox is gone' {
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body (New-EXONotFoundBehavior)

        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid } |
            Should -BeNullOrEmpty
    }

    It 'does NOT treat a throttled call as a missing mailbox' {
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body (New-EXOThrottledBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid } } |
            Should -Throw -ExpectedMessage '*throttled*'
    }

    It 'emits exactly the computed attributes the manifest declares' {
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $computed = @(
            $manifest.attributes.PSObject.Properties |
                Where-Object { $_.Value.computed } | ForEach-Object { $_.Name }
        )

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid }
        $emitted = @($result.Keys | Where-Object { $_ -ne 'id' })

        foreach ($name in $computed) { $emitted | Should -Contain $name }
        foreach ($name in $emitted) { $computed | Should -Contain $name }
    }
}

Describe 'cas_mailbox update' {
    BeforeEach { Initialize-EXOTest }

    It 'applies changed settings in place' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
            id           = $script:Guid
            identity     = 'sales@contoso.com'
            imap_enabled = $false
        }

        (Get-SetCASParameter).ImapEnabled | Should -BeFalse
        $result.id | Should -Be $script:Guid
    }

    It 'refuses to be repointed at a different mailbox' {
        # Client access settings belong to one specific mailbox, so silently
        # following the identity would abandon the original's settings.
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body {
            param($p)
            if ($p.Identity -eq 'other@contoso.com') {
                return New-EXOFakeCASMailbox -Guid '99999999-9999-9999-9999-999999999999' -PrimarySmtpAddress 'other@contoso.com'
            }
            New-EXOFakeCASMailbox
        }

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
                id       = $script:Guid
                identity = 'other@contoso.com'
            } } | Should -Throw -ExpectedMessage '*different mailbox*-replace*'
    }

    It 'accepts an identity that still resolves to the same mailbox' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
                id       = $script:Guid
                identity = 'sales@contoso.com'
            } } | Should -Not -Throw
    }
}

Describe 'cas_mailbox destroy' {
    BeforeEach { Initialize-EXOTest }

    It 'leaves Exchange untouched by default' {
        # The documented default: destroy drops state, hardening survives.
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id          = $script:Guid
            identity    = 'sales@contoso.com'
            owa_enabled = $false
        }

        Get-EXOCall -Command 'Set-CASMailbox' | Should -BeNullOrEmpty
        $result.id | Should -Be $script:Guid
    }

    It 'reverts only the settings this resource managed' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id                = $script:Guid
            identity          = 'sales@contoso.com'
            revert_on_destroy = $true
            owa_enabled       = $false
            pop_enabled       = $false
        } | Out-Null

        $revert = Get-SetCASParameter
        $revert.OWAEnabled | Should -BeTrue
        $revert.PopEnabled | Should -BeTrue
        # Never configured here, so never touched on the way out.
        $revert.ContainsKey('ImapEnabled') | Should -BeFalse
        $revert.ContainsKey('MAPIEnabled') | Should -BeFalse
    }

    It 'reverts a nullable setting to null, not to false' {
        # $null is Exchange's "inherit the tenant setting" state and is the
        # correct revert target; $false would actively enable SMTP AUTH.
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id                                  = $script:Guid
            identity                            = 'sales@contoso.com'
            revert_on_destroy                   = $true
            smtp_client_authentication_disabled = $true
        } | Out-Null

        $revert = Get-SetCASParameter
        # ContainsKey and the value are separate assertions on purpose: a plain
        # truthiness check would pass even if the key were missing entirely.
        $revert.ContainsKey('SmtpClientAuthenticationDisabled') | Should -BeTrue
        $revert.SmtpClientAuthenticationDisabled | Should -BeNullOrEmpty
    }

    It 'lets revert_values override the built-in defaults table' {
        # The right default for a policy name is tenant-specific, and the
        # pre-existing value cannot be snapshot: computed attributes are not
        # passed to a delete script.
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id                 = $script:Guid
            identity           = 'sales@contoso.com'
            revert_on_destroy  = $true
            owa_mailbox_policy = 'Contoso-Strict'
            revert_values      = @{ OwaMailboxPolicy = 'Contoso-Baseline' }
        } | Out-Null

        (Get-SetCASParameter).OwaMailboxPolicy | Should -Be 'Contoso-Baseline'
    }

    It 'is idempotent when the mailbox is already gone' {
        Set-EXOBehavior -Command 'Get-CASMailbox' -Body (New-EXONotFoundBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
                id                = $script:Guid
                identity          = 'sales@contoso.com'
                revert_on_destroy = $true
                owa_enabled       = $false
            } } | Should -Not -Throw
        Get-EXOCall -Command 'Set-CASMailbox' | Should -BeNullOrEmpty
    }

    It 'makes no call when revert is on but nothing was managed' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id                = $script:Guid
            identity          = 'sales@contoso.com'
            revert_on_destroy = $true
        } | Out-Null

        Get-EXOCall -Command 'Set-CASMailbox' | Should -BeNullOrEmpty
    }
}
