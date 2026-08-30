# Contract tests for the provider lifecycle scripts.
#
# startup.ps1/shutdown.ps1 run flat at the runspace scope and the engine
# prepends its own param block, so a param block here is a parse error that
# only shows up at `terraform plan` time. Catch it in CI instead.
#
# Run: pwsh ./.template/tests/unit/Invoke-UnitTests.ps1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '.template' 'tests' 'harness' 'ScriptUnit.psm1') -Force
    $script:ScriptsDir = Join-Path $PSScriptRoot '..'
}

Describe 'provider lifecycle scripts' {
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
