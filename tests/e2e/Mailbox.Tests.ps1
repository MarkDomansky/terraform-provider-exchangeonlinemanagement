# End-to-end test against a REAL Exchange Online tenant: real terraform, the
# compiled provider, the pshost sidecar, and live Exchange cmdlets.
#
# Gated on tests/e2e/config/e2e.tests.config.psd1 (gitignored). Without it the
# whole suite skips, so CI stays green on machines with no tenant. Copy
# config/e2e.tests.config.template.psd1 to get started.
#
# THIS CREATES AND DELETES REAL MAILBOXES. Point it at a test tenant.
#
# This suite is also where the Exchange behaviours that cannot be verified
# offline get settled - the cmdlets only exist after Connect-ExchangeOnline
# builds its REST session, so their parameters cannot be introspected from a
# unit test. See REPO-NOTES.md for the current list.
#
# Run: ./.template/build/Build-Provider.ps1 ; Invoke-Pester ./tests/e2e -Output Detailed
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '.template' 'tests' 'harness' 'TFHarness.psm1') -Force

    $script:Config = Get-E2ETestConfig
    $script:Enabled = $null -ne $script:Config -and $script:Config.Enabled -eq $true -and
    $script:Config.Organization -ne 'TBD' -and $script:Config.AppId -ne 'TBD'

    if (-not $script:Enabled) {
        Write-TFLog 'Exchange Online E2E suite skipped: no usable tests/e2e/config/e2e.tests.config.psd1' 'SKIP'
        return
    }

    Initialize-ProviderBin | Out-Null

    $script:Name = Get-ProviderName
    $script:Source = Get-ProviderSource
    $script:MailboxName = "$($script:Config.MailboxPrefix)-" + [Guid]::NewGuid().ToString('n').Substring(0, 8)

    Write-TFLog "test mailbox: $script:MailboxName" 'STEP'

    $script:Config1 = @"
terraform {
  required_providers {
    $script:Name = {
      source = "$script:Source"
    }
  }
}

variable "organization"           { type = string }
variable "app_id"                 { type = string }
variable "certificate_thumbprint" { type = string  default = null }
variable "certificate_path"       { type = string  default = null }
variable "certificate_password"   { type = string  default = null  sensitive = true }
variable "mailbox_name"           { type = string }
variable "display_name"           { type = string }

provider "$script:Name" {
  organization           = var.organization
  app_id                 = var.app_id
  certificate_thumbprint = var.certificate_thumbprint
  certificate_path       = var.certificate_path
  certificate_password   = var.certificate_password
}

resource "${script:Name}_mailbox" "test" {
  name         = var.mailbox_name
  type         = "shared"
  display_name = var.display_name
  alias        = var.mailbox_name

  # Skip the 30-day soft-delete retention so a rerun with a fresh name cannot
  # collide with leftovers from this one.
  permanently_delete = true
}

resource "${script:Name}_cas_mailbox" "test" {
  identity     = ${script:Name}_mailbox.test.id
  pop_enabled  = false
  imap_enabled = false
}

data "${script:Name}_mailbox" "by_address" {
  email_address = ${script:Name}_mailbox.test.effective_primary_smtp_address
}

output "id"                  { value = ${script:Name}_mailbox.test.id }
output "primary_smtp"        { value = ${script:Name}_mailbox.test.effective_primary_smtp_address }
output "display_name"        { value = ${script:Name}_mailbox.test.effective_display_name }
output "recipient_type"      { value = ${script:Name}_mailbox.test.recipient_type_details }
output "object_id"           { value = ${script:Name}_mailbox.test.external_directory_object_id }
output "ds_found"            { value = data.${script:Name}_mailbox.by_address.found }
output "ds_guid"             { value = data.${script:Name}_mailbox.by_address.mailbox_guid }
output "ds_display_name"     { value = data.${script:Name}_mailbox.by_address.display_name }
output "cas_pop_enabled"     { value = ${script:Name}_cas_mailbox.test.effective_pop_enabled }
output "cas_imap_enabled"    { value = ${script:Name}_cas_mailbox.test.effective_imap_enabled }
output "cas_owa_enabled"     { value = ${script:Name}_cas_mailbox.test.effective_owa_enabled }
"@

    $script:Variables = @{
        organization           = $script:Config.Organization
        app_id                 = $script:Config.AppId
        certificate_thumbprint = $script:Config.CertificateThumbprint
        certificate_path       = $script:Config.CertificatePath
        certificate_password   = $script:Config.CertificatePassword
        mailbox_name           = $script:MailboxName
        display_name           = 'Terraform E2E'
    }
}

Describe 'Exchange Online mailbox end to end' -Skip:(-not $script:Enabled) {
    It 'creates, reads back, updates in place, and destroys' {
        $ws = New-TFWorkspace -Config $script:Config1 -Variables $script:Variables
        try {
            Write-TFLog 'apply: create the mailbox and its client access settings' 'STEP'
            Invoke-TF -Workspace $ws -Arguments @('apply', '-auto-approve', '-no-color') | Out-Null

            $out = Get-TFOutput -Workspace $ws
            $created = $out.id.value

            $created | Should -Not -BeNullOrEmpty
            $out.recipient_type.value | Should -Be 'SharedMailbox'
            $out.display_name.value | Should -Be 'Terraform E2E'
            # Exchange derives this; proves the effective_ mirrors are populated.
            $out.primary_smtp.value | Should -Not -BeNullOrEmpty
            $out.object_id.value | Should -Not -BeNullOrEmpty

            # The data source resolves the same mailbox by address.
            $out.ds_found.value | Should -BeTrue
            $out.ds_guid.value | Should -Be $created
            $out.ds_display_name.value | Should -Be 'Terraform E2E'

            # Set-CASMailbox took effect, and an unmanaged protocol was untouched.
            $out.cas_pop_enabled.value | Should -BeFalse
            $out.cas_imap_enabled.value | Should -BeFalse
            $out.cas_owa_enabled.value | Should -BeTrue

            Write-TFLog 'plan: second plan must be a no-op' 'STEP'
            (Invoke-TFExit -Workspace $ws -Arguments @('plan', '-detailed-exitcode', '-no-color')).ExitCode |
                Should -Be 0

            Write-TFLog 'apply: rename in place, id must not change' 'STEP'
            $script:Variables.display_name = 'Terraform E2E (renamed)'
            $ws2 = New-TFWorkspace -Config $script:Config1 -Variables $script:Variables
            try {
                # Reuse the first workspace's state so this is an update, not a create.
                Copy-Item -Path (Join-Path $ws.Dir 'terraform.tfstate') -Destination $ws2.Dir -Force
                Invoke-TF -Workspace $ws2 -Arguments @('apply', '-auto-approve', '-no-color') | Out-Null

                $out2 = Get-TFOutput -Workspace $ws2
                $out2.display_name.value | Should -Be 'Terraform E2E (renamed)'
                # No attribute forces replacement, so an update keeps the id.
                $out2.id.value | Should -Be $created

                Write-TFLog 'destroy' 'STEP'
                Invoke-TF -Workspace $ws2 -Arguments @('destroy', '-auto-approve', '-no-color') | Out-Null
            }
            finally {
                Remove-TFWorkspace -Workspace $ws2
            }
        }
        finally {
            Remove-TFWorkspace -Workspace $ws
        }
    }

    It 'reports found = false for a mailbox that does not exist' {
        $config = @"
terraform {
  required_providers {
    $script:Name = {
      source = "$script:Source"
    }
  }
}

variable "organization"           { type = string }
variable "app_id"                 { type = string }
variable "certificate_thumbprint" { type = string  default = null }
variable "certificate_path"       { type = string  default = null }
variable "certificate_password"   { type = string  default = null  sensitive = true }

provider "$script:Name" {
  organization           = var.organization
  app_id                 = var.app_id
  certificate_thumbprint = var.certificate_thumbprint
  certificate_path       = var.certificate_path
  certificate_password   = var.certificate_password
}

data "${script:Name}_mailbox" "missing" {
  user_principal_name = "does-not-exist-$([Guid]::NewGuid().ToString('n'))@$($script:Config.Organization)"
}

output "found" { value = data.${script:Name}_mailbox.missing.found }
"@
        $variables = @{}
        foreach ($key in 'organization', 'app_id', 'certificate_thumbprint', 'certificate_path', 'certificate_password') {
            $variables[$key] = $script:Variables[$key]
        }

        $ws = New-TFWorkspace -Config $config -Variables $variables
        try {
            # A missing mailbox is not an error - it must apply cleanly.
            Invoke-TF -Workspace $ws -Arguments @('apply', '-auto-approve', '-no-color') | Out-Null
            (Get-TFOutput -Workspace $ws).found.value | Should -BeFalse
        }
        finally {
            Remove-TFWorkspace -Workspace $ws
        }
    }
}
