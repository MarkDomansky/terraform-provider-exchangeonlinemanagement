# Repo-local notes

Fork-owned; template sync never touches this file. Conventions and quirks
specific to `terraform-provider-exchangeonlinemanagement` live here, and the
general rules stay in `CLAUDE.md`.

## Shared PowerShell lives in `startup.ps1`

Provider scripts are embedded in the Go binary and `$PSScriptRoot` is empty at
runtime, so there is no way to dot-source a library file. Everything shared
between the CRUD scripts is defined as a `function global:` by
`provider/scripts/startup.ps1`, which runs once per Terraform run and whose
globals persist because the PowerShell process is persistent.

Add new shared code there, not to a new file:

| Function | Purpose |
|---|---|
| `Test-EXONotFound` | Is this error "the recipient does not exist"? |
| `Get-EXOMailboxOrNull`, `Get-EXOCASMailboxOrNull` | Lookup where not-found is `$null`, and everything else rethrows |
| `Add-EXOParam` | Copy an `$InputData` key into a splat only when it is present |
| `ConvertTo-EXOSplat` | A `json` attribute to a splattable hashtable |
| `ConvertTo-EXOStringArray`, `ConvertTo-EXONullableBool`, `ConvertTo-EXODateString` | Type projections the engine requires |
| `New-EXOMailboxSetSplat`, `New-EXOCASSetSplat` | Build the `Set-*` splats, shared by create and update |
| `Get-EXOCASDefault` | Attribute to (`Set-CASMailbox` parameter, Exchange default) |
| `ConvertTo-EXOMailboxState`, `ConvertTo-EXOCASState` | The single projection to computed attributes |

## Invariants that look like style but are not

- **No attribute may declare `requires_replace`.** `terraform import` writes
  only `id` and a read script cannot write config attributes, so post-import
  state has every config attribute null — a `requires_replace` attribute would
  plan the destruction of a live mailbox on the first apply. Immutable fields
  are guarded with a compare-then-throw in `update.ps1` instead. Both resources'
  unit tests assert this.
- **Almost nothing gets a manifest `default`.** `delete.ps1` and the splat
  builders use `$InputData.ContainsKey(...)` to mean "this resource manages
  that setting", and a default makes the key always present. Only `type`,
  `permanently_delete` and `revert_on_destroy` have one, and the tests pin that
  list. A `default` on a provider attribute additionally makes its `env`
  fallback dead code, because the default is applied first.
- **`Test-EXONotFound` must stay narrow.** `read.ps1` turns a true result into
  "emit nothing", which tells Terraform the object is gone. A match broad
  enough to catch a 429 or an expired token would destroy and recreate live
  mailboxes. Both resources have a test asserting a throttling error is *not*
  swallowed.
- **Every mutating splat carries `Confirm = $false`.** These cmdlets have a
  high `ConfirmImpact`, and a prompt in the sidecar's non-interactive host
  blocks until the operation timeout and then fails opaquely.

## Testing

Unit tests replace the Exchange cmdlets with **global stub functions**
(`tests/support/EXOTestStubs.psm1`), not Pester `Mock`. The ScriptUnit harness
runs CRUD scripts inside its own module with `[scriptblock]::Create` + `&`, so
a plain `Mock Get-Mailbox { }` in a test file is never seen by the script and
the test passes for the wrong reason. Global functions are visible from both
the test's scope and the harness module's.

Also:

- Simulate failures with `throw`, never `Write-Error` — the engine fails any
  operation that writes to the error stream.
- Each test file dot-sources the real `startup.ps1` so the tests exercise the
  actual shared helpers rather than doubles of them.
- Pester 5 does not allow a `BeforeEach` at the root of a file; each `Describe`
  calls the file's `Initialize-EXOTest`.
- The `ExchangeOnlineManagement` module may well be installed on the test
  machine, and `Get-Command` will auto-load it. The "module is not installed"
  test therefore runs in a child `pwsh` with a scrubbed `PSModulePath`.

## Local development

`go.work` in this repo (gitignored) points at the engine checkout at
`../terraform-provider-powershell`. It has to be here rather than in the parent
`c:\prj\PSTerraform\go.work`: forks keep the template's module path, so this
repo and the template are the same Go module and cannot share a workspace. Go
uses the nearest `go.work` walking up from the working directory.

While the engine is pre-GA this matters — `go.mod` pins a version that predates
the `*.tfps.json` manifest rename and cannot load these manifests.

## Exchange facts still to confirm against a live tenant

The Exchange cmdlets only exist after `Connect-ExchangeOnline` builds the REST
session, so their parameters cannot be verified offline. These are used by the
provider but unproven; `tests/e2e/Mailbox.Tests.ps1` is where they get settled:

- `Set-Mailbox -Type` — the accepted values and which conversions are allowed.
- `Set-Mailbox -ResourceCapacity` and `-WindowsEmailAddress`.
- `Get-CASMailbox`'s true default for `EwsEnabled` (`$true` vs `$null`), which
  determines the right `revert_on_destroy` target.
- `Set-CASMailbox -ActiveSyncBlockedDeviceIDs $null` as the "clear it" idiom.
- `Remove-Mailbox -PermanentlyDelete` against a mailbox that is not already
  soft-deleted.
- The exact shape of a "not found" error, which `Test-EXONotFound` keys on.
