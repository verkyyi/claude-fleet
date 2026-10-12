package nodesig

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The URI a dial signs is the URL's path?query, whatever its scheme — the
// control link is a ws:// / wss:// URL the hub reads as GET <path>.
func TestAuthorizationSignsThePath(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	s := fromSeed(seed)
	if s.ID() != "nk_65b60673d6ed884bf01c2c22" { // bin/fleet_node_sig.py's vector
		t.Fatalf("id = %s", s.ID())
	}
	for url, uri := range map[string]string{
		"wss://hub.test/v1/node/connect":   "/v1/node/connect",
		"https://hub.test/v1/ssh?id=a%20b": "/v1/ssh?id=a%20b",
		"http://hub.test":                  "/",
	} {
		v := Authorization(s, "tok", "GET", url)
		f := map[string]string{}
		for _, p := range strings.Split(strings.TrimPrefix(v, "FleetSig "), ",") {
			k, val, _ := strings.Cut(strings.TrimSpace(p), "=")
			f[k] = val
		}
		sig, _ := base64.RawURLEncoding.DecodeString(f["sig"])
		msg := strings.Join([]string{version, f["keyid"], f["ts"], f["nonce"], "GET", uri}, "\n")
		if !ed25519.Verify(s.priv.Public().(ed25519.PublicKey), []byte(msg), sig) {
			t.Fatalf("%s: the signature is not over GET %s", url, uri)
		}
	}
	if v := Authorization(nil, "tok", "GET", "https://hub.test/x"); v != "Bearer tok" {
		t.Fatalf("no key = %q", v)
	}
}

// Confirmed signs only for the hub the .ok names; LoginKeyPath stays out of a
// separated login's home.
func TestConfirmedAndLoginKeyPath(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "node.key")
	if err := keygen(p); err != nil {
		t.Fatal(err)
	}
	if Confirmed(p, "https://hub.test") != nil {
		t.Fatal("confirmed with no .ok")
	}
	s, _ := Load(p)
	_ = writeOK(p, s.ID()+" https://hub.test")
	if Confirmed(p, "https://hub.test/") == nil || Confirmed(p, "https://other.test") != nil {
		t.Fatal("Confirmed does not follow the .ok's hub")
	}
	if err := keygen(p); err == nil {
		t.Fatal("keygen overwrote a key")
	}

	t.Setenv("CCQUOTA_NODE_KEY", "")
	t.Setenv("FLEET_CONF_DIR", d)
	if got := LoginKeyPath(); got != p {
		t.Fatalf("LoginKeyPath = %q", got)
	}
	if err := os.WriteFile(filepath.Join(d, "credsep.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := LoginKeyPath(); got != "" {
		t.Fatalf("a separated login's key path = %q", got)
	}
	t.Setenv("CCQUOTA_NODE_KEY", "off")
	if got := LoginKeyPath(); got != "" {
		t.Fatalf("off = %q", got)
	}
	if Beside("/var/db/fleet-node/logins/a.env") != "/var/db/fleet-node/logins/a.key" {
		t.Fatal("Beside")
	}
}
