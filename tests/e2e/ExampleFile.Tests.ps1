# End-to-end test for the example_file sample: REAL terraform, the COMPILED
# provider, and the pshost sidecar. Delete this file together with the sample
# resource folders; use it as the blueprint for your own E2E suites.
#
# The HCL is generated from provider/settings.tfps.json, so this suite keeps
# working after Initialize-Fork.ps1 renames the provider.
#
# Suites that need a live target system (a tenant, a server...) should load
# Get-E2ETestConfig and skip cleanly when it returns $null - see SETUP.md.
#
# Run: ./.template/build/Build-Provider.ps1 ; Invoke-Pester ./tests/e2e -Output Detailed
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '.template' 'tests' 'harness' 'TFHarness.psm1') -Force
    Initialize-ProviderBin | Out-Null

    $script:Name = Get-ProviderName
    $script:Source = Get-ProviderSource

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("example-file-e2e-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TempDir | Out-Null

    $script:Config = @"
terraform {
  required_providers {
    $script:Name = {
      source = "$script:Source"
    }
  }
}

variable "dir" { type = string }
variable "content" { type = string }

provider "$script:Name" {
  default_directory = var.dir
}

resource "${script:Name}_example_file" "test" {
  path    = "e2e.txt"
  content = var.content
}

data "${script:Name}_example_file" "read" {
  path       = "e2e.txt"
  depends_on = [${script:Name}_example_file.test]
}

output "id" { value = ${script:Name}_example_file.test.id }
output "size" { value = ${script:Name}_example_file.test.size }
output "content_back" { value = data.${script:Name}_example_file.read.content }
"@
}

AfterAll {
    if ($script:TempDir) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

Describe 'example_file end to end' {
    It 'applies, reads back, updates in place, and destroys' {
        $ws = New-TFWorkspace -Config $script:Config -Variables @{ dir = $script:TempDir; content = 'hello e2e' }
        try {
            Invoke-TF -Workspace $ws -Arguments @('apply', '-auto-approve', '-no-color') | Out-Null

            $out = Get-TFOutput -Workspace $ws
            $out.id.value | Should -Not -BeNullOrEmpty
            $out.size.value | Should -Be 9
            $out.content_back.value | Should -Be 'hello e2e'
            $createdId = $out.id.value

            # Idempotent: a second plan shows no changes (exit 0).
            (Invoke-TFExit -Workspace $ws -Arguments @('plan', '-detailed-exitcode', '-no-color')).ExitCode | Should -Be 0

            # Content change updates in place: same id afterwards.
            Set-Content -Path (Join-Path $ws.Dir 'terraform.tfvars') -Value @(
                "dir = `"$($script:TempDir -replace '\\', '/')`""
                'content = "changed content"'
            ) -Encoding UTF8
            Invoke-TF -Workspace $ws -Arguments @('apply', '-auto-approve', '-no-color') | Out-Null
            $out2 = Get-TFOutput -Workspace $ws
            $out2.id.value | Should -Be $createdId
            $out2.size.value | Should -Be 15

            # Destroy removes the file.
            Invoke-TF -Workspace $ws -Arguments @('destroy', '-auto-approve', '-no-color') | Out-Null
            Test-Path -LiteralPath $createdId | Should -BeFalse
        }
        finally {
            Remove-TFWorkspace -Workspace $ws
        }
    }
}
