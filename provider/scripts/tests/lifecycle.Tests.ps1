# Contract and behaviour tests for the provider lifecycle scripts.
#
# startup.ps1/shutdown.ps1 run flat at the runspace scope and the engine
# prepends its own param block, so a param block here is a parse error that
# only shows up at `terraform plan` time. Catch it in CI instead.
#
# The behaviour tests dot-source startup.ps1 into this file's scope on purpose:
# that is what lets Pester's mocks reach the cmdlets it calls, and its
# `function global:` helpers still land at global scope where the ScriptUnit
# harness can see them.
#
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' 'tests' 'support' 'EXOTestStubs.psm1') -Force

    $script:ScriptsDir = Join-Path $PSScriptRoot '..'
    $script:StartupPath = Join-Path $script:ScriptsDir 'startup.ps1'
    $script:ShutdownPath = Join-Path $script:ScriptsDir 'shutdown.ps1'

    # A PFX the certificate_path branch can resolve. Its contents never matter:
    # Connect-ExchangeOnline is stubbed.
    $script:CertPath = Join-Path ([System.IO.Path]::GetTempPath()) ("exo-unit-" + [Guid]::NewGuid().ToString('n') + '.pfx')
    Set-Content -LiteralPath $script:CertPath -Value 'not-a-real-certificate' -NoNewline

    # Run startup.ps1 with a given config and return the recorded
    # Connect-ExchangeOnline parameters (or let its throw propagate).
    function Invoke-Startup {
        param([hashtable]$Config)

        Initialize-EXOStub
        $global:ProviderData = @{ Config = $Config }
        . $script:StartupPath
        return (Get-EXOCall -Command 'Connect-ExchangeOnline')
    }
}

AfterAll {
    Remove-EXOStub
    $global:ProviderData = $null
    $global:EXOProviderState = $null
    Remove-Item -LiteralPath $script:CertPath -Force -ErrorAction SilentlyContinue
}

Describe 'provider lifecycle script contract' {
    It '<_> parses' -ForEach @('startup.ps1', 'shutdown.ps1') {
        $path = Join-Path $script:ScriptsDir $_
        if (-not (Test-Path -LiteralPath $path)) { Set-ItResult -Skipped -Because "$_ is optional and absent"; return }

        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It '<_> declares no param block (the engine prepends its own)' -ForEach @('startup.ps1', 'shutdown.ps1') {
        $path = Join-Path $script:ScriptsDir $_
        if (-not (Test-Path -LiteralPath $path)) { Set-ItResult -Skipped -Because "$_ is optional and absent"; return }

        Get-ScriptParameter -Script (Get-Content -LiteralPath $path -Raw) | Should -BeNullOrEmpty
    }
}

Describe 'startup.ps1 authentication' {
    BeforeEach {
        Initialize-EXOStub
        $global:EXOProviderState = $null
    }

    It 'connects with the certificate path, converting the password to a SecureString' {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{
                certificate_path     = $script:CertPath
                certificate_password = 'pfx-secret'
            })

        $calls.Count | Should -Be 1
        $p = $calls[0].Parameters
        $p.AppId | Should -Be '44444444-4444-4444-4444-444444444444'
        $p.Organization | Should -Be 'contoso.onmicrosoft.com'
        $p.CertificateFilePath | Should -Not -BeNullOrEmpty
        # Resolved to an absolute path on the provider's machine.
        [System.IO.Path]::IsPathRooted($p.CertificateFilePath) | Should -BeTrue
        $p.CertificatePassword | Should -BeOfType [securestring]
        # A plaintext password must never reach the cmdlet.
        $p.CertificatePassword | Should -Not -Be 'pfx-secret'
        $p.ContainsKey('CertificateThumbprint') | Should -BeFalse
    }

    It 'omits CertificatePassword when the PFX is unprotected' {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath })
        $calls[0].Parameters.ContainsKey('CertificatePassword') | Should -BeFalse
    }

    It 'suppresses the banner and the format data on every connect' {
        # Startup runs on every plan, apply, refresh and destroy, and
        # SkipLoadingFormatData is what Microsoft documents for hosting the
        # module inside a service or the PowerShell SDK - which is what the
        # provider's sidecar is.
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath })
        $calls[0].Parameters.ShowBanner | Should -BeFalse
        $calls[0].Parameters.SkipLoadingFormatData | Should -BeTrue
    }

    It 'defaults the Exchange environment to O365Default' {
        # Deliberately a startup.ps1 fallback rather than a manifest default:
        # the engine applies a manifest default before the env lookup, which
        # would make EXO_EXCHANGE_ENVIRONMENT_NAME dead code.
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath })
        $calls[0].Parameters.ExchangeEnvironmentName | Should -Be 'O365Default'
        $global:EXOProviderState.Environment | Should -Be 'O365Default'
    }

    It 'passes a sovereign cloud through when configured' {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{
                certificate_path          = $script:CertPath
                exchange_environment_name = 'O365USGovGCCHigh'
            })
        $calls[0].Parameters.ExchangeEnvironmentName | Should -Be 'O365USGovGCCHigh'
    }

    It 'narrows the imported cmdlet set when command_names is set' {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{
                certificate_path = $script:CertPath
                command_names    = @('Get-Mailbox', 'Set-Mailbox')
            })
        $calls[0].Parameters.CommandName.Count | Should -Be 2
        $calls[0].Parameters.CommandName | Should -Contain 'Get-Mailbox'
    }

    It 'omits CommandName when command_names is unset' {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath })
        $calls[0].Parameters.ContainsKey('CommandName') | Should -BeFalse
    }

    It 'records the selected mode in EXOProviderState' {
        Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath }) | Out-Null
        $global:EXOProviderState.AuthMethod | Should -Be 'certificate_path'
        $global:EXOProviderState.Organization | Should -Be 'contoso.onmicrosoft.com'
    }

    It 'emits nothing to the success stream' {
        # startup.ps1 goes through the engine's one-object rule too: a stray
        # emitted object fails provider configuration.
        Initialize-EXOStub
        $global:ProviderData = @{ Config = New-EXOProviderConfig @{ certificate_path = $script:CertPath } }
        $emitted = @(. $script:StartupPath)
        $emitted | Should -BeNullOrEmpty
    }

    It 'uses the certificate thumbprint on Windows' -Skip:(-not $IsWindows) {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{
                certificate_path       = $null
                certificate_thumbprint = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
            })
        $calls[0].Parameters.CertificateThumbprint | Should -Be 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
        $calls[0].Parameters.ContainsKey('CertificateFilePath') | Should -BeFalse
    }

    It 'refuses the certificate thumbprint off Windows and names the alternative' -Skip:$IsWindows {
        # Connect-ExchangeOnline -CertificateThumbprint reads the Windows
        # certificate store; failing here beats a cryptic cmdlet error.
        {
            Invoke-Startup -Config (New-EXOProviderConfig @{
                    certificate_path       = $null
                    certificate_thumbprint = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
                })
        } | Should -Throw -ExpectedMessage '*Windows-only*certificate_path*'
    }
}

Describe 'startup.ps1 configuration errors' {
    BeforeEach {
        Initialize-EXOStub
        $global:EXOProviderState = $null
    }

    It 'rejects two certificates at once, because a schema cannot express mutual exclusivity' {
        {
            Invoke-Startup -Config (New-EXOProviderConfig @{
                    certificate_path       = $script:CertPath
                    certificate_thumbprint = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
                })
        } | Should -Throw -ExpectedMessage '*Ambiguous*auth_method*'
    }

    It 'honours auth_method as the tie-breaker' {
        $calls = Invoke-Startup -Config (New-EXOProviderConfig @{
                certificate_path       = $script:CertPath
                certificate_thumbprint = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
                auth_method            = 'certificate_path'
            })
        $calls[0].Parameters.ContainsKey('CertificateFilePath') | Should -BeTrue
        $calls[0].Parameters.ContainsKey('CertificateThumbprint') | Should -BeFalse
    }

    It 'lists both modes when no certificate is configured' {
        { Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $null }) } |
            Should -Throw -ExpectedMessage '*No Exchange Online certificate configured*'
    }

    It 'names the attribute and the env var when app_id is missing' {
        { Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath; app_id = $null }) } |
            Should -Throw -ExpectedMessage '*app_id*EXO_APP_ID*'
    }

    It 'names the attribute and the env var when organization is missing' {
        { Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = $script:CertPath; organization = $null }) } |
            Should -Throw -ExpectedMessage '*organization*EXO_ORGANIZATION*'
    }

    It 'reports a missing PFX against the provider machine, not a remote one' {
        { Invoke-Startup -Config (New-EXOProviderConfig @{ certificate_path = 'no-such-file.pfx' }) } |
            Should -Throw -ExpectedMessage '*does not exist*machine running the provider*'
    }

    It 'tells the operator how to install the module when it is absent' {
        # The module must genuinely be undiscoverable, and it may well be
        # installed on the machine running these tests (in which case
        # Get-Command auto-loads it). So run startup.ps1 in a child pwsh whose
        # PSModulePath covers only PowerShell's own modules - the closest
        # honest simulation of "the operator has not installed it yet".
        $script = @"
`$env:PSModulePath = [System.IO.Path]::Combine(`$PSHOME, 'Modules')
`$global:ProviderData = @{ Config = @{
    organization     = 'contoso.onmicrosoft.com'
    app_id           = '44444444-4444-4444-4444-444444444444'
    certificate_path = '$($script:CertPath -replace "'", "''")'
} }
try { . '$($script:StartupPath -replace "'", "''")' } catch { `$_.Exception.Message }
"@
        $output = & (Get-Process -Id $PID).Path -NoProfile -Command $script 2>&1 | Out-String

        $output | Should -BeLike '*ExchangeOnlineManagement*'
        $output | Should -BeLike '*Install-Module ExchangeOnlineManagement -Scope CurrentUser*'
        # The non-obvious part: the module has to be where the *provider
        # process* can see it, which is why module_path exists.
        $output | Should -BeLike '*module_path*'
    }
}

Describe 'shutdown.ps1' {
    It 'disconnects without prompting' {
        # -Confirm:$false is mandatory: Disconnect-ExchangeOnline has a high
        # ConfirmImpact and would otherwise block the non-interactive host.
        Initialize-EXOStub
        . $script:ShutdownPath
        (Get-EXOCall -Command 'Disconnect-ExchangeOnline').Count | Should -Be 1
        $global:EXOProviderState | Should -BeNullOrEmpty
    }

    It 'succeeds when no connection was ever made' {
        Remove-EXOStub
        { . $script:ShutdownPath } | Should -Not -Throw
    }

    It 'swallows a failing disconnect so it cannot fail the terraform run' {
        Initialize-EXOStub
        Set-EXOBehavior -Command 'Disconnect-ExchangeOnline' -Body { throw 'connection already closed' }
        { . $script:ShutdownPath } | Should -Not -Throw
    }
}
