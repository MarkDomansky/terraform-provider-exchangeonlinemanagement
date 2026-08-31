# Script-level unit tests for the 'mailbox' resource.
#
# The CRUD scripts run in-process through the ScriptUnit harness - no terraform,
# no Go, no sidecar, no tenant. The Exchange cmdlets are replaced by global stub
# functions (see tests/support/EXOTestStubs.psm1 for why global functions rather
# than Pester's Mock), and startup.ps1 is dot-sourced for real so these tests
# exercise the actual shared helpers.
#
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module (Join-Path $script:RepoRoot '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'tests' 'support' 'EXOTestStubs.psm1') -Force

    $script:Kind = 'resources'
    $script:Name = 'mailbox'
    $script:Guid = '11111111-1111-1111-1111-111111111111'

    function Initialize-EXOTest {
        # Fresh stubs, the real shared helpers from startup.ps1, and the
        # happy-path Exchange responses. Call from each Describe's BeforeEach;
        # Pester 5 does not allow a BeforeEach at the root of a file.
        Initialize-EXOStub
        $global:ProviderData = @{ Config = New-EXOProviderConfig }
        . (Join-Path $script:RepoRoot 'provider' 'scripts' 'startup.ps1')

        Initialize-EXOStub    # discard startup's own Connect-ExchangeOnline call
        Set-EXOBehavior -Command 'New-Mailbox' -Body { [pscustomobject]@{ Guid = '11111111-1111-1111-1111-111111111111' } }
        Set-EXOBehavior -Command 'Get-Mailbox' -Body { New-EXOFakeMailbox }
    }

    function Get-SetMailboxParameter {
        $calls = @(Get-EXOCall -Command 'Set-Mailbox')
        if ($calls.Count -eq 0) { return $null }
        return $calls[-1].Parameters
    }
}

AfterAll {
    Remove-EXOStub
    $global:ProviderData = $null
    $global:EXOProviderState = $null
}

Describe 'mailbox manifest' {
    BeforeEach { Initialize-EXOTest }

    It 'declares the expected shape' {
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $manifest.version | Should -Be 1
        $manifest.attributes.name.required | Should -BeTrue
        $manifest.attributes.type.default | Should -Be 'shared'
        $manifest.attributes.password.sensitive | Should -BeTrue
        $manifest.attributes.exchange_guid.computed | Should -BeTrue
    }

    It 'marks no attribute requires_replace' {
        # Load-bearing, not stylistic. terraform import populates only 'id' and
        # the engine cannot write config attributes from a read script, so every
        # config attribute is null in post-import state. A requires_replace
        # attribute would therefore plan destroy-and-recreate of a live mailbox
        # on the first apply after any import. Immutable fields are guarded in
        # update.ps1 instead.
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        foreach ($property in $manifest.attributes.PSObject.Properties) {
            $property.Value.requires_replace | Should -Not -BeTrue -Because "$($property.Name) must not force replacement"
        }
    }

    It 'gives a default only to attributes whose "unset" state carries no meaning' {
        # A manifest default makes the key always present in $InputData, which
        # destroys ContainsKey as a "the practitioner configured this" signal.
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $withDefaults = @(
            $manifest.attributes.PSObject.Properties |
                Where-Object { $null -ne $_.Value.default } |
                ForEach-Object { $_.Name }
        )
        $withDefaults | Should -Be @('type', 'permanently_delete')
    }

    It 'does not declare the reserved id attribute' {
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $manifest.attributes.PSObject.Properties.Name | Should -Not -Contain 'id'
    }
}

Describe 'mailbox script contract' {
    BeforeEach { Initialize-EXOTest }

    It '<_>.ps1 declares the engine param contract' -ForEach @('create', 'read', 'update', 'delete') {
        $path = Get-ResourceScriptPath -Kind $script:Kind -Name $script:Name -Action $_
        $params = @(Get-ScriptParameter -Script (Get-Content -LiteralPath $path -Raw))

        $params.Name | Should -Contain 'InputData'
        # $Action arrives as an enclosing-scope variable; a parameter shadows it.
        $params.Name | Should -Not -Contain 'Action'
        # Nothing can supply a second mandatory parameter.
        @($params | Where-Object { $_.Mandatory -and $_.Name -ne 'InputData' }) | Should -BeNullOrEmpty
    }

    It '<_>.ps1 rejects an $InputData with no id' -ForEach @('read', 'update', 'delete') {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action $_ -InputData @{ name = 'sales' } } |
            Should -Throw -ExpectedMessage '*requires a non-empty $InputData.id*'
    }
}

Describe 'mailbox create' {
    BeforeEach { Initialize-EXOTest }

    It 'creates a shared mailbox and returns its GUID as the id' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name = 'sales'
            type = 'shared'
        }

        $result.id | Should -Be $script:Guid
        $new = (Get-EXOCall -Command 'New-Mailbox')[0].Parameters
        $new.Name | Should -Be 'sales'
        $new.Shared | Should -BeTrue
        $new.ContainsKey('Room') | Should -BeFalse
    }

    It 'uses the -<Switch> switch for type = <Type>' -ForEach @(
        @{ Type = 'room'; Switch = 'Room' }
        @{ Type = 'equipment'; Switch = 'Equipment' }
    ) {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name = 'room-1'
            type = $Type
        } | Out-Null

        (Get-EXOCall -Command 'New-Mailbox')[0].Parameters[$Switch] | Should -BeTrue
    }

    It 'refuses type = "user" without a UPN, and points at the supported path' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
                name = 'ann'; type = 'user'
            } } | Should -Throw -ExpectedMessage '*requires user_principal_name*Entra ID*'
    }

    It 'refuses type = "user" without a password' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
                name = 'ann'; type = 'user'; user_principal_name = 'ann@contoso.com'
            } } | Should -Throw -ExpectedMessage '*requires password*'
    }

    It 'passes a user mailbox password as a SecureString, never plaintext' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name                = 'ann'
            type                = 'user'
            user_principal_name = 'ann@contoso.com'
            password            = 'P@ssw0rd!'
        } | Out-Null

        $new = (Get-EXOCall -Command 'New-Mailbox')[0].Parameters
        $new.MicrosoftOnlineServicesID | Should -Be 'ann@contoso.com'
        $new.Password | Should -BeOfType [securestring]
        $new.Password | Should -Not -Be 'P@ssw0rd!'
    }

    It 'waits for the new mailbox to become readable before configuring it' {
        # Exchange Online returns from New-Mailbox before the mailbox is
        # addressable. Without the poll, creates fail after the mailbox exists,
        # leaving a real mailbox with no Terraform state.
        $script:attempts = 0
        Set-EXOBehavior -Command 'Get-Mailbox' -Body {
            $script:attempts++
            if ($script:attempts -lt 3) { throw "The operation couldn't be performed because object 'sales' couldn't be found." }
            New-EXOFakeMailbox
        }

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{ name = 'sales' }
        $result.id | Should -Be $script:Guid
        (Get-EXOCall -Command 'Get-Mailbox').Count | Should -BeGreaterOrEqual 3
    }

    It 'skips Set-Mailbox when nothing beyond the create-time attributes is configured' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name  = 'sales'
            alias = 'sales'
        } | Out-Null

        Get-EXOCall -Command 'Set-Mailbox' | Should -BeNullOrEmpty
    }

    It 'applies the remaining settings through Set-Mailbox' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name                      = 'sales'
            hidden_from_address_lists = $true
            max_send_size             = '35 MB'
            primary_smtp_address      = 'sales@contoso.com'
        } | Out-Null

        $set = Get-SetMailboxParameter
        $set.HiddenFromAddressListsEnabled | Should -BeTrue
        $set.MaxSendSize | Should -Be '35 MB'
        # Applied post-create; Set-Mailbox uses -WindowsEmailAddress in EXO.
        $set.WindowsEmailAddress | Should -Be 'sales@contoso.com'
        # Mandatory throughout: a confirmation prompt would hang the sidecar.
        $set.Confirm | Should -BeFalse
    }
}

Describe 'mailbox settings splat' {
    BeforeEach { Initialize-EXOTest }

    It 'maps custom_attributes keys onto -CustomAttributeN' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name              = 'sales'
            custom_attributes = @{ '3' = 'finance'; '15' = 'eu' }
        } | Out-Null

        $set = Get-SetMailboxParameter
        $set.CustomAttribute3 | Should -Be 'finance'
        $set.CustomAttribute15 | Should -Be 'eu'
    }

    It 'rejects a custom_attributes key outside 1..15' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
                name              = 'sales'
                custom_attributes = @{ '16' = 'nope' }
            } } | Should -Throw -ExpectedMessage '*custom attributes 1 through 15*'
    }

    It 'lets additional_parameters reach the cmdlet and win over a modelled attribute' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name                  = 'sales'
            display_name          = 'Sales'
            max_send_size         = '35 MB'
            additional_parameters = @{ Office = 'HQ'; MaxSendSize = '100 MB' }
        } | Out-Null

        $set = Get-SetMailboxParameter
        $set.Office | Should -Be 'HQ'
        $set.MaxSendSize | Should -Be '100 MB'
    }

    It 'keeps a single-element set as an array' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name            = 'sales'
            email_addresses = @('SMTP:sales@contoso.com')
        } | Out-Null

        , (Get-SetMailboxParameter).EmailAddresses | Should -BeOfType [string[]]
    }

    It 'omits settings the practitioner did not configure' {
        # Absent means "not managed", never "set it to false".
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{
            name          = 'sales'
            max_send_size = '35 MB'
        } | Out-Null

        $set = Get-SetMailboxParameter
        $set.ContainsKey('HiddenFromAddressListsEnabled') | Should -BeFalse
        $set.ContainsKey('RetentionPolicy') | Should -BeFalse
    }
}

Describe 'mailbox read' {
    BeforeEach { Initialize-EXOTest }

    It 'projects the mailbox onto the computed attributes' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            id   = $script:Guid
            name = 'sales'
        }

        $result.id | Should -Be $script:Guid
        $result.effective_primary_smtp_address | Should -Be 'sales@contoso.com'
        $result.recipient_type_details | Should -Be 'SharedMailbox'
        $result.is_directory_synced | Should -BeOfType [bool]
        # ISO 8601, not the culture-dependent .ToString() the sidecar would fall
        # back to - otherwise state churns between machines.
        $result.when_created | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'returns computed sets as arrays even with one element' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid }
        , $result.effective_email_addresses | Should -BeOfType [array]
    }

    It 'emits nothing when the mailbox is gone, so Terraform plans a recreate' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXONotFoundBehavior)

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid }
        $result | Should -BeNullOrEmpty
    }

    It 'does NOT treat a throttled call as a missing mailbox' {
        # The failure mode this guards against: a 429 or an expired token read
        # as "gone" would make Terraform destroy and recreate a live mailbox.
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXOThrottledBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid } } |
            Should -Throw -ExpectedMessage '*throttled*'
    }

    It 'passes the id through unchanged, whatever form it took' {
        # read.ps1 cannot renormalise id: the engine never re-sets it, so an
        # id supplied by terraform import stays as-is forever.
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            id = 'sales@contoso.com'
        }
        $result.id | Should -Be 'sales@contoso.com'
        (Get-EXOCall -Command 'Get-Mailbox')[0].Parameters.Identity | Should -Be 'sales@contoso.com'
    }
}

Describe 'mailbox update' {
    BeforeEach { Initialize-EXOTest }

    It 'applies changed settings in place' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
            id           = $script:Guid
            name         = 'sales'
            display_name = 'Sales Team'
        }

        (Get-SetMailboxParameter).DisplayName | Should -Be 'Sales Team'
        $result.id | Should -Be $script:Guid
    }

    It 'refuses a user_principal_name change and names the alternative' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
                id                  = $script:Guid
                name                = 'sales'
                user_principal_name = 'new@contoso.com'
            } } | Should -Throw -ExpectedMessage '*not supported*Entra ID*-replace*'
    }

    It 'accepts a matching user_principal_name, so the first apply after import is a no-op' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
                id                  = $script:Guid
                name                = 'sales'
                user_principal_name = 'sales@contoso.com'
            } } | Should -Not -Throw
    }

    It 'converts the mailbox type in place when it changed' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body { New-EXOFakeMailbox -RecipientTypeDetails 'SharedMailbox' }

        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
            id   = $script:Guid
            name = 'sales'
            type = 'room'
        } | Out-Null

        @(Get-EXOCall -Command 'Set-Mailbox' | Where-Object { $_.Parameters.Type -eq 'Room' }) | Should -Not -BeNullOrEmpty
    }

    It 'does not convert the type when it already matches' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body { New-EXOFakeMailbox -RecipientTypeDetails 'SharedMailbox' }

        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
            id   = $script:Guid
            name = 'sales'
            type = 'shared'
        } | Out-Null

        @(Get-EXOCall -Command 'Set-Mailbox' | Where-Object { $_.Parameters.ContainsKey('Type') }) | Should -BeNullOrEmpty
    }

    It 'never sends the creation password to Set-Mailbox' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
            id       = $script:Guid
            name     = 'sales'
            password = 'P@ssw0rd!'
            alias    = 'sales2'
        } | Out-Null

        (Get-SetMailboxParameter).ContainsKey('Password') | Should -BeFalse
    }

    It 'fails clearly when the mailbox has disappeared' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXONotFoundBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{
                id = $script:Guid; name = 'sales'
            } } | Should -Throw -ExpectedMessage '*no longer exists*'
    }
}

Describe 'mailbox delete' {
    BeforeEach { Initialize-EXOTest }

    It 'removes the mailbox without prompting' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id   = $script:Guid
            name = 'sales'
        } | Out-Null

        $remove = (Get-EXOCall -Command 'Remove-Mailbox')[0].Parameters
        $remove.Identity | Should -Be $script:Guid
        $remove.Confirm | Should -BeFalse
        $remove.ContainsKey('PermanentlyDelete') | Should -BeFalse
    }

    It 'passes -PermanentlyDelete when asked' {
        Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
            id                 = $script:Guid
            name               = 'sales'
            permanently_delete = $true
        } | Out-Null

        (Get-EXOCall -Command 'Remove-Mailbox')[0].Parameters.PermanentlyDelete | Should -BeTrue
    }

    It 'is idempotent when the mailbox is already gone' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXONotFoundBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
                id = $script:Guid; name = 'sales'
            } } | Should -Not -Throw
        Get-EXOCall -Command 'Remove-Mailbox' | Should -BeNullOrEmpty
    }

    It 'still surfaces a genuine failure rather than treating it as "already gone"' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXOThrottledBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action delete -InputData @{
                id = $script:Guid; name = 'sales'
            } } | Should -Throw -ExpectedMessage '*throttled*'
    }
}

Describe 'mailbox computed attribute parity' {
    BeforeEach { Initialize-EXOTest }

    It 'create, read and update emit the same computed keys' {
        # Guards against the three scripts drifting apart: a key missing from
        # one of them silently becomes null in state after that operation.
        $created = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action create -InputData @{ name = 'sales' }
        $read = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid }
        $updated = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action update -InputData @{ id = $script:Guid; name = 'sales' }

        $readKeys = ($read.Keys | Sort-Object) -join ','
        ($created.Keys | Sort-Object) -join ',' | Should -Be $readKeys
        ($updated.Keys | Sort-Object) -join ',' | Should -Be $readKeys
    }

    It 'emits every computed attribute the manifest declares, and nothing undeclared' {
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $computed = @(
            $manifest.attributes.PSObject.Properties |
                Where-Object { $_.Value.computed } | ForEach-Object { $_.Name }
        )

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ id = $script:Guid }
        $emitted = @($result.Keys | Where-Object { $_ -ne 'id' })

        # A missing computed key is only a TF_LOG warning at runtime; catch it here.
        foreach ($name in $computed) { $emitted | Should -Contain $name }
        # An undeclared key is silently ignored at runtime; catch typos here.
        foreach ($name in $emitted) { $computed | Should -Contain $name }
    }
}
