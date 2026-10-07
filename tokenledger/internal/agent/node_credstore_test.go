package agent

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
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

// claude-fleet#1971: separated, a leased Claude credential goes to the proxy's
// socket and never lands in this login's accounts directory; the label marker
// (not a credential) still does.
func TestClaudeCredGoesToTheStoreWhenSeparated(t *testing.T) {
	sock, got := fakeCredStore(t, "")
	dir := t.TempDir()
	exp := time.Now().Add(time.Hour)
	if err := writeClaudeCred(dir, "main", "sk-ant-oat01-sep", &exp, nil, "max", credStoreSink(sock)); err != nil {
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
	if err := writeCodexAuth(home, "at-sep", "id", "acct-1", time.Now(), credStoreSink(sock)); err != nil {
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
	err := writeClaudeCred(t.TempDir(), "main", "sk-ant-oat01-x", &exp, nil, "", credStoreSink(sock))
	if err == nil || !strings.Contains(err.Error(), "unsafe label") {
		t.Fatalf("err = %v", err)
	}
}

// No FleetCredStore = no sink = the files, exactly as before.
func TestNoCredStoreMeansNoSink(t *testing.T) {
	a := &Agent{cfg: Config{}}
	if a.credSink() != nil {
		t.Fatal("an agent with no FleetCredStore has a sink")
	}
}
