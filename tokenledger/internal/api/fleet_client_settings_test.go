package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// claude-fleet#1722: /version says which client this build hands out.
func TestVersionCarriesTheClient(t *testing.T) {
	needPacked(t)
	h := newHarness(t)
	resp, err := h.http.Client().Get(h.http.URL + "/version")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var got map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got["client_version"] != fleetclient.Version || len(fleetclient.Version) != 12 {
		t.Errorf("client_version = %v, want %q (12 hex)", got["client_version"], fleetclient.Version)
	}
	if got["client_compat"] != float64(fleetclient.Compat) || got["min_client_compat"] != float64(fleetclient.MinCompat) {
		t.Errorf("compat = %v / %v, want %d / %d", got["client_compat"], got["min_client_compat"], fleetclient.Compat, fleetclient.MinCompat)
	}
}

// The hub serves the current client and the one before it: MinCompat never
// rises above Compat-1 (and never above Compat).
func TestClientCompatPromise(t *testing.T) {
	if fleetclient.MinCompat > fleetclient.Compat || fleetclient.MinCompat < fleetclient.Compat-1 {
		t.Errorf("MinCompat %d with Compat %d: a hub serves the current client and the previous one", fleetclient.MinCompat, fleetclient.Compat)
	}
	// the client this build serves speaks the same level it says
	needPacked(t)
	b, err := fleetclient.Files.ReadFile("bin/fleet-client-update.sh")
	if err != nil {
		t.Fatal(err)
	}
	if want := fmt.Sprintf("\nFLEET_CLIENT_COMPAT=%d\n", fleetclient.Compat); !strings.Contains(string(b), want) {
		t.Errorf("bin/fleet-client-update.sh does not carry %q", strings.TrimSpace(want))
	}
}

// The digest follows the files: same list same bytes → same version; any
// byte changed → another.
func TestClientVersionDigest(t *testing.T) {
	files := map[string][]byte{"bin/a": []byte("#!/bin/sh\n"), "conf/b": []byte("x\n")}
	read := func(n string) ([]byte, error) { return files[n], nil }
	v1 := fleetclient.Digest(read, []string{"bin/a", "conf/b"})
	if v1 != fleetclient.Digest(read, []string{"bin/a", "conf/b"}) {
		t.Fatal("digest is not stable")
	}
	files["conf/b"] = []byte("y\n")
	if v1 == fleetclient.Digest(read, []string{"bin/a", "conf/b"}) {
		t.Error("a changed file left the digest unchanged")
	}
}

func getClientSettings(t *testing.T, h *harness) (map[string]string, []string) {
	t.Helper()
	resp, err := http.Get(h.http.URL + "/v1/fleet/client-settings") // no credential: public
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("client-settings: HTTP %d without a token, want 200", resp.StatusCode)
	}
	var out struct {
		Settings map[string]string `json:"settings"`
		Keys     []string          `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out.Settings, out.Keys
}

// Only whitelisted keys, never a credential-shaped value, "" clears.
func TestClientSettingsWhitelist(t *testing.T) {
	h := newFleetHarness(t)
	if s, keys := getClientSettings(t, h); len(s) != 0 || len(keys) == 0 {
		t.Fatalf("fresh hub: settings %v keys %v", s, keys)
	}
	putSetting(t, h, ClientDefaultsPrefix+"FLEET_UI_LANG", "en", http.StatusOK)
	putSetting(t, h, ClientDefaultsPrefix+"FLEET_NODE_ALIASES", "desk-mac=m5 macmini=m4", http.StatusOK)
	// not on the whitelist: an address, a token, anything else
	putSetting(t, h, ClientDefaultsPrefix+"FLEET_HUB_URL", "https://evil.example", http.StatusBadRequest)
	putSetting(t, h, ClientDefaultsPrefix+"CCQUOTA_VIEWER_TOKEN", "x", http.StatusBadRequest)
	// secret-shaped or unquotable values
	for _, v := range []string{
		"sk-ant-abc", "ghp_abcdef", "AKIAABCDEFGHIJKLMNOP",
		"aGVsbG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCB0b2tlbg",
		"it's", "a\nb", "$(id)",
	} {
		putSetting(t, h, ClientDefaultsPrefix+"FLEET_SHELL_PREFIX", v, http.StatusBadRequest)
	}
	// a row stored behind the whitelist's back is never served
	if err := h.srv.Store.SetFleetSetting(ClientDefaultsPrefix+"OPENAI_API_KEY", "x", time.Now()); err != nil {
		t.Fatal(err)
	}
	s, _ := getClientSettings(t, h)
	if len(s) != 2 || s["FLEET_UI_LANG"] != "en" || s["FLEET_NODE_ALIASES"] != "desk-mac=m5 macmini=m4" {
		t.Errorf("client-settings = %v", s)
	}
	putSetting(t, h, ClientDefaultsPrefix+"FLEET_UI_LANG", "", http.StatusOK)
	if s, _ := getClientSettings(t, h); s["FLEET_UI_LANG"] != "" {
		t.Errorf("cleared key still served: %v", s)
	}
}
