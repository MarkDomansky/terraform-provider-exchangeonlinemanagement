# Repo-local notes — the template repo itself

Rules that apply to **this** repository only, on top of the shared contract in
`CLAUDE.md`. This file is not part of the managed file set, so template syncs
never overwrite or restore it: a repo created from this template can delete it
outright, or replace the contents with its own local rules.

## No `beta` branch, no release

`CLAUDE.md` says to squash PRs into `beta` for prereleases and merge `beta`
into `main` with a real merge commit for GA. That does not apply here.

The template ships no installable provider, and repos consume it as a file
copy from a ref (`template-sync.yml` checks out `main`), never as a versioned
artifact — so a prerelease channel would have no consumer. Work lands as PRs
into `main`.

The `publish` job in `release.yml` is guarded off by repository name, so the
pipeline still builds and smoke-tests here but never tags or uploads
`terraform-provider-yourprovider` artifacts.

The `CLAUDE.md` rules are what repos created from this template inherit, and
they are correct there — do not "fix" them to match this repo.
