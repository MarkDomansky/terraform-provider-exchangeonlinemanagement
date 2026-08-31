---
page_title: "exchangeonlinemanagement_cas_mailbox Resource"
description: |-
  Manages the client access settings of an existing Exchange Online mailbox -
  which protocols it can be reached over - with Get-CASMailbox and
  Set-CASMailbox.
---

# exchangeonlinemanagement_cas_mailbox (Resource)

Manages the **client access settings** of an existing mailbox: which protocols
it can be reached over — OWA, ActiveSync, POP3, IMAP4, MAPI, EWS — and the
policies applied to them.

There is no `New-CASMailbox` or `Remove-CASMailbox`. These are properties of a
mailbox this resource does not own, which shapes its lifecycle:

- **Create** resolves the mailbox and applies the settings you configured.
- **Destroy** removes the resource from state and, by default, **leaves the
  settings in place**. See [Destroying](#destroying).
- Settings you do not configure are never touched — omitting `pop_enabled`
  means "not managed", never "set it to false".

## Example Usage

```terraform
resource "exo_mailbox" "sales" {
  name = "sales"
  type = "shared"
}

# Turn off the legacy protocols on that mailbox.
resource "exo_cas_mailbox" "sales" {
  identity = exo_mailbox.sales.id

  pop_enabled                         = false
  imap_enabled                        = false
  activesync_enabled                  = false
  smtp_client_authentication_disabled = true

  # Leave OWA and MAPI alone: not listed, not managed.
}
```

Applied to a mailbox this configuration does not create:

```terraform
resource "exo_cas_mailbox" "exec" {
  identity           = "exec@contoso.com"
  owa_mailbox_policy = "Contoso-Restricted"

  # Undo it on destroy rather than leaving the policy applied.
  revert_on_destroy = true
  revert_values = {
    OwaMailboxPolicy = "Contoso-Default"
  }
}
```

## Schema

### Required

- `identity` (String) The mailbox to configure: a UPN, primary SMTP address,
  alias or GUID — anything `Get-CASMailbox -Identity` accepts. The mailbox must
  already exist.

### Optional — protocols

- `activesync_enabled` (Boolean) Allow Exchange ActiveSync.
- `owa_enabled` (Boolean) Allow Outlook on the web.
- `owa_for_devices_enabled` (Boolean) Allow the Outlook on the web mobile apps.
- `pop_enabled` (Boolean) Allow POP3.
- `imap_enabled` (Boolean) Allow IMAP4.
- `mapi_enabled` (Boolean) Allow MAPI — how the Outlook desktop client
  connects.
- `ews_enabled` (Boolean) Allow Exchange Web Services. Unset on the mailbox
  means "inherit the organisation setting".
- `pop_use_protocol_defaults` (Boolean) Use the organisation's POP3 defaults.
- `imap_use_protocol_defaults` (Boolean) Use the organisation's IMAP4 defaults.
- `smtp_client_authentication_disabled` (Boolean) Disable authenticated SMTP
  (SMTP AUTH). Unset means "inherit the tenant-wide `Set-TransportConfig`
  setting".

### Optional — policies and lists

- `activesync_mailbox_policy` (String) Name of an existing mobile device
  mailbox policy.
- `owa_mailbox_policy` (String) Name of an existing Outlook on the web mailbox
  policy.
- `activesync_allowed_device_ids` (Set of String) Device IDs allowed to sync.
  Authoritative.
- `activesync_blocked_device_ids` (Set of String) Device IDs blocked from
  syncing. Authoritative.
- `ews_allow_outlook` (Boolean) Allow Outlook to use EWS.
- `ews_allow_mac_outlook` (Boolean) Allow Outlook for Mac to use EWS.
- `ews_application_access_policy` (String) `EnforceAllowList` or
  `EnforceBlockList`.
- `ews_allow_list` (Set of String) EWS user-agent strings permitted under
  `EnforceAllowList`.
- `ews_block_list` (Set of String) EWS user-agent strings denied under
  `EnforceBlockList`.

### Optional — lifecycle

- `revert_on_destroy` (Boolean, default `false`) Restore Exchange's defaults
  for the managed settings on destroy. See [Destroying](#destroying).
- `revert_values` (String, JSON) Overrides the built-in table of Exchange
  defaults used by `revert_on_destroy`, as `Set-CASMailbox` parameter names.
- `additional_parameters` (String, JSON) Extra `Set-CASMailbox` parameters,
  splatted after everything above and winning over it. Not validated by
  Terraform, not reflected in any `effective_*` attribute, and **not** undone
  by `revert_on_destroy`.

### Read-Only

- `id` (String) The mailbox GUID, or whatever identity value it was imported
  with.
- `external_directory_object_id` (String) The mailbox's Entra ID object ID.
- `effective_primary_smtp_address` (String) Primary SMTP address of the mailbox
  being configured — useful for confirming `identity` resolved to what you
  expected.
- `effective_display_name` (String) Display name of that mailbox.
- `effective_activesync_enabled`, `effective_owa_enabled`,
  `effective_pop_enabled`, `effective_imap_enabled`, `effective_mapi_enabled`
  (Boolean) The live protocol states.
- `effective_ews_enabled` (Boolean) Live EWS state; `null` when the mailbox
  inherits the organisation setting.
- `effective_smtp_client_authentication_disabled` (Boolean) Live SMTP AUTH
  state; `null` when the mailbox inherits the tenant-wide setting.
- `effective_activesync_mailbox_policy`, `effective_owa_mailbox_policy`
  (String) The policies currently applied.
- `effective_activesync_blocked_device_ids`,
  `effective_activesync_allowed_device_ids` (Set of String) The live device
  lists.

## Detecting drift

Terraform never reports a diff on a configuration attribute of this resource;
the provider refreshes computed attributes from the tenant but never rewrites
configuration attributes from it. The `effective_*` mirrors are refreshed, which
makes them the right thing to assert on for security-relevant settings:

```terraform
check "sales_legacy_auth_stays_off" {
  assert {
    condition = alltrue([
      exo_cas_mailbox.sales.effective_pop_enabled == false,
      exo_cas_mailbox.sales.effective_imap_enabled == false,
    ])
    error_message = "A legacy protocol was re-enabled on the sales mailbox outside Terraform."
  }
}
```

An out-of-band change is still corrected by the next apply that touches the
resource — it just is not reported beforehand.

## Destroying

By default, destroying this resource **only removes it from Terraform state**.
The mailbox keeps its settings, so hardening applied here survives a
`terraform destroy`. That is deliberate: the resource does not own the mailbox,
and re-enabling protocols on someone else's mailbox is not something to do
implicitly.

Set `revert_on_destroy = true` to have the destroy restore Exchange's defaults:

| Setting | Reverted to |
|---|---|
| `activesync_enabled`, `owa_enabled`, `owa_for_devices_enabled`, `pop_enabled`, `imap_enabled`, `mapi_enabled` | `true` |
| `pop_use_protocol_defaults`, `imap_use_protocol_defaults` | `true` |
| `ews_enabled`, `smtp_client_authentication_disabled` | `null` (inherit the organisation/tenant setting) |
| `activesync_mailbox_policy` | `Default` |
| `owa_mailbox_policy` | `OwaMailboxPolicy-Default` |
| the device ID and EWS lists | `null` (cleared) |

Only settings **this resource actually configured** are reverted; the rest are
left alone.

The policy-name defaults are tenant-specific, so override them with
`revert_values` when they are wrong for you:

```terraform
revert_values = jsonencode({
  OwaMailboxPolicy        = "Contoso-Default"
  ActiveSyncMailboxPolicy = "Contoso-Mobile-Default"
})
```

The resource cannot instead snapshot the pre-existing values and restore
them: destroy scripts receive only configuration attributes, never computed
ones, so a captured "original settings" attribute would not be available when
it mattered. `revert_values` is the honest alternative.

## Import

Import by mailbox GUID, UPN, primary SMTP address or alias:

```shell
terraform import exo_cas_mailbox.sales sales@contoso.com
```

As with the mailbox resource, importing populates only `id` — every
configuration attribute starts null, so the first plan shows them all being set
and the first apply writes them to the tenant. Reconcile your HCL with the live
settings (read them with `Get-CASMailbox`) before applying.
