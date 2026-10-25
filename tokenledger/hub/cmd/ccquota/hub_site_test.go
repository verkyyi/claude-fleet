package main

import (
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/api"
)

// CCQUOTA_SITE (claude-fleet#3583, task PNWW): on / 1 / true the default
// site, sandbox the sandbox edition, anything else off.
func TestSiteEnv(t *testing.T) {
	for v, want := range map[string]struct {
		on      bool
		edition string
	}{
		"": {}, "off": {}, "0": {}, "sandboxes": {},
		"on": {true, ""}, "1": {true, ""}, "TRUE": {true, ""}, "yes": {true, ""},
		"sandbox": {true, api.SiteEditionSandbox}, " Sandbox ": {true, api.SiteEditionSandbox},
	} {
		if siteOn(v) != want.on || siteEdition(v) != want.edition {
			t.Errorf("CCQUOTA_SITE=%q: on %v edition %q; want %v %q", v, siteOn(v), siteEdition(v), want.on, want.edition)
		}
	}
}
