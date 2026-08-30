# Script-level unit tests for the example_file sample resource.
#
# These run the CRUD scripts in-process (no terraform, no Go, no sidecar) via
# the managed ScriptUnit harness, so they are fast enough for every PR. For a
# resource that talks to a real system you would Pester-Mock its cmdlets here
# (Mock New-Mailbox { ... }) instead of touching that system.
#
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("example-file-unit-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TempDir | Out-Null
    # The startup script would normally build this from $global:ProviderData.Config.
    $global:YourProviderState = @{ default_directory = $script:TempDir }
}

AfterAll {
    $global:YourProviderState = $null
    Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
}

Describe 'example_file resource scripts' {
    It 'declares a valid schema with the expected attributes' {
        $manifest = Get-ResourceManifest -Kind resources -Name example_file
        $manifest.version | Should -Be 1
        $manifest.attributes.path.required | Should -BeTrue
        $manifest.attributes.content.optional | Should -BeTrue
        $manifest.attributes.size.computed | Should -BeTrue
    }

    It '<_>.ps1 declares the engine param contract' -ForEach @('create', 'read', 'update', 'delete') {
        $path = Get-ResourceScriptPath -Kind resources -Name example_file -Action $_
        $params = @(Get-ScriptParameter -Script (Get-Content -LiteralPath $path -Raw))

        # The engine binds -InputData by name and passes nothing else.
        $params.Name | Should -Contain 'InputData'
        # $Action arrives as an enclosing-scope variable; a parameter shadows it.
        $params.Name | Should -Not -Contain 'Action'
        # Nothing can supply a second mandatory parameter.
        @($params | Where-Object { $_.Mandatory -and $_.Name -ne 'InputData' }) | Should -BeNullOrEmpty
    }

    It '<_>.ps1 rejects an $InputData with no id' -ForEach @('read', 'update', 'delete') {
        { Invoke-ResourceScript -Kind resources -Name example_file -Action $_ -InputData @{ path = 'no-id.txt' } } |
            Should -Throw -ExpectedMessage '*requires a non-empty $InputData.id*'
    }

    It 'create writes the file and emits id, size, last_modified' {
        $result = Invoke-ResourceScript -Kind resources -Name example_file -Action create -InputData @{
            path    = 'unit-create.txt'
            content = 'hello'
        }
        $result.id | Should -Be (Join-Path $script:TempDir 'unit-create.txt')
        $result.size | Should -Be 5
        $result.last_modified | Should -Not -BeNullOrEmpty
        Get-Content -LiteralPath $result.id -Raw | Should -Be 'hello'
    }

    It 'read emits the current state for an existing file' {
        $id = Join-Path $script:TempDir 'unit-read.txt'
        Set-Content -LiteralPath $id -Value 'abc' -NoNewline
        $result = Invoke-ResourceScript -Kind resources -Name example_file -Action read -InputData @{
            id   = $id
            path = 'unit-read.txt'
        }
        $result.size | Should -Be 3
    }

    It 'read emits nothing when the file is gone (resource disappeared)' {
        $result = Invoke-ResourceScript -Kind resources -Name example_file -Action read -InputData @{
            id   = (Join-Path $script:TempDir 'does-not-exist.txt')
            path = 'does-not-exist.txt'
        }
        $result | Should -BeNullOrEmpty
    }

    It 'update rewrites the content in place' {
        $id = Join-Path $script:TempDir 'unit-update.txt'
        Set-Content -LiteralPath $id -Value 'old' -NoNewline
        $result = Invoke-ResourceScript -Kind resources -Name example_file -Action update -InputData @{
            id      = $id
            path    = 'unit-update.txt'
            content = 'new content'
        }
        $result.size | Should -Be 11
        Get-Content -LiteralPath $id -Raw | Should -Be 'new content'
    }

    It 'delete removes the file and stays idempotent' {
        $id = Join-Path $script:TempDir 'unit-delete.txt'
        Set-Content -LiteralPath $id -Value 'x' -NoNewline
        Invoke-ResourceScript -Kind resources -Name example_file -Action delete -InputData @{ id = $id; path = 'unit-delete.txt' } | Out-Null
        Test-Path -LiteralPath $id | Should -BeFalse
        # Deleting again must not fail (idempotent destroy).
        { Invoke-ResourceScript -Kind resources -Name example_file -Action delete -InputData @{ id = $id; path = 'unit-delete.txt' } } |
            Should -Not -Throw
    }
}
