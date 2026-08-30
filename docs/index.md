---
page_title: "exchangeonlinemanagement Provider"
description: |-
  Manage Exchange Online mailboxes and their client access settings with
  Terraform, using the ExchangeOnlineManagement PowerShell module and
  certificate-based app-only authentication.
---

# exchangeonlinemanagement Provider

Manages Exchange Online recipients by running the `ExchangeOnlineManagement`
PowerShell module's cmdlets — `New-Mailbox`, `Set-Mailbox`, `Set-CASMailbox`
and friends — from Terraform.

The provider opens one Exchange Online session per Terraform run and reuses it
for every resource, so authentication happens once rather than per mailbox.

## Requirements

> ### The ExchangeOnlineManagement module must already be installed
>
> The provider bundles a PowerShell runtime, **not** the Exchange module. You
> need **ExchangeOnlineManagement 3.0.0 or later** installed on the machine
> that runs `terraform`:
>
> ```powershell
> Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion 3.0.0
> ```
>
> The provider hosts PowerShell in-process rather than launching `pwsh`, so the
> module must be on the `PSModulePath` that the `terraform` process itself
> sees. If it lives somewhere that path does not cover, point the provider at
> it with the `module_path` attribute (see [Schema](#schema)).
>
> If it is missing, the provider fails at configuration time with a message
> telling you exactly this. To install it *with* Terraform, see
> [Installing the PowerShell module](guides/installing-the-module).

You also need an Entra ID app registration with a certificate and the Exchange
permissions to use it — see
[Registering the Entra application](guides/app-registration).

## Example Usage

```terraform
terraform {
  required_providers {
    # The provider name is long, so bind it to a short local name.
    exo = {
      source  = "markdomansky/exchangeonlinemanagement"
      version = "~> 0.1"
    }
  }
}

provider "exo" {
  organization           = "contoso.onmicrosoft.com"
  app_id                 = "36ee4c6c-0812-40a2-b820-b22ebd02bce3"
  certificate_thumbprint = "83213AEAC56D61C97AEE5C1528F4AC5EBA7321C1"
}

resource "exo_mailbox" "sales" {
  name         = "sales"
  type         = "shared"
  display_name = "Sales Team"
  alias        = "sales"
}

# Turn off the legacy protocols on that mailbox.
resource "exo_cas_mailbox" "sales" {
  identity                            = exo_mailbox.sales.id
  pop_enabled                         = false
  imap_enabled                        = false
  smtp_client_authentication_disabled = true
}

output "sales_address" {
  value = exo_mailbox.sales.effective_primary_smtp_address
}
```

## Authentication

The provider supports **certificate-based app-only authentication** only, in
two forms. Configure exactly one; setting both is an error, because a Terraform
schema cannot express mutual exclusivity and silently picking one would be
worse.

### Certificate in the Windows certificate store

```terraform
provider "exo" {
  organization           = "contoso.onmicrosoft.com"
  app_id                 = "36ee4c6c-0812-40a2-b820-b22ebd02bce3"
  certificate_thumbprint = "83213AEAC56D61C97AEE5C1528F4AC5EBA7321C1"
}
```

`Connect-ExchangeOnline -CertificateThumbprint` reads the Windows certificate
store and Microsoft documents no cross-platform equivalent, so this form is
**Windows-only**. The provider fails with a clear message on Linux and macOS
rather than letting the cmdlet fail obscurely.

### Certificate from a PFX file (all platforms)

```terraform
provider "exo" {
  organization         = "contoso.onmicrosoft.com"
  app_id               = "36ee4c6c-0812-40a2-b820-b22ebd02bce3"
  certificate_path     = "/etc/terraform/exo.pfx"
  certificate_password = var.certificate_password # sensitive
}
```

The path is resolved on the machine running the provider — the same machine
running `terraform` — not on any remote system.

### Not supported

- **Client secret.** `Connect-ExchangeOnline` has no `-ClientSecret`
  parameter. Supporting it would mean the provider minting OAuth tokens itself
  and managing their expiry. Use a certificate.
- **Managed identity** and **interactive / delegated sign-in.** Neither suits
  a Terraform provider that must run unattended and configure itself from HCL.

### Environment variables

Every provider attribute except `command_names` falls back to an environment
variable, so credentials can stay out of your configuration entirely:

| Attribute | Environment variable |
|---|---|
| `organization` | `EXO_ORGANIZATION` |
| `app_id` | `EXO_APP_ID` |
| `auth_method` | `EXO_AUTH_METHOD` |
| `certificate_thumbprint` | `EXO_CERTIFICATE_THUMBPRINT` |
| `certificate_path` | `EXO_CERTIFICATE_PATH` |
| `certificate_password` | `EXO_CERTIFICATE_PASSWORD` |
| `exchange_environment_name` | `EXO_EXCHANGE_ENVIRONMENT_NAME` |
| `module_path` | `EXO_MODULE_PATH` |

```terraform
# Everything comes from the environment.
provider "exo" {}
```

## Schema

### Optional

- `organization` (String) The tenant's primary `.onmicrosoft.com` domain, e.g.
  `contoso.onmicrosoft.com`. Required in practice; the provider fails at
  configuration time when it is missing. (It is declared optional so that the
  environment-variable fallback is available.)
- `app_id` (String) Application (client) ID of the Entra app registration.
  Required in practice, for the same reason.
- `auth_method` (String) Forces the authentication mode: `certificate_thumbprint`
  or `certificate_path`. Leave unset to infer it from whichever certificate
  attribute you set; use it only to resolve an ambiguity.
- `certificate_thumbprint` (String) Thumbprint of a certificate in the Windows
  certificate store. **Windows only.**
- `certificate_path` (String) Path to a PFX file holding the app
  registration's certificate and private key. All platforms.
- `certificate_password` (String, **Sensitive**) Password protecting that PFX.
  Omit for an unprotected file.
- `exchange_environment_name` (String) The Exchange Online cloud instance:
  `O365Default` (the default), `O365GermanyCloud`, `O365China`,
  `O365USGovGCCHigh` or `O365USGovDoD`.
- `module_path` (String) Directory prepended to `PSModulePath` before
  `ExchangeOnlineManagement` is imported.
- `command_names` (List of String) The subset of Exchange cmdlets to import.
  Narrowing it measurably speeds up provider startup, which runs on **every**
  plan, apply, refresh and destroy. This provider needs at least
  `Get-Mailbox`, `New-Mailbox`, `Set-Mailbox`, `Remove-Mailbox`,
  `Get-CASMailbox` and `Set-CASMailbox`:

  ```terraform
  provider "exo" {
    command_names = [
      "Get-Mailbox", "New-Mailbox", "Set-Mailbox", "Remove-Mailbox",
      "Get-CASMailbox", "Set-CASMailbox",
    ]
  }
  ```

The underlying engine also provides built-in attributes on every provider it
builds — `startup_script`, `shutdown_script`, `timeout`, generic connection
arguments (`server`, `username`, `password`, `cert_thumbprint`,
`provider_data`, `sensitive_provider_data`) and remote-session arguments
(`session_type` and friends). This provider does not use them; prefer the
attributes above. See the
[engine's documentation](https://github.com/markdomansky/terraform-provider-powershell)
for their semantics.

## Things worth knowing before you build on this

### Configuration drift is only visible through the `effective_*` attributes

When someone changes a setting in the Exchange admin center, Terraform will
**not** report a diff on the corresponding configuration attribute. The
provider engine refreshes computed attributes from the tenant but never
rewrites configuration attributes from it.

That is why every meaningful setting has a computed mirror —
`effective_display_name`, `effective_owa_enabled`, and so on. Those *are*
refreshed, so they are where drift shows up, and what to assert on in tests or
alert on in CI:

```terraform
# check blocks require Terraform 1.5 or later.
check "sales_pop_stays_off" {
  assert {
    condition     = exo_cas_mailbox.sales.effective_pop_enabled == false
    error_message = "POP3 was re-enabled on the sales mailbox outside Terraform."
  }
}
```

Applying always reconciles the tenant to your configuration, so a drifted
setting is corrected by the next `terraform apply` that touches the resource —
it just is not *reported* beforehand.

### After `terraform import`, the first apply reconciles everything

Importing populates only the resource `id`; every configuration attribute
starts null in state. The first plan therefore shows every attribute you have
written going from null to its value, and the first apply pushes them to the
tenant.

Consequently **no attribute on these resources forces replacement**. If one
did, importing would plan the destruction of a live mailbox. Genuinely
immutable fields — a mailbox's UPN, the mailbox a `cas_mailbox` resource points
at — are checked during apply and produce a named error instead.

### Secrets and state

`certificate_password` is marked sensitive, which redacts it from CLI output.
It is still written to state, and provider configuration is embedded in saved
plan files (`terraform plan -out`). Treat both as secrets, and prefer the
`EXO_CERTIFICATE_PASSWORD` environment variable.

### Exchange Online is slow and throttles

Each resource allows 300 seconds per operation. Large `for_each` expansions can
hit Exchange's throttling; the module retries internally, but consider
`-parallelism` if you are creating mailboxes in bulk.
