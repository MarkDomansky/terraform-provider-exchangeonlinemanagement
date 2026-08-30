# From fork to the Terraform Registry — the checklist

Work through these in order. Steps 1–6 get you a working provider; 7–10 get it
released and published.

Everything under `.template/` is template machinery (build scripts, test
harnesses, release configs) — you run it, you never edit it.

## 1. Get your copy

Template updates arrive as monthly file-copy sync PRs (see step 10), which do
**not** require shared git history — so any of these paths works:

- **"Use this template"** (recommended): create a new repo from this template
  named `terraform-provider-<name>`. History starts fresh; template-sync
  still works.
- **GitHub fork**: fork this repo, rename it to `terraform-provider-<name>`
  in the repo settings.
- **Manual clone** (private repos, orgs GitHub won't fork into): create an
  empty repo, then
  ```
  git clone https://github.com/markdomansky/TEMPLATE-terraform-provider-YOURPROVIDER.git terraform-provider-<name>
  cd terraform-provider-<name>
  git remote remove origin
  git remote add origin <your-new-repo-url>
  git push -u origin main
  ```

Then create the `beta` branch from `main` and push it — the release pipeline
needs both branches to exist:

```
git checkout -b beta && git push -u origin beta
```

Branch protection tip: require PRs into `beta`; merge PRs with **squash**;
merge `beta` into `main` with a **real merge commit** (never squash — the
release notes and version bump are computed from the individual commits).

## 2. Set your identity

```
./.template/build/Initialize-Fork.ps1 -Name <provider_name> -Namespace <registry_namespace>
```

`<provider_name>` is lowercase (letters/digits/underscores) and prefixes every
resource type; `<registry_namespace>` is your GitHub user/org. This writes
`provider/settings.tfps.json` — the only file that names your provider. Commit it.

## 3. Build your resources

Study the working sample first — `provider/resources/example_file/` is a
complete, tested resource managing a local file. Then, per resource:

```
./.template/build/New-Resource.ps1 -Name mailbox            # resource
./.template/build/New-Resource.ps1 -Name mailbox -DataSource # data source
```

Edit `resource.tfps.json` (attributes, types, required/optional/computed,
`requires_replace`), then fill in the scripts. The full authoring reference —
script contract, every manifest field, update-vs-replace semantics — is in
[docs/guides/writing-resources.md](docs/guides/writing-resources.md).

Provider-level concerns (authentication, connection settings) go in
`provider/provider.tfps.json` (custom provider attributes, delivered to scripts as
`$global:ProviderData.Config.<name>`) and `provider/scripts/startup.ps1`
(connect once per terraform run).

## 4. Test locally (all platforms)

Everything here runs the same on Windows, Linux, and macOS (PowerShell 7):

```
pwsh ./.template/tests/unit/Invoke-UnitTests.ps1 # fast: scripts in-process, Pester mocks, no terraform
go test ./...                                    # validates every manifest + required scripts
./.template/build/Build-Provider.ps1             # compile + stage sidecar into dist/local/
Invoke-Pester ./tests/e2e -Output Detailed       # real terraform apply via dev_overrides
```

E2E suites that need a live system (a tenant, a server) should load
`Get-E2ETestConfig` from the harness and skip when it returns `$null`; commit
a `tests/e2e/config/e2e.tests.config.template.psd1` blueprint and gitignore
the real config (already wired). CI runs unit tests + E2E on Windows and
Linux for every PR.

## 5. Write the docs

`docs/` follows the Terraform Registry layout (`index.md`,
`resources/<name>.md`, `data-sources/<name>.md`, `guides/`).
`New-Resource.ps1` scaffolds a stub per resource. On `main`, `docs/` is
auto-synced to the repo's wiki (create the wiki's first page once in the UI so
the wiki git repo exists).

## 6. Delete the samples

Before publishing, remove the sample content:

```
git rm -r provider/resources/example_file provider/data-sources/example_file
git rm tests/e2e/ExampleFile.Tests.ps1 docs/resources/example_file.md docs/data-sources/example_file.md
```

Also replace the sample `default_directory` attribute in `provider/provider.tfps.json`
and the sample logic in `provider/scripts/startup.ps1` with your own. Template
sync only ever touches managed paths, so deleting these fork-owned samples
never conflicts with future sync PRs.

## 7. Configure release signing

The Terraform Registry requires GPG-signed checksums:

1. Generate a signing key: `gpg --full-generate-key` (RSA 4096).
2. Repo secrets (Settings → Secrets → Actions):
   - `GPG_PRIVATE_KEY` — `gpg --armor --export-secret-keys <key-id>`
   - `GPG_PASSPHRASE` — the key's passphrase
3. Keep the public key (`gpg --armor --export <key-id>`) for step 9.

Without the secrets, releases still work on GitHub (unsigned) but the registry
will reject them.

## 8. Release

Every squash-merged PR into `beta` cuts `x.y.z-beta.N` automatically —
version comes from conventional commit messages (`feat:` = minor, `fix:` =
patch, anything = at least patch; never hand-edit versions or create tags).
The pipeline: version → package (GoReleaser + downloaded sidecars) → install
smoke test on all three OSes → tag + GitHub release. For GA, merge `beta`
into `main` with a real merge commit.

## 9. Publish to the Terraform Registry

One-time, after your first GA release:

1. Sign in at <https://registry.terraform.io> with GitHub.
2. User/org settings → **Signing keys** → add the GPG **public** key from step 7.
3. **Publish → Provider**, pick your `terraform-provider-<name>` repo.

The registry ingests the GitHub releases (zips + SHA256SUMS + .sig +
manifest); future releases appear automatically.

## 10. Stay current

- **Engine**: with `"engine_version": "latest"` every build picks up the
  newest GA engine automatically; pin an exact version in
  `provider/settings.tfps.json` when you need stability (or a specific
  `-beta.N` prerelease).
- **Template**: `template-sync.yml` checks on the 1st of each month whether
  the template has managed-file changes this repo lacks. If so, it opens
  (or refreshes) a **"Template updates available" issue** listing the
  pending template commits and files — it never changes anything on its
  own. To apply the updates, run the sync manually (Actions → Template
  Sync → Run workflow, or `gh workflow run 'Template Sync'`): that copies
  the managed file set onto a `template-sync` branch and opens a PR into
  `beta` (or your default branch), closing the tracking issue. An unmerged
  sync PR is force-pushed and updated by the next manual run, never
  duplicated. Squash-merge it like any other PR. Two one-time settings:
  enable "Allow GitHub Actions to create and approve pull requests"
  (Settings → Actions → General), and optionally add a `TEMPLATE_SYNC_TOKEN`
  secret (PAT with contents + workflows + pull-requests write) so syncs can
  update `.github/workflows/**` and trigger CI on the PR — without it,
  workflow changes are only reported in the PR body. Sync PRs created
  without the PAT show **no CI checks** (GitHub ignores events from the
  default token): close and reopen the PR to trigger them — required status
  checks stay pending until you do. Merging the PR always triggers CI on
  `beta` normally. To opt out, delete
  `.github/workflows/template-sync.yml` or disable the workflow in the
  Actions tab.
