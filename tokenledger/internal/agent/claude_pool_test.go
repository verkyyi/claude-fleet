package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/identity"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// claude-fleet#3204: a login that runs Claude Code on tokens handed in from
// outside (the credential proxy's pool) never runs /login, so ~/.claude.json
// has no oauthAccount. The agent skipped every Claude scan on such a login —
// with Codex on, without a word — and three days of one person's usage never
// reached the hub.

// noLoginHome is fakeHome with the oauthAccount taken out.
func noLoginHome(t *testing.T, n int) string {
	t.Helper()
	home := fakeHome(t, n)
	cfg := `{"machineID":"m1","lastReleaseNotesSeen":"2.1.252","userID":"u"}`
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

// poolHub records each batch's identity and origin.
type poolHub struct {
	mu      sync.Mutex
	batches []model.Batch
	srv     *httptest.Server
}

func newPoolHub(t *testing.T) *poolHub {
	t.Helper()
	h := &poolHub{}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b model.Batch
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		h.mu.Lock()
		h.batches = append(h.batches, b)
		h.mu.Unlock()
		json.NewEncoder(w).Encode(model.IngestResponse{Accepted: len(b.Events), EndpointID: "ep"})
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func TestAgent_NoLoginFilesClaudeUsageUnderThePool(t *testing.T) {
	const n = 40
	h := newPoolHub(t)
	a := newAgent(t, noLoginHome(t, n), h.srv.URL, DefaultSpoolBytesForTest)

	if err := a.cycle(context.Background()); err != nil {
		t.Fatalf("cycle: %v", err)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	got := 0
	for _, b := range h.batches {
		if b.Identity.Source != model.SourceClaude {
			continue
		}
		if b.Identity.AccountUUID != identity.ClaudePoolAccount {
			t.Fatalf("Claude batch filed under %q, want the pool %q", b.Identity.AccountUUID, identity.ClaudePoolAccount)
		}
		// The pool is no login: it must never move the endpoint's account.
		if b.AccountOrigin != model.OriginSession {
			t.Fatalf("pool batch origin %q, want %q", b.AccountOrigin, model.OriginSession)
		}
		if b.Identity.MachineID != "m1" || b.Identity.CCVersion != "2.1.252" {
			t.Fatalf("pool identity lost the machine fields: %+v", b.Identity)
		}
		got += len(b.Events)
	}
	if got != n {
		t.Fatalf("hub received %d of %d Claude turns from a login with no /login", got, n)
	}
}

// A login with no Claude transcripts at all (Codex only) has nothing to file:
// no pool is invented for it.
func TestAgent_NoLoginNoTranscriptsFilesNothing(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(`{"machineID":"m1"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newPoolHub(t)
	a := newAgent(t, home, h.srv.URL, DefaultSpoolBytesForTest)
	if a.hasClaudeTranscripts() {
		t.Fatal("a home with no ~/.claude/projects reads as having transcripts")
	}
	_ = a.cycle(context.Background())
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, b := range h.batches {
		if b.Identity.AccountUUID == identity.ClaudePoolAccount {
			t.Fatalf("a login with no Claude transcripts sent a pool batch: %+v", b.Identity)
		}
	}
}
