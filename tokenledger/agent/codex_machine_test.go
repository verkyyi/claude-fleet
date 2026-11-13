package agent

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

func fakeCodexJWT(t *testing.T, claims map[string]any) string {
	t.Helper()
	b, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"none"}`)) + "." + enc(b) + ".sig"
}

// writeCodexLogin is a subscription auth.json in codexHome.
func writeCodexLogin(t *testing.T, codexHome string) {
	t.Helper()
	meta := map[string]any{"chatgpt_account_id": "acct-1", "chatgpt_user_id": "user-1", "chatgpt_plan_type": "plus"}
	access := fakeCodexJWT(t, map[string]any{"https://api.openai.com/auth": meta, "exp": time.Now().Add(72 * time.Hour).Unix()})
	id := fakeCodexJWT(t, map[string]any{"email": "grace@example.com"})
	doc, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{
		"id_token": id, "access_token": access, "refresh_token": "r", "account_id": "acct-1"}})
	if err := os.MkdirAll(codexHome, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(codexHome, "auth.json"), doc, 0o600); err != nil {
		t.Fatal(err)
	}
}

// plantCodex puts an executable codex in home/.local/bin that leaves marker
// behind when anything runs it.
func plantCodex(t *testing.T, home string) (marker string) {
	t.Helper()
	marker = filepath.Join(t.TempDir(), "ran")
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "codex"), []byte("#!/bin/sh\ntouch "+marker+"\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return marker
}

func codexHub(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/collectors/quota-lease" {
			http.NotFound(w, r)
			return
		}
		var batch model.Batch
		_ = json.NewDecoder(r.Body).Decode(&batch)
		json.NewEncoder(w).Encode(model.IngestResponse{Accepted: len(batch.Events), EndpointID: "ep"})
	}))
	t.Cleanup(srv.Close)
	return srv
}

// A machine tenant's Codex account work never runs in the root program: it is
// handed to `ccquota codex machine-op` as the login, with a Codex binary that
// is not the one in the login's home. The plain agent keeps its own road.
func TestMachineTenantCodexWorkRunsAsTheLogin(t *testing.T) {
	home := t.TempDir()
	marker := plantCodex(t, home)
	writeCodexLogin(t, filepath.Join(home, ".codex"))
	srv := codexHub(t)
	ra := &RunAs{Login: "grace", UID: uint32(os.Getuid()), GID: uint32(os.Getgid()), Home: home}

	var mu sync.Mutex
	var reqs []codexOpRequest
	var who []*RunAs
	old := runCodexOp
	runCodexOp = func(ctx context.Context, got *RunAs, req codexOpRequest) (codexOpAnswer, error) {
		mu.Lock()
		defer mu.Unlock()
		reqs, who = append(reqs, req), append(who, got)
		return codexOpAnswer{Error: "stub"}, nil
	}
	t.Cleanup(func() { runCodexOp = old })

	a, err := New(Config{HubURL: srv.URL, Token: "t", Home: home, StateDir: t.TempDir(), SessionsDir: t.TempDir(),
		Sources: "codex", Once: true, RunAs: ra})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := a.codexAcct.(loginCodex); !ok {
		t.Fatalf("machine tenant's Codex account work: %T; want loginCodex", a.codexAcct)
	}
	if err := a.cycle(withRunAs(context.Background(), ra)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("the codex in the login's home was started by the agent itself")
	}
	if len(reqs) == 0 {
		t.Fatal("no Codex account work was handed to the login's machine-op")
	}
	for i, req := range reqs {
		if who[i] != ra {
			t.Fatalf("machine-op %d ran as %+v; want %s", i, who[i], ra.Login)
		}
		if req.Binary != "" && (underLogin(ra, req.Binary) || strings.HasPrefix(req.Binary, home)) {
			t.Fatalf("machine-op %d names %s — a Codex in the login's home", i, req.Binary)
		}
		if req.Home != filepath.Join(home, ".codex") {
			t.Fatalf("machine-op %d for %s", i, req.Home)
		}
	}

	// The plain agent (its own login) keeps the in-process road and its own
	// binary choice: the home's ~/.local/bin/codex.
	plain, err := New(Config{HubURL: srv.URL, Token: "t", Home: home, StateDir: t.TempDir(), SessionsDir: t.TempDir(), Sources: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := plain.codexAcct.(localCodex); !ok {
		t.Fatalf("plain agent: %T; want localCodex", plain.codexAcct)
	}
	if got := plain.codexBinary(); got != filepath.Join(home, ".local", "bin", "codex") {
		t.Fatalf("plain agent's codex %q", got)
	}
	if got := a.codexBinary(); strings.HasPrefix(got, home) {
		t.Fatalf("machine tenant's codex %q is in the login's home", got)
	}
}

// Root names only the machine's own Codex: the configured one, else the
// release's tools/bin/codex beside this program's bin/.
func TestMachineCodexBinaryIsTheReleases(t *testing.T) {
	rel := t.TempDir()
	for _, d := range []string{"bin", "tools/bin"} {
		if err := os.MkdirAll(filepath.Join(rel, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	self := filepath.Join(rel, "bin", "ccquota")
	os.WriteFile(self, []byte("x"), 0o755)
	old := codexOpSelf
	codexOpSelf = func() (string, error) { return self, nil }
	t.Cleanup(func() { codexOpSelf = old })
	if got := machineCodexBinary(""); got != "" {
		t.Fatalf("no release codex: %q; want none (the login's command resolves it)", got)
	}
	shipped := filepath.Join(rel, "tools", "bin", "codex")
	os.WriteFile(shipped, []byte("x"), 0o755)
	want, _ := filepath.EvalSymlinks(shipped)
	if got, _ := filepath.EvalSymlinks(machineCodexBinary("")); got != want {
		t.Fatalf("release codex: %q; want %q", got, want)
	}
	if got := machineCodexBinary("/opt/codex/bin/codex"); got != "/opt/codex/bin/codex" {
		t.Fatalf("configured: %q", got)
	}
	ra := &RunAs{Login: "grace", Home: "/Users/grace"}
	if p := strings.Split(strings.TrimPrefix(codexOpEnv(ra)[0], "PATH="), ":"); len(p) == 0 || filepath.Base(filepath.Dir(p[0])) != "tools" {
		t.Fatalf("PATH %q; want the release's tools/bin first", p)
	}
}

func TestRunCodexOpRefusesBadRequests(t *testing.T) {
	for _, in := range []string{`{"op":"query","home":"relative"}`, `{"op":"rm","home":"/x"}`, `nope`} {
		var out bytes.Buffer
		if err := RunCodexOp(strings.NewReader(in), &out); err == nil {
			t.Fatalf("%s: accepted", in)
		}
	}
	// a query whose account moved under it answers that, and starts nothing
	home := t.TempDir()
	writeCodexLogin(t, home)
	var out bytes.Buffer
	if err := RunCodexOp(strings.NewReader(`{"op":"query","home":"`+home+`","binary":"/nonexistent","account":"someone-else"}`), &out); err != nil {
		t.Fatal(err)
	}
	var ans codexOpAnswer
	if json.Unmarshal(out.Bytes(), &ans) != nil || !strings.Contains(ans.Error, "account changed") || ans.Result != nil {
		t.Fatalf("answer %s", out.String())
	}
}

// One login's unreadable or out-of-home Codex registry turns off that login's
// Codex collection, never the machine program: New succeeds, and the cycle
// keeps the rest of the login's collection going.
func TestMachineTenantBadCodexRegistry(t *testing.T) {
	srv := codexHub(t)
	for name, body := range map[string]string{
		"invalid":     `{"profiles":[`,
		"outside":     `{"profiles":[{"name":"other","home":"/Users/someone-else/.codex"}]}`,
		"duplicate":   `{"profiles":[{"name":"a","home":"/x"},{"name":"a","home":"/y"}]}`,
		"unknown-use": `{"active":"ghost","profiles":[]}`,
	} {
		home := t.TempDir()
		os.MkdirAll(filepath.Join(home, ".ccquota"), 0o700)
		os.WriteFile(filepath.Join(home, ".ccquota", "codex-profiles.json"), []byte(body), 0o600)
		ra := &RunAs{Login: "grace", UID: uint32(os.Getuid()), GID: uint32(os.Getgid()), Home: home}
		a, err := New(Config{HubURL: srv.URL, Token: "t", Home: home, StateDir: t.TempDir(), SessionsDir: t.TempDir(),
			Sources: "codex", Once: true, RunAs: ra})
		if err != nil {
			t.Fatalf("%s: machine tenant refused to start: %v", name, err)
		}
		if !a.codexOn || len(a.codexProfileSnapshot()) != 0 {
			t.Fatalf("%s: codexOn %v, %d profiles", name, a.codexOn, len(a.codexProfileSnapshot()))
		}
		if err := a.cycle(withRunAs(context.Background(), ra)); err != nil {
			t.Fatalf("%s: cycle: %v", name, err)
		}
		// fixed: collected from the next cycle on
		os.Remove(filepath.Join(home, ".ccquota", "codex-profiles.json"))
		if err := a.cycle(withRunAs(context.Background(), ra)); err != nil || len(a.codexProfileSnapshot()) != 1 {
			t.Fatalf("%s: after the fix: %v, %d profiles", name, err, len(a.codexProfileSnapshot()))
		}
		// a plain agent still refuses a bad registry at start, as before
		os.WriteFile(filepath.Join(home, ".ccquota", "codex-profiles.json"), []byte(`{"profiles":[`), 0o600)
		if _, err := New(Config{HubURL: srv.URL, Token: "t", Home: home, StateDir: t.TempDir(), SessionsDir: t.TempDir(), Sources: "codex"}); err == nil {
			t.Fatalf("%s: plain agent started on an invalid registry", name)
		}
	}
}
