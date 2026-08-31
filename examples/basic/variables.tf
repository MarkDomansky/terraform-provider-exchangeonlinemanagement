// Input variables for the basic example.
//
// Copy terraform.tfvars.example to terraform.tfvars and fill it in, or supply
// these through the environment instead - every one of them maps to a provider
// attribute that reads an EXO_* environment variable when unset:
//
//   EXO_ORGANIZATION  EXO_APP_ID  EXO_CERTIFICATE_THUMBPRINT
//   EXO_CERTIFICATE_PATH  EXO_CERTIFICATE_PASSWORD
//
// terraform.tfvars is gitignored (*.tfvars); terraform.tfvars.example is not.

variable "organization" {
  type        = string
  description = "Tenant primary domain, e.g. contoso.onmicrosoft.com. Not a custom domain and not the tenant GUID."

  validation {
    condition     = can(regex("\\.", var.organization))
    error_message = "organization must be a domain such as contoso.onmicrosoft.com."
  }
}

variable "app_id" {
  type        = string
  description = "Entra application (client) ID of the app registration used for app-only authentication."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.app_id))
    error_message = "app_id must be a GUID, e.g. 36ee4c6c-0812-40a2-b820-b22ebd02bce3."
  }
}

// Set EXACTLY ONE of certificate_thumbprint or certificate_path. The provider
// rejects both being set, because a Terraform schema cannot express mutual
// exclusivity and silently picking one would be worse.

variable "certificate_thumbprint" {
  type        = string
  default     = null
  description = "Thumbprint of a certificate in the Windows certificate store. WINDOWS ONLY - use certificate_path on Linux and macOS. The certificate must be in the store of the account that runs terraform."

  validation {
    condition     = var.certificate_thumbprint == null || can(regex("^[0-9a-fA-F]{40}$", var.certificate_thumbprint))
    error_message = "certificate_thumbprint must be 40 hexadecimal characters with no spaces or colons."
  }
}

variable "certificate_path" {
  type        = string
  default     = null
  description = "Path to a PFX file holding the app registration's certificate and private key. Works on every platform. Resolved on the machine running terraform."
}

variable "certificate_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password protecting the PFX named by certificate_path. Omit for an unprotected file. Prefer the EXO_CERTIFICATE_PASSWORD environment variable over putting this in a tfvars file."
}

variable "mailbox_name" {
  type        = string
  default     = "terraform-sales"
  description = "Name and alias of the shared mailbox this example creates."
}

variable "display_name" {
  type        = string
  default     = "Sales Team"
  description = "Display name of the shared mailbox in address lists."
}
