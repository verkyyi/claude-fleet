package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// peerPost asks the hub for a machine-to-machine certificate with a node token.
func peerPost(t *testing.T, h *harness, tok string, body map[string]any) (int, PeerCertResponse, string) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/peer-cert", bytes.NewReader(b))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out PeerCertResponse
	if res.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("answer does not parse: %v %s", err, raw)
		}
	}
	return res.StatusCode, out, string(raw)
}

// peerHarness: certHarness (Alice owns login alice on macmini + macmini-m4),
// plus Bob owning bob on macmini-m4 only, and the operator's own login verk —
// owned by no person — on both. Every login runs a node.
func peerHarness(t *testing.T) (*harness, *sshca.CA, map[string]*fleetNode) {
	t.Helper()
	h, ca := certHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: "Bob", Hostname: "macmini-m4", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	nodes := map[string]*fleetNode{
		"alice5": connectNode(t, h, "alice5", "macmini", "alice", false),
		"alice4": connectNode(t, h, "alice4", "macmini-m4", "alice", false),
		"bob4":   connectNode(t, h, "bob4", "macmini-m4", "bob", false),
		"verk5":  connectNode(t, h, "verk5", "macmini", "verk", false),
		"verk4":  connectNode(t, h, "verk4", "macmini-m4", "verk", false),
	}
	waitFor(t, 3*time.Second, "every node on the roster", func() bool {
		for _, n := range nodes {
			if r := h.srv.nodeRow(n.id); r == nil || r.Hostname == "" {
				return false
			}
		}
		return true
	})
	return h, ca, nodes
}

// The completion criterion, hub side: a node gets a five-minute certificate
// for its OWNER's login on the target — and only that — recorded before it
// is handed out; a node that is not the owner's is refused.
func TestPeerCertOwnerOnlyShortAndAudited(t *testing.T) {
	h, ca, n := peerHarness(t)

	key := newUserKey(t)
	st, got, raw := peerPost(t, h, n["alice5"].token, map[string]any{"target": "m4", "purpose": "view", "public_key": key})
	if st != 200 {
		t.Fatalf("alice@m5 → m4: HTTP %d %s", st, raw)
	}
	c := parseCert(t, strings.TrimSpace(got.Certificate))
	if len(c.ValidPrincipals) != 1 || c.ValidPrincipals[0] != "alice" || got.Login != "alice" || got.Target != "macmini-m4" {
		t.Fatalf("principals %v login %q target %q; want alice on macmini-m4", c.ValidPrincipals, got.Login, got.Target)
	}
	if c.KeyId != "peer:alice@macmini>alice@macmini-m4:view" || got.KeyID != c.KeyId {
		t.Fatalf("key id %q", c.KeyId)
	}
	if life := time.Unix(int64(c.ValidBefore), 0).Sub(time.Now()); life > sshca.PeerTTL || life < sshca.PeerTTL-10*time.Second {
		t.Fatalf("lives %v; want five minutes", life)
	}
	if _, ok := c.Permissions.Extensions["permit-agent-forwarding"]; ok {
		t.Fatal("a peer certificate forwards the agent")
	}
	if string(c.SignatureKey.Marshal()) != string(mustParsePub(t, ca.PublicKey()).Marshal()) {
		t.Fatal("not signed by the hub's CA")
	}

	// A longer life is asked for and not given; a shorter one is.
	if _, g, _ := peerPost(t, h, n["alice5"].token, map[string]any{"target": "macmini-m4", "purpose": "upgrade", "public_key": key, "ttl_sec": 86400}); g.TTLSec > int(sshca.PeerTTL.Seconds()) {
		t.Fatalf("asked a day, got %ds", g.TTLSec)
	}
	if _, g, _ := peerPost(t, h, n["alice5"].token, map[string]any{"target": "macmini-m4", "purpose": "move", "public_key": key, "ttl_sec": 30}); g.TTLSec > 30 {
		t.Fatalf("asked 30s, got %ds", g.TTLSec)
	}

	// The operator's own login (no person owns it) reaches the same name only.
	if st, g, raw := peerPost(t, h, n["verk5"].token, map[string]any{"target": "m4", "purpose": "view", "public_key": key}); st != 200 || g.Login != "verk" {
		t.Fatalf("verk@m5 → m4: HTTP %d login %q %s; want verk", st, g.Login, raw)
	}

	// Refusals: Bob has no login on m5; nobody's own machine; no such
	// machine; an unknown purpose; no token; a bad token.
	for name, tc := range map[string]struct {
		tok  string
		body map[string]any
		want int
	}{
		"not the owner's": {n["bob4"].token, map[string]any{"target": "m5", "purpose": "view", "public_key": key}, 403},
		"itself":          {n["alice5"].token, map[string]any{"target": "m5", "purpose": "view", "public_key": key}, 400},
		"unknown machine": {n["alice5"].token, map[string]any{"target": "nowhere", "purpose": "view", "public_key": key}, 422},
		"bad purpose":     {n["alice5"].token, map[string]any{"target": "m4", "purpose": "shell", "public_key": key}, 400},
		"bad key":         {n["alice5"].token, map[string]any{"target": "m4", "purpose": "view", "public_key": "nope"}, 400},
		"no token":        {"", map[string]any{"target": "m4", "purpose": "view", "public_key": key}, 401},
		"bad token":       {"not-a-token", map[string]any{"target": "m4", "purpose": "view", "public_key": key}, 401},
	} {
		if st, _, raw := peerPost(t, h, tc.tok, tc.body); st != tc.want {
			t.Errorf("%s: HTTP %d %s; want %d", name, st, raw, tc.want)
		}
	}

	// Every issuance is in the audit — four, newest first — and the
	// refusals are not.
	var audit struct {
		PeerCerts []map[string]any `json:"peer_certs"`
	}
	h.getJSON(t, "/v1/fleet/peer-certs", &audit)
	if len(audit.PeerCerts) != 4 {
		t.Fatalf("audit has %d rows; want 4: %v", len(audit.PeerCerts), audit.PeerCerts)
	}
	seen := map[string]bool{}
	for _, r := range audit.PeerCerts {
		seen[r["source_user"].(string)+">"+r["login"].(string)+":"+r["purpose"].(string)] = true
		if r["target_host"] != "macmini-m4" || r["source_host"] != "macmini" {
			t.Errorf("audit row %v", r)
		}
	}
	for _, k := range []string{"alice>alice:view", "alice>alice:upgrade", "alice>alice:move", "verk>verk:view"} {
		if !seen[k] {
			t.Errorf("audit misses %s: %v", k, audit.PeerCerts)
		}
	}
}

// No CA configured: the route is not there, like every certificate route.
func TestPeerCertOffWithoutCA(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.SSHCA = nil
	if st, _, _ := peerPost(t, h, n["alice5"].token, map[string]any{"target": "m4", "purpose": "view", "public_key": newUserKey(t)}); st != 404 {
		t.Fatalf("HTTP %d; want 404", st)
	}
}

func mustParsePub(t *testing.T, line string) ssh.PublicKey {
	t.Helper()
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	return pk
}
