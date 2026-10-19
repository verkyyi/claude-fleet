package e2e

import (
	"sync/atomic"

	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"

	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	iofs "io/fs"
	"net"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The end-to-end check: a hub with the vault and a real agent (CCQUOTA_FLEET=1,
// CCQUOTA_FLEET_CREDS=1) on a machine nobody has logged in on. The agent's
// first heartbeat tells the hub who it is, its lease comes back, and the files
// Claude Code / Codex / gh read are on disk — with no refresh token among them.
func TestCredentialLeaseIntegration(t *testing.T) {
	h := newFleetHarness(t)
	sealer, _ := credvault.NewSealer(bytes.Repeat([]byte{9}, 32))
	h.Srv.Vault = &credvault.Vault{Store: h.Srv.Store, Sealer: sealer, Refresher: &stubRefresher{}}

	hostname, _ := os.Hostname()
	u, err := user.Current()
	if err != nil {
		t.Skip("no current user")
	}
	p, err := h.Srv.Store.AdoptPrincipal("gh:1010", u.Username, "IT", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Srv.Store.AdoptAccount(p, hostname, time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, c := range []FleetCredentialRequest{
		{Provider: "claude", Account: "main", Secret: credvault.Secret{RefreshToken: "sk-ant-ort01-HUBONLY", SubscriptionType: "max"}},
		{Provider: "codex", Account: "work", Secret: credvault.Secret{RefreshToken: "rt-HUBONLY", AccountID: "acct-it"}},
	} {
		c.Action, c.PrincipalID = "put", "gh:1010"
		if code, out := h.Post(t, "/v1/fleet/credentials", c); code != http.StatusOK {
			t.Fatalf("put: %d %v", code, out)
		}
	}

	home := t.TempDir()
	// A separated login (claude-fleet#4607): its credsep script says so, and its
	// agent hands every lease to the credential proxy's store — the only place a
	// subscription credential goes (claude-fleet#4675).
	credsep := filepath.Join(home, ".claude", "fleet", "bin", "fleet-credsep.sh")
	_ = os.MkdirAll(filepath.Dir(credsep), 0o755)
	if err := os.WriteFile(credsep, []byte("#!/bin/bash\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	sock, stored := itCredStore(t)
	a, err := agent.New(agent.Config{
		HubURL: h.HTTP.URL, Token: h.Enroll(t, "it"), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 150 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetCreds: true, FleetCredStore: sock, Version: "it",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })

	waitFor(t, 10*time.Second, "the agent stored both leased credentials", func() bool {
		return stored("claude/main") != nil && stored("codex/work") != nil
	})
	for _, p := range []string{
		filepath.Join(home, ".config", "claude-fleet", "accounts", "main.hub"),
		filepath.Join(home, ".codex-accounts", "work", "auth.json"),
	} {
		if _, err := os.Lstat(p); err == nil {
			t.Fatalf("%s written into the home", p)
		}
	}
	cb := stored("claude/main")
	if !strings.Contains(string(cb), `"accessToken":"claude-access-`) || !strings.Contains(string(cb), `"refreshToken":null`) {
		t.Fatalf("claude credentials file: %s", cb)
	}
	marker, _ := os.ReadFile(filepath.Join(home, ".config", "claude-fleet", "accounts", "main"))
	if string(marker) != "hub:main\n" {
		t.Fatalf("pool file = %q", marker)
	}
	xb := stored("codex/work")
	if !strings.Contains(string(xb), `"refresh_token": "hub-managed"`) || !strings.Contains(string(xb), `"account_id": "acct-it"`) {
		t.Fatalf("codex auth.json: %s", xb)
	}
	// The completion criterion's grep: no refresh token anywhere on the node.
	_ = filepath.WalkDir(home, func(path string, d iofs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if b, _ := os.ReadFile(path); bytes.Contains(b, []byte("HUBONLY")) || bytes.Contains(b, []byte("rotated-")) {
				t.Errorf("%s holds a refresh token", path)
			}
		}
		return nil
	})
	audit, _ := h.Srv.Store.CredAuditLog("gh:1010", 50)
	issued := 0
	for _, r := range audit {
		if r.Action == store.CredIssue && r.Hostname == hostname && r.OSUser == u.Username {
			issued++
		}
	}
	if issued < 2 {
		t.Fatalf("%d issue audit rows for %s@%s, want 2", issued, u.Username, hostname)
	}
}

// itCredStore is the credential proxy's control socket: it keeps each stored
// file by kind/label and answers every op ok.
func itCredStore(t *testing.T) (string, func(key string) []byte) {
	t.Helper()
	dir, err := os.MkdirTemp("", "cs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "ctl.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	var mu sync.Mutex
	files := map[string][]byte{}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			line, _ := bufio.NewReader(c).ReadBytes('\n')
			var req map[string]any
			_ = json.Unmarshal(line, &req)
			if req["op"] == "store" {
				b, _ := base64.StdEncoding.DecodeString(fmt.Sprint(req["data"]))
				mu.Lock()
				files[fmt.Sprint(req["kind"])+"/"+fmt.Sprint(req["label"])] = b
				mu.Unlock()
			}
			c.Write([]byte(`{"ok":true,"rejected":[],"gone":[]}` + "\n"))
			c.Close()
		}
	}()
	return sock, func(key string) []byte {
		mu.Lock()
		defer mu.Unlock()
		return files[key]
	}
}

type stubRefresher struct {
	n atomic.Int64
	// refuse: answer every refresh with the provider's invalid_grant.
	refuse atomic.Bool
}

func (r *stubRefresher) Refresh(_ context.Context, provider string, s credvault.Secret) (credvault.Access, credvault.Secret, error) {
	n := r.n.Add(1)
	if r.refuse.Load() {
		return credvault.Access{}, s, &credvault.ProviderRefusal{Status: http.StatusBadRequest, Code: "invalid_grant", Body: `{"error":"invalid_grant"}`}
	}
	exp := time.Now().Add(8 * time.Hour).UTC()
	next := s
	next.RefreshToken = fmt.Sprintf("rotated-%d", n)
	return credvault.Access{AccessToken: fmt.Sprintf("%s-access-%d", provider, n), AccountID: s.AccountID, ExpiresAt: &exp}, next, nil
}

func enrollAs(t *testing.T, h *harness, label, hostname, osUser string) string {
	t.Helper()
	tok := h.Enroll(t, label)
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.Srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.Srv.Store.TouchEndpoint("ep_"+label, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	// Every login leases only credential-separated (claude-fleet#4607, no way
	// out since #4675): the fixture's login is one, as its first heartbeat
	// says. A test about the gate beats its own word over it (credsepBeat).
	ep, err := h.Srv.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Srv.Store.NodeConnected(ep.ID, hostname, osUser, "test", control.Proto, 60000, time.Now()); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(control.Heartbeat{Hostname: hostname, OSUser: osUser, Credsep: control.CredsepSeparated, ObservedAt: time.Now()})
	if err := h.Srv.Store.NodeHeartbeat(ep.ID, hostname, osUser, "", control.Proto, string(raw), time.Now()); err != nil {
		t.Fatal(err)
	}
	return tok
}

func lease(t *testing.T, h *harness, tok string) (int, NodeCredentialsResponse, map[string]string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.HTTP.URL+"/v1/node/credentials", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.HTTP.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body bytes.Buffer
	_, _ = body.ReadFrom(res.Body)
	var ok NodeCredentialsResponse
	var refusal map[string]string
	if res.StatusCode == http.StatusOK {
		_ = json.Unmarshal(body.Bytes(), &ok)
	} else {
		_ = json.Unmarshal(body.Bytes(), &refusal)
	}
	return res.StatusCode, ok, refusal
}
