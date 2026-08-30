# Script-level unit tests for the 'mailbox' data source.
#
# See provider/resources/mailbox/tests/mailbox.Tests.ps1 for why the Exchange
# cmdlets are replaced with global stub functions rather than Pester mocks.
#
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module (Join-Path $script:RepoRoot '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'tests' 'support' 'EXOTestStubs.psm1') -Force

    $script:Kind = 'data-sources'
    $script:Name = 'mailbox'

    function Initialize-EXOTest {
        Initialize-EXOStub
        $global:ProviderData = @{ Config = New-EXOProviderConfig }
        . (Join-Path $script:RepoRoot 'provider' 'scripts' 'startup.ps1')

        Initialize-EXOStub    # discard startup's own Connect-ExchangeOnline call
        Set-EXOBehavior -Command 'Get-Mailbox' -Body { New-EXOFakeMailbox }
    }
}

AfterAll {
    Remove-EXOStub
    $global:ProviderData = $null
    $global:EXOProviderState = $null
}

Describe 'mailbox data source manifest' {
    BeforeEach { Initialize-EXOTest }

    It 'declares all three lookups as optional' {
        # Terraform has no "exactly one of" in this manifest format, so all
        # three must be optional and read.ps1 enforces the rule.
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        foreach ($name in 'user_principal_name', 'object_id', 'email_address') {
            $manifest.attributes.$name.optional | Should -BeTrue
            $manifest.attributes.$name.computed | Should -Not -BeTrue
        }
    }

    It 'has no computed attribute colliding with a lookup attribute' {
        # An attribute cannot be both config and computed in this engine, so a
        # collision would be a load error - catch it here with a clear message.
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $config = @($manifest.attributes.PSObject.Properties | Where-Object { -not $_.Value.computed } | ForEach-Object { $_.Name })
        $computed = @($manifest.attributes.PSObject.Properties | Where-Object { $_.Value.computed } | ForEach-Object { $_.Name })

        foreach ($name in $config) { $computed | Should -Not -Contain $name }
    }

    It 'read.ps1 declares the engine param contract and expects no id' {
        $path = Get-ResourceScriptPath -Kind $script:Kind -Name $script:Name -Action read
        $params = @(Get-ScriptParameter -Script (Get-Content -LiteralPath $path -Raw))

        $params.Name | Should -Contain 'InputData'
        $params.Name | Should -Not -Contain 'Action'
        @($params | Where-Object { $_.Mandatory -and $_.Name -ne 'InputData' }) | Should -BeNullOrEmpty
        # A data source carries no state, so unlike a resource's read.ps1 this
        # one must not assert on an id.
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
                user_principal_name = 'sales@contoso.com'
            } } | Should -Not -Throw
    }
}

Describe 'mailbox data source lookup' {
    BeforeEach { Initialize-EXOTest }

    It 'looks the mailbox up by <Attribute>' -ForEach @(
        @{ Attribute = 'user_principal_name'; Value = 'sales@contoso.com' }
        @{ Attribute = 'object_id'; Value = '33333333-3333-3333-3333-333333333333' }
        @{ Attribute = 'email_address'; Value = 'sales@contoso.com' }
    ) {
        # Get-Mailbox -Identity resolves all three natively, so they share a path.
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{ $Attribute = $Value }

        $result.found | Should -BeTrue
        (Get-EXOCall -Command 'Get-Mailbox')[0].Parameters.Identity | Should -Be $Value
    }

    It 'requires a lookup attribute' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{} } |
            Should -Throw -ExpectedMessage '*exactly one of*none was set*'
    }

    It 'refuses two lookup attributes and names them' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
                user_principal_name = 'sales@contoso.com'
                email_address       = 'sales@contoso.com'
            } } | Should -Throw -ExpectedMessage '*exactly one of*ambiguous*'
    }

    It 'ignores a lookup attribute set to whitespace' {
        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
                user_principal_name = 'sales@contoso.com'
                email_address       = '   '
            } } | Should -Not -Throw
    }

    It 'reports found = false rather than failing when nothing matches' {
        # Emitting nothing would just null every attribute, which is
        # indistinguishable from a mailbox with no properties.
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXONotFoundBehavior)

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            user_principal_name = 'nope@contoso.com'
        }
        $result.found | Should -BeFalse
        $result.Keys | Should -Be @('found')
    }

    It 'does NOT report a throttled call as "not found"' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body (New-EXOThrottledBehavior)

        { Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
                user_principal_name = 'sales@contoso.com'
            } } | Should -Throw -ExpectedMessage '*throttled*'
    }
}

Describe 'mailbox data source output' {
    BeforeEach { Initialize-EXOTest }

    It 'projects the mailbox onto the declared attributes' {
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            user_principal_name = 'sales@contoso.com'
        }

        $result.mailbox_guid | Should -Be '11111111-1111-1111-1111-111111111111'
        $result.external_directory_object_id | Should -Be '33333333-3333-3333-3333-333333333333'
        $result.primary_smtp_address | Should -Be 'sales@contoso.com'
        $result.effective_user_principal_name | Should -Be 'sales@contoso.com'
        $result.recipient_type_details | Should -Be 'SharedMailbox'
        $result.when_created | Should -Match '^\d{4}-\d{2}-\d{2}T'
        , $result.email_addresses | Should -BeOfType [array]
    }

    It 'emits exactly the computed attributes the manifest declares' {
        $manifest = Get-ResourceManifest -Kind $script:Kind -Name $script:Name
        $computed = @(
            $manifest.attributes.PSObject.Properties |
                Where-Object { $_.Value.computed } | ForEach-Object { $_.Name }
        )

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            user_principal_name = 'sales@contoso.com'
        }

        foreach ($name in $computed) { $result.Keys | Should -Contain $name }
        foreach ($name in $result.Keys) { $computed | Should -Contain $name }
    }

    It 'drops empty custom attributes and keys the rest by number' {
        Set-EXOBehavior -Command 'Get-Mailbox' -Body {
            $mailbox = New-EXOFakeMailbox
            $mailbox.CustomAttribute3 = 'finance'
            $mailbox
        }

        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            user_principal_name = 'sales@contoso.com'
        }
        $result.custom_attributes['3'] | Should -Be 'finance'
        $result.custom_attributes.Keys | Should -Be @('3')
    }

    It 'builds mailbox_json as a nested hashtable' {
        # The sidecar passes hashtables through but calls .ToString() on
        # anything else, so a PSCustomObject would land in state as the literal
        # string "System.Management.Automation.PSCustomObject".
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            user_principal_name = 'sales@contoso.com'
        }

        $result.mailbox_json | Should -BeOfType [hashtable]
        $result.mailbox_json['DisplayName'] | Should -Be 'Sales'
    }

    It 'normalises every mailbox_json value to a JSON-safe type' {
        # Without this, a DateTime would be stringified with the machine's
        # culture and state would churn between refreshes and between machines.
        $result = Invoke-ResourceScript -Kind $script:Kind -Name $script:Name -Action read -InputData @{
            user_principal_name = 'sales@contoso.com'
        }

        # The types the sidecar carries through unchanged. Anything else gets
        # .ToString()'d, which is lossy and culture-dependent.
        foreach ($pair in $result.mailbox_json.GetEnumerator()) {
            if ($null -eq $pair.Value) { continue }
            $type = $pair.Value.GetType()
            $ok = $type -eq [string] -or $type -eq [bool] -or
            $type -eq [int] -or $type -eq [long] -or $type -eq [double] -or
            $pair.Value -is [System.Collections.IList] -or
            $pair.Value -is [System.Collections.IDictionary]
            $ok | Should -BeTrue -Because "mailbox_json['$($pair.Key)'] is [$($type.Name)], which the sidecar would stringify"
        }
        $result.mailbox_json['WhenCreatedUTC'] | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }
}
