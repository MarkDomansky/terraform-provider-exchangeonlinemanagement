// MANAGED FILE - do not edit in your fork.
package main

import (
	"testing"

	"github.com/markdomansky/terraform-provider-powershell/scriptprovider"
)

// TestProviderDefinitionLoads validates the whole embedded provider/ tree at
// CI time: settings.tfps.json, every resource/data-source manifest, and the
// presence of every required script. A typo in any manifest fails `go test ./...` with the
// engine's pointed error message instead of failing at terraform runtime.
func TestProviderDefinitionLoads(t *testing.T) {
	settings, err := scriptprovider.LoadSettings(providerFS)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := scriptprovider.NewProviderFactory(scriptprovider.Definition{
		Settings: settings,
		Version:  "0.0.0-test",
		FS:       providerFS,
	}); err != nil {
		t.Fatal(err)
	}
}
