---
page_title: "exchangeonlinemanagement_mailbox Data Source"
description: |-
  Looks up an Exchange Online mailbox by user principal name, Entra object ID
  or email address, and returns its details.
---

# exchangeonlinemanagement_mailbox (Data Source)

Looks up a mailbox that already exists in the tenant — whether or not Terraform
manages it — and exposes its details.

Set **exactly one** of `user_principal_name`, `object_id` or `email_address`.
A Terraform schema cannot express "exactly one of", so the provider enforces it
and fails with a clear message if you set none or several.

A mailbox that does not exist is **not an error**. Check `found` before using
anything else; every other attribute is null when it is `false`.

## Example Usage

```terraform
data "exo_mailbox" "sales" {
  email_address = "sales@contoso.com"
}

output "sales_object_id" {
  value = data.exo_mailbox.sales.external_directory_object_id
}
```

Guarding on `found`:

```terraform
data "exo_mailbox" "maybe" {
  user_principal_name = var.candidate_upn
}

resource "exo_cas_mailbox" "maybe" {
  count = data.exo_mailbox.maybe.found ? 1 : 0

  identity    = data.exo_mailbox.maybe.mailbox_guid
  pop_enabled = false
}
```

Reaching a property this data source does not model, via `mailbox_json`:

```terraform
locals {
  mailbox = jsondecode(data.exo_mailbox.sales.mailbox_json)
}

output "office" {
  value = local.mailbox.Office
}
```

Finding the GUID to import with:

```terraform
output "import_command" {
  value = "terraform import exo_mailbox.sales ${data.exo_mailbox.sales.mailbox_guid}"
}
```

## Schema

### Optional — set exactly one

- `user_principal_name` (String) Look up by user principal name, e.g.
  `sales@contoso.com`.
- `object_id` (String) Look up by Entra ID object ID (the mailbox's
  `ExternalDirectoryObjectId`).
- `email_address` (String) Look up by any of the mailbox's SMTP addresses,
  primary or secondary.

### Read-Only

- `found` (Boolean) Whether a mailbox matched. **Check this first** — every
  attribute below is null when it is `false`.
- `mailbox_guid` (String) The mailbox's Exchange directory GUID. This is the
  value `exchangeonlinemanagement_mailbox` uses as its `id`, so it is what to
  pass to `terraform import`.
- `exchange_guid` (String) The mailbox's Exchange GUID.
- `external_directory_object_id` (String) The mailbox's Entra ID object ID —
  the same value the `object_id` lookup takes.
- `effective_user_principal_name` (String) The mailbox's UPN. Named
  `effective_` because `user_principal_name` is a lookup attribute, and one
  attribute cannot be both input and output.
- `primary_smtp_address` (String) The primary SMTP address.
- `email_addresses` (Set of String) Every proxy address, prefix included
  (`SMTP:`, `smtp:`, `SIP:`, `SPO:`).
- `name` (String) The mailbox name.
- `display_name` (String) The display name.
- `alias` (String) The alias.
- `recipient_type` (String) Exchange's broad classification, e.g.
  `UserMailbox`.
- `recipient_type_details` (String) Exchange's specific classification:
  `SharedMailbox`, `UserMailbox`, `RoomMailbox`, `EquipmentMailbox`, ...
- `hidden_from_address_lists` (Boolean) Whether the mailbox is hidden from
  address lists.
- `litigation_hold_enabled` (Boolean) Whether it is on litigation hold.
- `is_directory_synced` (Boolean) Whether the object is synced from
  on-premises Active Directory.
- `deliver_to_mailbox_and_forward` (Boolean) Whether forwarded mail is also
  kept in the mailbox.
- `forwarding_smtp_address` (String) The external forwarding address, if set.
- `retention_policy` (String) The retention policy applied.
- `issue_warning_quota`, `prohibit_send_quota`,
  `prohibit_send_receive_quota`, `max_send_size`, `max_receive_size` (String)
  Quotas and limits, as Exchange reports them (e.g.
  `"49 GB (52,613,349,376 bytes)"`).
- `custom_attributes` (Map of String) Exchange custom attributes 1 through 15,
  keyed `"1"` .. `"15"`. Attributes with no value are omitted.
- `when_created` (String) Creation time, UTC, ISO 8601.
- `mailbox_json` (String, JSON) The whole `Get-Mailbox` object, for the many
  properties not modelled above. Read it with `jsondecode()`.

## About `mailbox_json`

Values are normalised so state stays stable across refreshes and across
machines: dates become ISO 8601 strings, multi-valued properties become string
arrays, and anything else is stringified. Keys are sorted, so the encoded JSON
does not reorder between plans.

It is an escape hatch, not a contract — the property set depends on the
Exchange Online build and on your tenant's licensing, so a key present today
may not be tomorrow. Use `try()` or `lookup()` when reading from it in anything
you care about:

```terraform
locals {
  office = try(jsondecode(data.exo_mailbox.sales.mailbox_json).Office, null)
}
```
