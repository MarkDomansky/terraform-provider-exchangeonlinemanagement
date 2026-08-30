// MANAGED FILE - do not edit in your fork.
//
// This is the entire Go surface of your provider. Everything it does is
// driven by the user-owned provider/ directory:
//
//	provider/settings.tfps.json   -> provider name + registry address
//	provider/provider.tfps.json   -> custom provider-block attributes (optional)
//	provider/scripts/*.ps1        -> provider startup/shutdown scripts (optional)
//	provider/resources/<name>/    -> one Terraform resource per folder
//	provider/data-sources/<name>/ -> one Terraform data source per folder
//
// The engine (terraform-provider-powershell's scriptprovider package) parses
// the embedded tree, builds real typed Terraform schemas from each
// manifest, and runs your CRUD scripts in a persistent PowerShell sidecar.
package main

import (
	"context"
	"embed"
	"flag"
	"log"

	"github.com/markdomansky/terraform-provider-powershell/scriptprovider"
)

// all: is required so files beginning with '.' or '_' are embedded too.
//
//go:embed all:provider
var providerFS embed.FS

// version is stamped by the release workflow via
// -ldflags "-X main.version=x.y.z". Never edit it by hand.
var version = "0.1-dev"

func main() {
	var debug bool
	flag.BoolVar(&debug, "debug", false, "set to true to run the provider with support for debuggers like delve")
	flag.Parse()

	settings, err := scriptprovider.LoadSettings(providerFS)
	if err != nil {
		log.Fatal(err.Error())
	}

	// Serve blocks until Terraform closes the plugin, then runs every
	// registered shutdown script and stops the PowerShell sidecar.
	if err := scriptprovider.Serve(context.Background(), scriptprovider.Definition{
		Settings: settings,
		Version:  version,
		FS:       providerFS,
		Debug:    debug,
	}); err != nil {
		log.Fatal(err.Error())
	}
}
