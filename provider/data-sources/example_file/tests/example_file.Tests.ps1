# Script-level unit tests for the example_file sample data source.
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("example-file-ds-unit-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TempDir | Out-Null
    $global:YourProviderState = @{ default_directory = $script:TempDir }
}

AfterAll {
    $global:YourProviderState = $null
    Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
}

Describe 'example_file data source script' {
    It 'read.ps1 declares the engine param contract' {
        $path = Get-ResourceScriptPath -Kind data-sources -Name example_file -Action read
        $params = @(Get-ScriptParameter -Script (Get-Content -LiteralPath $path -Raw))

        $params.Name | Should -Contain 'InputData'
        $params.Name | Should -Not -Contain 'Action'
        @($params | Where-Object { $_.Mandatory -and $_.Name -ne 'InputData' }) | Should -BeNullOrEmpty
    }

    It 'reads an existing file' {
        Set-Content -LiteralPath (Join-Path $script:TempDir 'ds.txt') -Value 'data!' -NoNewline
        $result = Invoke-ResourceScript -Kind data-sources -Name example_file -Action read -InputData @{ path = 'ds.txt' }
        $result.exists | Should -BeTrue
        $result.content | Should -Be 'data!'
        $result.size | Should -Be 5
    }

    It 'reports a missing file via exists=false' {
        $result = Invoke-ResourceScript -Kind data-sources -Name example_file -Action read -InputData @{ path = 'nope.txt' }
        $result.exists | Should -BeFalse
        $result.content | Should -BeNullOrEmpty
    }
}
