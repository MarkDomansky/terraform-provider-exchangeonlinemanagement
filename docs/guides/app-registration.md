---
page_title: "Registering the Entra application"
description: |-
  Create the Entra ID app registration, certificate, API permission and
  Exchange role assignment that the exchangeonlinemanagement provider needs for
  certificate-based app-only authentication.
---

# Registering the Entra application

The provider authenticates to Exchange Online with **certificate-based app-only
authentication**: an Entra ID application, a certificate it owns, and an
Exchange administrative role assigned to its service principal. No user
account, no password, no interactive sign-in.

There are four things to set up, and all four are required — missing any one
produces an authentication or authorisation failure at `terraform plan` time:

1. An app registration.
2. A certificate, uploaded to the app registration.
3. The **`Exchange.ManageAsApp`** application permission, with admin consent.
4. An Exchange **role** assigned to the application's service principal.

Step 4 is the one people miss. The API permission grants the *ability* to
call Exchange PowerShell as an application; the role grants the *authority* to
change anything. Without it you connect successfully and then get access-denied
errors on every cmdlet.

You need Global Administrator (or Privileged Role Administrator plus
Application Administrator) to complete steps 3 and 4.

## 1. Create the certificate

The application keeps the **public** certificate; the machine running Terraform
keeps the **private** key. Pick the form matching how you will configure the
provider.

### Windows: certificate store (for `certificate_thumbprint`)

```powershell
$cert = New-SelfSignedCertificate `
    -Subject 'CN=terraform-exchangeonline' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(2)

# Upload this file to the app registration.
Export-Certificate -Cert $cert -FilePath .\terraform-exchangeonline.cer | Out-Null

# This is the value for the provider's certificate_thumbprint.
$cert.Thumbprint
```

The certificate must be in the store of the **account that runs Terraform**.
An unattended agent running as a service account will not see a certificate you
created interactively as yourself.

### Any platform: PFX file (for `certificate_path`)

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 730 -nodes \
    -keyout exo.key -out exo.cer \
    -subj "/CN=terraform-exchangeonline"

# The provider reads this file; protect it like the private key it contains.
openssl pkcs12 -export -out exo.pfx -inkey exo.key -in exo.cer
```

Or from the Windows certificate above:

```powershell
$password = Read-Host 'PFX password' -AsSecureString
Export-PfxCertificate -Cert $cert -FilePath .\exo.pfx -Password $password | Out-Null
```

Either way you upload **`.cer`** (public) to Entra and keep **`.pfx`**
(private) on the Terraform machine.

## 2. Register the application

Portal: **Microsoft Entra admin center → Identity → Applications → App
registrations → New registration**. Name it something recognisable
(`terraform-exchangeonline`), choose **Accounts in this organizational
directory only**, leave the redirect URI empty, and register.

Copy the **Application (client) ID** — that is the provider's `app_id`.

Then **Certificates & secrets → Certificates → Upload certificate**, and upload
the `.cer` from step 1. Do **not** create a client secret; this provider cannot
use one (see [Not supported](#why-not-a-client-secret)).

Or with the Microsoft Graph PowerShell module:

```powershell
Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'

$cer = [Convert]::ToBase64String(
    [IO.File]::ReadAllBytes((Resolve-Path .\terraform-exchangeonline.cer)))

$app = New-MgApplication -DisplayName 'terraform-exchangeonline' -KeyCredentials @(
    @{ Type = 'AsymmetricX509Cert'; Usage = 'Verify'; Key = [Convert]::FromBase64String($cer) }
)
$sp = New-MgServicePrincipal -AppId $app.AppId

"app_id: $($app.AppId)"
```

## 3. Grant the Exchange.ManageAsApp permission

Portal: **API permissions → Add a permission → APIs my organization uses →
Office 365 Exchange Online → Application permissions →
`Exchange.ManageAsApp`**, add it, then **Grant admin consent for \<tenant\>**.

Two things to get right:

- It is under **Office 365 Exchange Online**, not Microsoft Graph.
- It must be an **Application** permission, not Delegated.

The permission is inert until admin consent is granted — the API permissions
list will show a warning until you do.

## 4. Assign an Exchange role

Portal: **Entra admin center → Identity → Roles & admins**, open **Exchange
Administrator**, then **Add assignments** and pick your application by name.

`Exchange Administrator` is the broad option. To follow least privilege, create
a custom Exchange role group containing only what the provider needs — for
managing mailboxes and client access settings, the **Mail Recipients**,
**Mail Recipient Creation** and **Recipient Policies** roles cover
`New-Mailbox`, `Set-Mailbox`, `Remove-Mailbox` and `Set-CASMailbox`:

```powershell
# In Exchange Online PowerShell, as an administrator:
New-RoleGroup -Name 'Terraform Mailbox Management' `
    -Roles 'Mail Recipients', 'Mail Recipient Creation', 'Recipient Policies'

Add-RoleGroupMember -Identity 'Terraform Mailbox Management' `
    -Member '<the service principal object id>'
```

Role assignments can take a few minutes to take effect. An authentication that
succeeds but reports access denied on every cmdlet usually means step 4 has not
propagated yet.

## 5. Configure the provider

```terraform
provider "exo" {
  organization           = "contoso.onmicrosoft.com"
  app_id                 = "36ee4c6c-0812-40a2-b820-b22ebd02bce3"
  certificate_thumbprint = "83213AEAC56D61C97AEE5C1528F4AC5EBA7321C1"
}
```

or, cross-platform:

```terraform
provider "exo" {
  organization         = "contoso.onmicrosoft.com"
  app_id               = "36ee4c6c-0812-40a2-b820-b22ebd02bce3"
  certificate_path     = "/etc/terraform/exo.pfx"
  certificate_password = var.certificate_password
}
```

`organization` is the tenant's primary `.onmicrosoft.com` domain, not a custom
domain and not the tenant GUID.

Everything here also reads from the environment, which is usually what you want
in CI:

```bash
export EXO_ORGANIZATION=contoso.onmicrosoft.com
export EXO_APP_ID=36ee4c6c-0812-40a2-b820-b22ebd02bce3
export EXO_CERTIFICATE_PATH=/etc/terraform/exo.pfx
export EXO_CERTIFICATE_PASSWORD=...
```

## Verifying before you run Terraform

Connect by hand with the same credentials. If this works, the provider will:

```powershell
Connect-ExchangeOnline `
    -AppId '36ee4c6c-0812-40a2-b820-b22ebd02bce3' `
    -CertificateThumbprint '83213AEAC56D61C97AEE5C1528F4AC5EBA7321C1' `
    -Organization 'contoso.onmicrosoft.com' `
    -ShowBanner:$false

Get-Mailbox -ResultSize 1    # proves the role assignment, not just the sign-in
Disconnect-ExchangeOnline -Confirm:$false
```

`Connect-ExchangeOnline` succeeding proves steps 1–3. Only a cmdlet that
actually touches data proves step 4.

## Certificate rotation

Certificates expire, and an expired one fails every Terraform run against the
tenant. To rotate without downtime: create the new certificate, upload it to
the app registration alongside the old one (Entra accepts several), switch the
provider's `certificate_thumbprint` / `certificate_path`, verify, then remove
the old certificate from the app registration.

## Why not a client secret?

`Connect-ExchangeOnline` has no `-ClientSecret` parameter. Using a secret would
require acquiring an OAuth token out-of-band and passing it as `-AccessToken`,
which means the provider owning token acquisition and renewal for a session
that may outlive the token. Certificate-based authentication is Microsoft's
documented approach for unattended Exchange Online scripting, and
`Connect-ExchangeOnline` renews those sessions itself — so that is what this
provider supports.
