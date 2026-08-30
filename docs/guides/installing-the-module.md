---
page_title: "Installing the PowerShell module"
description: |-
  The exchangeonlinemanagement provider requires the ExchangeOnlineManagement
  PowerShell module to already be installed. How to install it, including with
  Terraform itself.
---

# Installing the PowerShell module

This provider runs the `ExchangeOnlineManagement` module's cmdlets. It does not
ship them. **The module must already be installed on the machine that runs
`terraform`**, and the provider will refuse to configure itself if it is not:

```
The exchangeonlinemanagement provider requires the ExchangeOnlineManagement
PowerShell module (3.0.0 or later) to be installed on the machine running
terraform, and it could not be loaded: ...
```

The one-line fix is the ordinary one:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion 3.0.0
```

Whether the module is installed is a property of the machine, not of your
infrastructure, so most teams handle it where they handle their other
prerequisites: the CI image, a container layer, a configuration-management run,
or a developer setup script. The rest of this page is for when you would rather
express it in Terraform.

## Where the module has to be

The provider hosts PowerShell **in-process** — it does not launch `pwsh` — so
it inherits whatever `PSModulePath` the `terraform` process has. Two
consequences:

- `Install-Module -Scope CurrentUser` installs to the per-user module directory
  (`~/Documents/PowerShell/Modules` on Windows,
  `~/.local/share/powershell/Modules` on Linux and macOS), which is on the
  default `PSModulePath`. That normally just works.
- If the module lives anywhere else — a vendored directory, a shared network
  path, an `-Scope AllUsers` install under a different account — tell the
  provider where with `module_path`:

  ```terraform
  provider "exo" {
    module_path = "/opt/powershell-modules"
    # ...
  }
  ```

## Installing it with Terraform

The natural fit is the generic
[`markdomansky/powershell`](https://registry.terraform.io/providers/markdomansky/powershell)
provider, which runs PowerShell scripts as a Terraform resource. Unlike a
`terraform_data` + `local-exec` provisioner, its `read_script` runs on every
refresh, so the resource genuinely tracks whether the module is still installed
instead of just remembering that it once ran.

> ### This must be a separate root module and a separate apply
>
> A provider is configured *before* any resource in the same configuration is
> applied, and there is no `depends_on` for a provider block. So an install
> resource sitting next to your mailboxes cannot be ordered ahead of the
> `exchangeonlinemanagement` provider's startup — the provider would try to
> load the module and fail while the install resource is still waiting its
> turn.
>
> Put the bootstrap in its own root module and apply it first. This is a
> one-time, per-machine operation, so a separate state is the honest model
> anyway.

### `bootstrap/main.tf`

```terraform
terraform {
  required_providers {
    powershell = {
      source  = "markdomansky/powershell"
      version = "~> 0.1"
    }
  }
}

variable "minimum_version" {
  type        = string
  default     = "3.0.0"
  description = "Minimum ExchangeOnlineManagement version the provider needs."
}

resource "powershell_script" "exchange_online_management" {
  # Install-Module is chatty and the engine fails any operation that writes to
  # the error stream, so everything is silenced deliberately and the whole
  # thing is guarded to stay idempotent.
  create_script = <<-PS
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'

    $minimum = [version]$InputData.minimum_version
    $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
        Sort-Object Version -Descending | Select-Object -First 1

    if (-not $installed -or $installed.Version -lt $minimum) {
        Install-Module -Name ExchangeOnlineManagement `
            -MinimumVersion $minimum `
            -Scope CurrentUser -Force -AllowClobber -Confirm:$false | Out-Null

        $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
            Sort-Object Version -Descending | Select-Object -First 1
    }

    @{
        id      = 'ExchangeOnlineManagement'
        version = [string]$installed.Version
        path    = [string]$installed.ModuleBase
    }
  PS

  # Emitting nothing tells Terraform the module is gone, so a machine that lost
  # it plans a reinstall.
  read_script = <<-PS
    $ErrorActionPreference = 'Stop'

    $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed) { return }

    @{
        id      = 'ExchangeOnlineManagement'
        version = [string]$installed.Version
        path    = [string]$installed.ModuleBase
    }
  PS

  # Destroy leaves the module in place: it is a machine-level prerequisite that
  # other things may depend on. Replace this with Uninstall-Module if you would
  # rather `terraform destroy` clean up.
  delete_script = "# Intentionally left installed."

  input_data = jsonencode({
    minimum_version = var.minimum_version
  })
}

output "module_version" {
  value = jsondecode(powershell_script.exchange_online_management.output_data).version
}

output "module_path" {
  description = "Feed this to the exchangeonlinemanagement provider's module_path if it is not on the default PSModulePath."
  value       = jsondecode(powershell_script.exchange_online_management.output_data).path
}
```

Apply it once per machine, then apply your real configuration:

```console
$ terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply
$ terraform init && terraform apply
```

### The lighter alternative

If you do not want a second provider, `terraform_data` with a `local-exec`
provisioner does the install with nothing extra to download:

```terraform
resource "terraform_data" "exchange_online_management" {
  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PS
      if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement |
                Where-Object Version -ge ([version]'3.0.0'))) {
          Install-Module ExchangeOnlineManagement -MinimumVersion 3.0.0 `
              -Scope CurrentUser -Force -Confirm:$false
      }
    PS
  }
}
```

The trade-off: a provisioner runs once at create time and is never re-checked,
so if the module is later removed Terraform will not notice. The same
"separate root module, separate apply" rule applies.

## Verifying

```powershell
Get-Module -ListAvailable ExchangeOnlineManagement |
    Select-Object Version, ModuleBase
```

If that lists 3.0.0 or later and the path is on your `PSModulePath`, the
provider will find it. Next: [Registering the Entra
application](app-registration).
