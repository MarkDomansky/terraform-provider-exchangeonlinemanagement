// Minimal working example: a shared mailbox, its client access settings, and
// a lookup of the result.
//
// Prerequisites (see docs/guides/):
//   1. ExchangeOnlineManagement 3.0.0+ installed on this machine.
//   2. An Entra app registration with a certificate, the Exchange.ManageAsApp
//      application permission (admin-consented), and an Exchange role.

terraform {
  // The check block at the bottom needs Terraform 1.5 or later. The provider
  // itself works with any version that speaks provider protocol 6.
  required_version = ">= 1.5.0"

  required_providers {
    // The provider name is long, so bind it to a short local name.
    exo = {
      source  = "markdomansky/exchangeonlinemanagement"
      version = "~> 0.1"
    }
  }
}

// Variables are declared in variables.tf. Copy terraform.tfvars.example to
// terraform.tfvars to supply them, or export the EXO_* environment variables.

provider "exo" {
  organization = var.organization
  app_id       = var.app_id

  // Option 1: Use a certificate in the Windows certificate store (Windows only).
  certificate_thumbprint = var.certificate_thumbprint
  // Option 2: Use a PFX file (cross-platform).
  # certificate_path       = var.certificate_path
  # certificate_password   = var.certificate_password
}

resource "exo_mailbox" "sales" {
  name         = var.mailbox_name
  type         = "shared"
  display_name = var.display_name
  alias        = var.mailbox_name

  hidden_from_address_lists = false
  max_send_size             = "35 MB"
}

// Client access settings live on their own resource: Set-CASMailbox configures
// a mailbox, it does not create one.
resource "exo_cas_mailbox" "sales" {
  identity = exo_mailbox.sales.id

  pop_enabled                         = false
  imap_enabled                        = false
  smtp_client_authentication_disabled = true

  // Destroy leaves these settings in place by default; opt in to undoing them.
  revert_on_destroy = true
}

// Reads the mailbox back independently of the resource's own state.
data "exo_mailbox" "sales" {
  email_address = exo_mailbox.sales.effective_primary_smtp_address
}

output "primary_smtp_address" {
  // Exchange derives this when primary_smtp_address is not set, so read it
  // from the effective_ mirror rather than from the configuration attribute.
  value = exo_mailbox.sales.effective_primary_smtp_address
}

output "object_id" {
  value = data.exo_mailbox.sales.external_directory_object_id
}

// The effective_ attributes are refreshed from the tenant, so they are what
// makes an out-of-band change visible. Configuration attributes are not.
check "legacy_protocols_stay_off" {
  assert {
    condition = alltrue([
      exo_cas_mailbox.sales.effective_pop_enabled == false,
      exo_cas_mailbox.sales.effective_imap_enabled == false,
    ])
    error_message = "POP3 or IMAP4 was re-enabled on the sales mailbox outside Terraform."
  }
}
