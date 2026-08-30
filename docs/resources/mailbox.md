---
page_title: "exchangeonlinemanagement_mailbox Resource"
description: |-
  Manages an Exchange Online mailbox with New-Mailbox, Get-Mailbox, Set-Mailbox
  and Remove-Mailbox.
---

# exchangeonlinemanagement_mailbox (Resource)

Manages an Exchange Online mailbox.

Best suited to **shared, room and equipment** mailboxes, which Exchange itself
provisions. User mailboxes in Exchange Online are normally created by licensing
a user in Entra ID rather than by `New-Mailbox`; `type = "user"` is supported
but see [User mailboxes](#user-mailboxes) before reaching for it.

## Example Usage

```terraform
resource "exo_mailbox" "sales" {
  name         = "sales"
  type         = "shared"
  display_name = "Sales Team"
  alias        = "sales"

  hidden_from_address_lists = false
  max_send_size             = "35 MB"
  grant_send_on_behalf_to   = ["marketing@contoso.com"]

  custom_attributes = {
    "1" = "finance"
    "3" = "eu-west"
  }
}

resource "exo_mailbox" "boardroom" {
  name              = "boardroom"
  type              = "room"
  display_name      = "Boardroom (12 seats)"
  resource_capacity = 12
}
```

### Anything not modelled here

`additional_parameters` is splatted onto `Set-Mailbox` after every attribute
above, and wins over them:

```terraform
resource "exo_mailbox" "sales" {
  name = "sales"

  additional_parameters = jsonencode({
    Office                            = "HQ"
    RequireSenderAuthenticationEnabled = false
  })
}
```

Keys are `Set-Mailbox` parameter names. Terraform cannot validate them, they
are not reflected in any `effective_*` attribute, and a typo surfaces as an
Exchange error at apply time.

## Schema

### Required

- `name` (String) The mailbox name. Changing it renames the mailbox in place —
  the resource is keyed on the mailbox GUID, so a rename is not a recreate.

### Optional

- `type` (String) `shared` (default), `room`, `equipment` or `user`. Changing
  it converts the mailbox in place with `Set-Mailbox -Type`.
- `alias` (String) Mail alias. Exchange derives one if unset; read it back from
  `effective_alias`.
- `display_name` (String) Display name in address lists. Read it back from
  `effective_display_name`.
- `primary_smtp_address` (String) The primary SMTP address, applied after
  creation. Leave unset to let Exchange derive it, then read
  `effective_primary_smtp_address`.
- `email_addresses` (Set of String) The **complete** proxy-address list, e.g.
  `["SMTP:sales@contoso.com", "smtp:sales@contoso.onmicrosoft.com"]`.
  Uppercase `SMTP:` marks the primary. Authoritative — setting it replaces
  every existing address, so include the ones Exchange added itself (read
  `effective_email_addresses` first). Leave unset to manage addresses outside
  Terraform.
- `hidden_from_address_lists` (Boolean) Hide the mailbox from address lists.
- `custom_attributes` (Map of String) Exchange custom attributes, keyed `"1"`
  through `"15"`. Any other key is an error.
- `litigation_hold_enabled` (Boolean) Place the mailbox on litigation hold.
  Requires the appropriate licence.
- `litigation_hold_duration_days` (Number) Retention period for litigation
  hold, in days.
- `retention_policy` (String) Name of an existing retention policy.
- `issue_warning_quota` (String) Exchange size string, e.g. `"49 GB"`.
- `prohibit_send_quota` (String) Exchange size string, e.g. `"49.5 GB"`.
- `prohibit_send_receive_quota` (String) Exchange size string, e.g. `"50 GB"`.
- `max_send_size` (String) Exchange size string, e.g. `"35 MB"`.
- `max_receive_size` (String) Exchange size string, e.g. `"36 MB"`.
- `grant_send_on_behalf_to` (Set of String) Recipients allowed to send on
  behalf of this mailbox. Authoritative.
- `forwarding_smtp_address` (String) External forwarding address.
- `deliver_to_mailbox_and_forward` (Boolean) Keep a copy when forwarding.
- `resource_capacity` (Number) Seating capacity of a room or equipment mailbox.
- `user_principal_name` (String) UPN for a `type = "user"` mailbox.
  **Create-only** — see [User mailboxes](#user-mailboxes).
- `password` (String, **Sensitive**) Initial password for a `type = "user"`
  mailbox. Used only at creation, never read back or reconciled; changing it
  has no effect.
- `permanently_delete` (Boolean, default `false`) On destroy, pass
  `Remove-Mailbox -PermanentlyDelete`. See [Destroying](#destroying).
- `additional_parameters` (String, JSON) Extra `Set-Mailbox` parameters.

### Read-Only

- `id` (String) The mailbox GUID, or whatever identity value it was imported
  with.
- `exchange_guid` (String) The mailbox's Exchange GUID.
- `external_directory_object_id` (String) The mailbox's Entra ID object ID.
- `effective_primary_smtp_address` (String) The primary SMTP address Exchange
  resolved.
- `effective_alias` (String) The alias Exchange resolved.
- `effective_display_name` (String) The display name Exchange resolved.
- `effective_user_principal_name` (String) The mailbox's current UPN.
- `effective_email_addresses` (Set of String) Every proxy address, including
  the `SIP:` and `SPO:` entries Exchange adds itself.
- `recipient_type_details` (String) `SharedMailbox`, `UserMailbox`,
  `RoomMailbox`, `EquipmentMailbox`, ...
- `distinguished_name` (String) DN in the Exchange directory.
- `is_directory_synced` (Boolean) Whether the object is synced from
  on-premises AD. Synced objects cannot be fully managed from Exchange Online.
- `when_created` (String) Creation time, UTC, ISO 8601.

## The `effective_*` attributes

Terraform never reports drift on a configuration attribute of this resource —
the provider refreshes computed attributes from the tenant but never rewrites
configuration attributes from it. The `effective_*` mirrors are refreshed, so
they are where an out-of-band change becomes visible:

```terraform
check "sales_display_name" {
  assert {
    condition     = exo_mailbox.sales.effective_display_name == "Sales Team"
    error_message = "The sales mailbox display name was changed outside Terraform."
  }
}
```

They are also the only way to read a value you did not set — Exchange derives
the alias and primary SMTP address when you leave them unset.

## User mailboxes

`type = "user"` requires `user_principal_name` and `password`, and calls
`New-Mailbox -MicrosoftOnlineServicesID`. Before using it:

- In Exchange Online, user mailboxes are normally provisioned by assigning a
  licence to a user in Entra ID. That is the supported path, and it is what
  Microsoft's tooling assumes.
- The UPN belongs to Entra ID, not to `Set-Mailbox`. Changing
  `user_principal_name` on an existing resource **fails at apply time** with an
  explanatory error rather than silently doing nothing. Change the user in
  Entra ID and update the configuration to match, or force a recreate with
  `terraform apply -replace=...` — which deletes the mailbox and its contents.
- `Remove-Mailbox` on a licensed user mailbox usually fails; delete the Entra
  user instead. The provider does not paper over the Exchange error.

## Destroying

`terraform destroy` runs `Remove-Mailbox`, which **soft-deletes** the mailbox.
Exchange retains it for 30 days, which can collide with recreating a mailbox of
the same name or alias. Set `permanently_delete = true` to pass
`-PermanentlyDelete` and skip the soft-delete retention.

## Import

Import by mailbox GUID, UPN, primary SMTP address or alias — anything
`Get-Mailbox -Identity` accepts:

```shell
terraform import exo_mailbox.sales sales@contoso.com
```

Two things to expect afterwards:

- The `id` keeps whatever value you imported with. The provider cannot
  renormalise it, so importing by address leaves the address as the `id`
  permanently. Import by GUID (see the
  [`exchangeonlinemanagement_mailbox` data source](../data-sources/mailbox)'s
  `mailbox_guid`) if you want a GUID `id`.
- Importing populates only `id`. Every configuration attribute starts null, so
  the first plan shows all of them being set and the first apply pushes them to
  the tenant. Run a plan and reconcile your HCL with the tenant before applying
  — no attribute on this resource forces replacement (precisely so that this
  first apply cannot destroy a live mailbox), but the apply *will* write your
  configuration over what is there.
