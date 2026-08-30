---
page_title: "yourprovider Provider"
description: |-
  A PowerShell-script-backed Terraform provider built from the
  terraform-provider-powershell template. Replace this page with your
  provider's real documentation.
---

# yourprovider Provider

> **Template note:** this page documents the sample provider that ships with
> the template. After `Initialize-Fork.ps1`, rewrite it for your provider:
> what it manages, how to authenticate, real examples. The layout
> (`index.md`, `resources/`, `data-sources/`, `guides/`) is what the
> Terraform Registry renders, and `main` auto-syncs it to the repo wiki.

The provider executes PowerShell scripts (bundled inside the provider — no
PowerShell installation required at runtime) for every resource operation. It
maintains one persistent PowerShell process per configured provider instance,
so authentication done at startup is reused by every resource.

## Example Usage

```terraform
terraform {
  required_providers {
    yourprovider = {
      source = "yournamespace/yourprovider"
    }
  }
}

provider "yourprovider" {
  # Custom attribute declared in provider/provider.tfps.json:
  default_directory = "C:/temp/demo"
}

resource "yourprovider_example_file" "hello" {
  path    = "hello.txt"
  content = "Hello from a derived provider!"
}
```

## Schema

### Optional

- `default_directory` (String) Directory used by the example_file resource
  when a relative path is given. Can also be set via the
  `YOURPROVIDER_DEFAULT_DIRECTORY` environment variable.

The engine also provides built-in attributes on every derived provider —
`startup_script`, `shutdown_script`, `timeout`, connection arguments
(`server`, `username`, `password`, `cert_thumbprint`, `provider_data`,
`sensitive_provider_data`), and remote-session arguments (`session_type`
`winrm`/`ssh`/`vmguest` with `session_host`, `session_username`, ...). With a
`session_type` set, every script runs on the remote machine. See the
[engine's documentation](https://github.com/markdomansky/terraform-provider-powershell)
for the full list and semantics.
