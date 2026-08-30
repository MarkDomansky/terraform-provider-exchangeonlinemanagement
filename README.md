# Terraform Provider Template (PowerShell-backed)

Build a **real, typed Terraform provider** where every resource is a folder of
PowerShell scripts plus a small JSON manifest — no Go required. This template
rides on the [terraform-provider-powershell](https://github.com/markdomansky/terraform-provider-powershell)
engine: a persistent PowerShell 7 sidecar (bundled in every release, no
PowerShell install needed at runtime) executes your CRUD scripts, while the
engine turns your manifests into real terraform-plugin-framework schemas —
per-attribute plan diffs, validation, sensitivity, import, the works.

```text
provider/
├── settings.tfps.json           # your provider's name + registry address
├── provider.tfps.json           # custom provider-block attributes (optional)
├── scripts/startup.ps1          # connect/authenticate once per run (optional)
├── scripts/shutdown.ps1         # disconnect once per run (optional)
├── resources/
│   └── mailbox/                 # => resource "yourprovider_mailbox"
│       ├── resource.tfps.json   #    typed attributes
│       ├── create.ps1           #    $InputData in, one object out
│       ├── read.ps1
│       ├── update.ps1           #    optional: presence enables in-place update
│       ├── delete.ps1
│       └── tests/*.Tests.ps1    #    Pester unit tests (mock your cmdlets)
└── data-sources/
    └── mailbox/                 # => data "yourprovider_mailbox"
        ├── datasource.tfps.json
        └── read.ps1
```

Each `*.tfps.json` carries a `"$schema"` pointer to its published
[SchemaStore](https://www.schemastore.org) schema, so editors give you
completion and validation as you type. The distinctive filenames also let
editors associate the schemas automatically, with no `$schema` key at all.

## Quickstart

1. Create your repo from this template ("Use this template", or fork — see
   [SETUP.md](SETUP.md)), create a `beta` branch.
2. `./.template/build/Initialize-Fork.ps1 -Name yourprovider -Namespace yourgithubname`
3. Study the working sample in `provider/resources/example_file/`, then
   scaffold your own: `./.template/build/New-Resource.ps1 -Name mailbox`
4. Test: `pwsh ./.template/tests/unit/Invoke-UnitTests.ps1`, then
   `./.template/build/Build-Provider.ps1` + `Invoke-Pester ./tests/e2e`
5. Delete the `example_file` sample folders and release via PRs to `beta`.

Full walkthrough: **[SETUP.md](SETUP.md)**. Authoring reference (script
contract, manifest format): **[docs/guides/writing-resources.md](docs/guides/writing-resources.md)**.

## What you edit vs. what the template manages

The rule: **everything under `.template/` is managed** — build scripts, test
harnesses, and release configs (including `terraform-registry-manifest.json`;
sitting under `.template/release/` is its managed marker, since JSON can't
carry a header comment). Everything else is yours, except a short list of
files that must live at fixed paths and therefore stay at the root, each
carrying a `MANAGED FILE` header.

| Path | Owner | Notes |
|---|---|---|
| `provider/**` | **You** | Identity, schemas, scripts, unit tests. The sample `example_file` folders get deleted before you publish. |
| `docs/**` | **You** | Terraform Registry docs; synced to the repo wiki from `main`. Exception: `docs/guides/writing-resources.md` is managed — the registry publishes it from here. |
| `examples/**` | **You** | Sample .tf configs. |
| `tests/e2e/**` | **You** | E2E Pester suites (sample included). |
| `.template/**` | Managed | Build scripts, test harnesses, release configs, wiki-sync script. |
| `.github/workflows/*` | Managed | GitHub requires this path; CI/release/wiki-sync/template-sync. |
| `main.go`, `go.mod`, `main_test.go` | Managed | The entire Go surface (~50 lines); module root + `go:embed all:provider` pin them here. |
| `.releaserc.cjs` | Managed | 3-line discovery shim; the real config is `.template/release/releaserc.cjs`. |
| `.gitignore`, `LICENSE`, `README.md`, `SETUP.md`, `CLAUDE.md` | Managed | Root-level by convention/tooling. For fork-specific ignores, add a `.gitignore` in a subdirectory. |

Managed files are byte-identical in every copy: a monthly check opens an
issue when the template has updates, and a manually triggered sync workflow
copies the managed file set over and opens a PR with whatever changed (no
shared git history needed, so "Use this template" copies sync too). Don't
edit managed files; if one blocks you, open an issue on the template instead.

## Engine updates

The engine is a build-time dependency: `provider/settings.tfps.json` says
`"engine_version": "latest"` (newest GA release, resolved at every build) or
an exact version to pin. `.template/build/Update-Engine.ps1` resolves it into
`go.mod`; `.template/build/Get-EngineSidecars.ps1` downloads the matching `pshost` sidecars from
the engine's GitHub release at package time. Nothing engine-related is
committed to your repo, and every release zip of *your* provider carries its
own sidecar copy — fully self-contained, isolated per provider instance at
runtime (provider aliases give you multiple sidecars/sessions).

## Requirements

- **Runtime** (practitioners): Terraform >= 1.0. Nothing else — the bundled
  sidecar embeds PowerShell 7 and the .NET runtime.
- **Building/testing** (you): Go >= 1.21, PowerShell 7+, Pester >= 5,
  Terraform (for E2E). No .NET SDK needed — sidecars are downloaded, not built.

## License

MIT — see [LICENSE](LICENSE).
