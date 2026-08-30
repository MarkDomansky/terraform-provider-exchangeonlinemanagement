// MANAGED FILE - do not edit the module path in your fork.
//
// The module path deliberately stays the template's path in every fork:
// module path and binary name are unrelated (the binary is named
// terraform-provider-<name> from provider/settings.tfps.json at build time), and a
// fixed path means template->fork merges never conflict here.
//
// The engine version below is a last-known-good baseline only. Builds run
// .template/build/Update-Engine.ps1 first, which resolves it to the latest GA release
// (or the exact pin from provider/settings.tfps.json) before compiling.
module github.com/markdomansky/template-terraform-provider-yourprovider

go 1.26.2

require github.com/markdomansky/terraform-provider-powershell v0.1.0-beta.3
