# Repo rules (for humans and AI assistants)

* This repo is built from the TEMPLATE-terraform-provider-YOURPROVIDER
  template. Everything under `.template/` is owned by the template and updated
  via template-sync PRs — never edit it — as are the root files carrying a
  "MANAGED FILE" header (the workflows, `go.mod`/`main.go`/`main_test.go`,
  `.releaserc.cjs` — a shim requiring `.template/release/releaserc.cjs` —
  `.gitignore`, and `docs/guides/writing-resources.md`). Everything else under
  `provider/`, `docs/`, `examples/`, and `tests/e2e/` is fork-owned.
* Resources are folders of PowerShell scripts + resource.tfps.json under
  `provider/resources/`; the authoring contract is in
  docs/guides/writing-resources.md. CRUD scripts (and a data source's
  `read.ps1`) declare `param([hashtable]$InputData)` — the engine binds it by
  name and passes nothing else, so no other parameter may be `Mandatory` and
  `$Action` must never be a parameter. Lifecycle scripts
  (`provider/scripts/startup.ps1`, `shutdown.ps1`) must have no param block at
  all. Every script must emit exactly one object and keep the error stream
  clean.
* Keep unit tests cross-platform (Windows/Linux/macOS, PowerShell 7).

## Commit messages decide the released version

Versions are **not** set by hand. `semantic-release` reads the commit messages
on the pushed branch and computes the next version
(`.github/workflows/release.yml`, configured by `.releaserc.cjs`). Never edit
a version string by hand and never create a `v*` tag manually — the release
workflow creates the tag itself, only after the install smoke test passes.

* Squash-merge PRs into `beta` (prereleases); merge `beta` into `main` with a
  REAL merge commit (never squash) for GA.
* Only `main` ever publishes the wiki (`wiki-sync.yml` asserts this in the
  job's `if:` as well as its trigger — do not relax either).

## Repo-local notes

If `REPO-NOTES.md` exists at the repo root, read it too. This file is a
MANAGED file replaced wholesale by every template sync, so anything specific
to one repository — local exceptions to the rules above, house conventions,
environment quirks — belongs in `REPO-NOTES.md`, which the sync never touches.

## Engine dependency

The terraform-provider-powershell engine version is resolved at build time by
`.template/build/Update-Engine.ps1` from `provider/settings.tfps.json` (`"latest"` GA or an
exact pin). go.mod's require line is a baseline, not the truth — do not bump
it by hand; change `engine_version` instead.
