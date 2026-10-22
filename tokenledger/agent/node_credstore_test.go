package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeCredStore is the credential proxy's control socket: it records every
// `store` request and answers ok (or refuses, when refuse is set).
func fakeCredStore(t *testing.T, refuse string) (string, chan map[string]string) {
	t.Helper()
	dir, err := os.MkdirTemp("", "cs") // short: a unix socket path has ~104 bytes
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
	got := make(chan map[string]string, 8)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			line, _ := bufio.NewReader(c).ReadBytes('\n')
			var req map[string]string
			_ = json.Unmarshal(line, &req)
			if req["op"] == "upstream-rejections" {
				c.Write([]byte(`{"ok":true,"rejected":[]}` + "\n"))
				c.Close()
				continue
			}
			got <- req
			if refuse != "" {
				c.Write([]byte(`{"ok":false,"err":"` + refuse + `"}` + "\n"))
			} else {
				c.Write([]byte(`{"ok":true}` + "\n"))
			}
			c.Close()
		}
	}()
	return sock, got
}

// recCredStore is the credential proxy's control socket for a whole lease
// cycle: it keeps every `store`d file by kind/label and answers every op ok.
func recCredStore(t *testing.T) (string, func(kind, label string) []byte) {
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
	return sock, func(kind, label string) []byte {
		mu.Lock()
		defer mu.Unlock()
		return files[kind+"/"+label]
	}
}

// storeAgent is credAgent with a credential store: where every lease goes.
func storeAgent(t *testing.T, srv *httptest.Server, home string) (*Agent, func(kind, label string) []byte) {
	sock, stored := recCredStore(t)
	a := credAgent(srv, home)
	a.cfg.FleetCredStore = sock
	return a, stored
}

// claude-fleet#1971: separated, a leased Claude credential goes to the proxy's
// socket and never lands in this login's accounts directory; the label marker
// (not a credential) still does.
func TestClaudeCredGoesToTheStoreWhenSeparated(t *testing.T) {
	sock, got := fakeCredStore(t, "")
	dir := t.TempDir()
	exp := time.Now().Add(time.Hour)
	if err := writeClaudeCred(dir, "main", "sk-ant-oat01-sep", &exp, nil, "max", credStoreSink(sock, "")); err != nil {
		t.Fatal(err)
	}
	req := <-got
	if req["op"] != "store" || req["kind"] != "claude" || req["label"] != "main" {
		t.Fatalf("store request = %v", req)
	}
	b, _ := base64.StdEncoding.DecodeString(req["data"])
	if !strings.Contains(string(b), `"accessToken":"sk-ant-oat01-sep"`) || !strings.Contains(string(b), `"subscriptionType":"max"`) {
		t.Fatalf("stored bytes = %s", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "main.hub", ".credentials.json")); err == nil {
		t.Fatal("separated: the credential file was written into the login's accounts dir")
	}
	if m, err := os.ReadFile(filepath.Join(dir, "main")); err != nil || string(m) != "hub:main\n" {
		t.Fatalf("marker = %q, %v", m, err)
	}
}

// ~/.codex is the label "default"; config.toml (no credential) stays local,
// auth.json goes to the store.
func TestCodexAuthGoesToTheStoreWhenSeparated(t *testing.T) {
	sock, got := fakeCredStore(t, "")
	home := filepath.Join(t.TempDir(), ".codex")
	if err := writeCodexAuth(home, "at-sep", "id", "acct-1", time.Now(), credStoreSink(sock, "")); err != nil {
		t.Fatal(err)
	}
	req := <-got
	if req["kind"] != "codex" || req["label"] != "default" {
		t.Fatalf("store request = %v", req)
	}
	if _, err := os.Stat(filepath.Join(home, "auth.json")); err == nil {
		t.Fatal("separated: auth.json was written into the login's codex home")
	}
	if _, err := os.Stat(filepath.Join(home, "config.toml")); err != nil {
		t.Fatalf("config.toml: %v", err)
	}
}

func TestCredStoreRefusalIsAnError(t *testing.T) {
	sock, _ := fakeCredStore(t, "unsafe label")
	exp := time.Now().Add(time.Hour)
	err := writeClaudeCred(t.TempDir(), "main", "sk-ant-oat01-x", &exp, nil, "", credStoreSink(sock, ""))
	if err == nil || !strings.Contains(err.Error(), "unsafe label") {
		t.Fatalf("err = %v", err)
	}
}

// claude-fleet#4675: no FleetCredStore = no sink = nothing written anywhere.
func TestNoCredStoreMeansNoSink(t *testing.T) {
	a := &Agent{cfg: Config{}}
	if a.credSink() != nil {
		t.Fatal("an agent with no FleetCredStore has a sink")
	}
	dir, home := t.TempDir(), filepath.Join(t.TempDir(), ".codex")
	exp := time.Now().Add(time.Hour)
	if err := writeClaudeCred(dir, "main", "sk-ant-oat01-x", &exp, nil, "", nil); !errors.Is(err, errNoStore) {
		t.Fatalf("claude with no store: err = %v, want errNoStore", err)
	}
	if err := writeCodexAuth(home, "at", "id", "acct-1", time.Now(), nil); !errors.Is(err, errNoStore) {
		t.Fatalf("codex with no store: err = %v, want errNoStore", err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatalf("no store, yet %d entries written in the accounts dir", len(ents))
	}
	if _, err := os.Lstat(home); err == nil {
		t.Fatal("no store, yet the codex home was made")
	}
}

// claude-fleet#3155: separated, the agent tells the proxy how each lease went —
// the hub's refusal in its own words, or how many Claude accounts it leased — so
// a session with no account is told why instead of «Please run /login».
func TestCredVerdictReachesTheStore(t *testing.T) {
	sock, got := fakeCredStore(t, "")
	a := credAgent(fakeVaultHub(t, 403, `{"error":"drill","message":"a drill person gets no credentials"}`), t.TempDir())
	a.cfg.FleetCredStore = sock
	if _, err := a.credCycle(context.Background()); err == nil {
		t.Fatal("a refused lease returned no error")
	}
	req := <-got
	if req["op"] != "lease" || req["state"] != "refused" || req["reason"] != "drill" ||
		req["message"] != "a drill person gets no credentials" || req["claude"] != "0" {
		t.Fatalf("refused verdict = %v", req)
	}

	b := credAgent(fakeVaultHub(t, 200, `{"credentials":[]}`), t.TempDir())
	b.cfg.FleetCredStore = sock
	if _, err := b.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	// claude-fleet#3744: the whole lease is handed to the proxy's prune first
	if req := <-got; req["op"] != "prune" {
		t.Fatalf("after a 200 lease, first request = %v, want prune", req)
	}
	if req := <-got; req["op"] != "lease" || req["state"] != "ok" || req["claude"] != "0" {
		t.Fatalf("empty lease verdict = %v", req)
	}
}

// Not separated: no verdict is sent anywhere (byte for byte as before).
func TestCredVerdictOffWithoutStore(t *testing.T) {
	a := credAgent(fakeVaultHub(t, 200, `{"credentials":[]}`), t.TempDir())
	if a.cfg.FleetCredStore != "" {
		t.Fatalf("credAgent is separated: %q", a.cfg.FleetCredStore)
	}
	if _, err := a.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
}

// claude-fleet#4675 (after #4643, where an agent started with no store leased
// a real Claude token into a separated login's home for a week): an agent with
// no credential store that is pushed creds writes NO subscription credential
// into any home — separated or not — and says no_store; GitHub's token, not a
// subscription, is still written.
func TestNoStoreWritesNothingHome(t *testing.T) {
	exp := time.Now().Add(8 * time.Hour).UTC().Truncate(time.Second)
	body := fmt.Sprintf(`{"credentials":[
	 {"provider":"claude","account":"icloud","expires_at":%q,"access":{"access_token":"sk-ant-oat01-LEAK","scopes":["user:inference"]}},
	 {"provider":"codex","account":"work","expires_at":%q,"access":{"access_token":"cx-LEAK","id_token":"idt","account_id":"acct-1"}},
	 {"provider":"github","account":"alice","access":{"token":"ghp_short","user":"alice"}}]}`,
		exp.Format(time.RFC3339), exp.Format(time.RFC3339))
	for _, separated := range []bool{true, false} {
		home := t.TempDir()
		conf := filepath.Join(home, ".config", "claude-fleet")
		if err := os.MkdirAll(conf, 0o700); err != nil {
			t.Fatal(err)
		}
		if separated {
			if err := os.WriteFile(filepath.Join(conf, "credsep.json"), []byte(`{"root":"/var/db/fleet-cred/x"}`), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		var buf bytes.Buffer
		log.SetOutput(&buf)
		a := credAgent(fakeVaultHub(t, 200, body), home)
		_, err := a.credCycle(context.Background())
		log.SetOutput(os.Stderr)
		if err != nil {
			t.Fatal(err)
		}
		_ = filepath.WalkDir(home, func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return err
			}
			if b, _ := os.ReadFile(p); strings.Contains(string(b), "LEAK") {
				t.Errorf("separated=%v: no store, yet %s holds a subscription credential", separated, p)
			}
			return nil
		})
		if !strings.Contains(buf.String(), "no_store=2") {
			t.Errorf("separated=%v: the cycle did not say no_store:\n%s", separated, buf.String())
		}
		if gh, _ := os.ReadFile(filepath.Join(home, ".config", "gh", "hosts.yml")); !strings.Contains(string(gh), "ghp_short") {
			t.Errorf("separated=%v: the GitHub token (not a subscription) was not written: %q", separated, gh)
		}
	}
}

// claude-fleet T904: the shared proxy restarting (its ctl.sock gone, then
// refused) costs one line, not one per account per lease; the wait asks the
// socket every credStorePoll and, once it answers, the next lease writes what
// it missed and says so once.
func TestCredStoreDownIsSaidOnceAndWrittenWhenBack(t *testing.T) {
	exp := time.Now().Add(8 * time.Hour).UTC().Truncate(time.Second)
	body := fmt.Sprintf(`{"principal_id":"p","credentials":[
	 {"provider":"claude","account":"main","expires_at":%q,"access":{"access_token":"sk-ant-oat01-a"}},
	 {"provider":"claude","account":"spare","expires_at":%q,"access":{"access_token":"sk-ant-oat01-b"}}]}`,
		exp.Format(time.RFC3339), exp.Format(time.RFC3339))
	dir, err := os.MkdirTemp("", "cs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "ctl.sock")
	a := credAgent(fakeVaultHub(t, 200, body), t.TempDir())
	a.cfg.FleetCredStore = sock
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	for i := 0; i < 3; i++ { // the socket is not there: three leases, one line
		if _, err := a.credCycle(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if !a.credStoreDown {
		t.Fatal("a lease whose store is gone did not mark it down")
	}
	if n := strings.Count(buf.String(), "not answering"); n != 1 {
		t.Fatalf("%d «not answering» lines, want 1:\n%s", n, buf.String())
	}
	if strings.Contains(buf.String(), "credentials: write") || strings.Contains(buf.String(), "sk-ant-") {
		t.Fatalf("a per-account line, or a credential, in the log:\n%s", buf.String())
	}

	// the proxy comes back 300 ms into a 6 h wait: the wait ends within a poll
	stored := make(chan string, 4)
	go func() {
		time.Sleep(300 * time.Millisecond)
		l, err := net.Listen("unix", sock)
		if err != nil {
			return
		}
		t.Cleanup(func() { l.Close() })
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			line, _ := bufio.NewReader(c).ReadBytes('\n')
			var req map[string]any
			_ = json.Unmarshal(line, &req)
			if req["op"] == "store" {
				stored <- fmt.Sprint(req["label"])
			}
			c.Write([]byte(`{"ok":true,"rejected":[]}` + "\n"))
			c.Close()
		}
	}()
	start := time.Now()
	if !a.waitCredLease(context.Background(), 6*time.Hour) {
		t.Fatal("wait ended without the context ending, yet said false")
	}
	if d := time.Since(start); d > credStorePoll+3*time.Second {
		t.Fatalf("the wait took %v after the proxy came back", d)
	}
	if _, err := a.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case l := <-stored:
			got[l] = true
		case <-time.After(5 * time.Second):
			t.Fatalf("stored %v, want main and spare", got)
		}
	}
	if a.credStoreDown || strings.Count(buf.String(), "answers again — wrote 2") != 1 {
		t.Fatalf("down=%v, log:\n%s", a.credStoreDown, buf.String())
	}
}
