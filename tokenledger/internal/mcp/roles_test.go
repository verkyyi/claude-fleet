package mcp

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A user over /mcp (claude-fleet#1985): only the tools IsUserTool names,
// each cut to their machine login, no subscription in the answer.
func TestRunUser_ScopedToLogin(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	s := &mcpServer{api: &api.Server{Store: st, Pricing: pricing.Default()}}
	for _, who := range []struct{ acct, ep, login string }{{"acct-a", "mini", "verkyyi"}, {"acct-b", "box", "alice"}} {
		id := model.Identity{AccountUUID: who.acct, Email: who.acct + "@example.com", Hostname: who.ep}
		if err := st.UpsertAccount(id, "max", "default_claude_max_20x"); err != nil {
			t.Fatal(err)
		}
		if err := st.Enroll(who.ep, who.ep, "hash-"+who.ep); err != nil {
			t.Fatal(err)
		}
		if _, _, err := st.InsertEvents([]model.UsageEvent{{AccountUUID: who.acct, EndpointID: who.ep,
			MessageUUID: who.ep + "-1", SessionID: "s-" + who.login, TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 1000, OSUser: who.login}}); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := s.runUser(&api.UserLogins{Login: "alice"}, "list_accounts", map[string]any{}); err == nil || !strings.Contains(err.Error(), "admin") {
		t.Errorf("list_accounts as a user = %v; want refused", err)
	}
	out, err := s.runUser(&api.UserLogins{Login: "alice"}, "list_sessions", map[string]any{"account": "acct-a"})
	if err != nil {
		t.Fatal(err)
	}
	rows := out.(map[string]any)["sessions"].([]store.SessionRow)
	if len(rows) != 1 || rows[0].OSUser != "alice" || rows[0].AccountUUID != "" {
		t.Errorf("list_sessions as alice = %+v", rows)
	}
	if _, err := s.runUser(&api.UserLogins{Login: "alice"}, "get_session", map[string]any{"session_id": "s-verkyyi"}); err == nil {
		t.Error("get_session of someone else's session answered")
	}
	if _, err := s.runUser(&api.UserLogins{Login: "alice"}, "get_session", map[string]any{"session_id": "s-alice"}); err != nil {
		t.Errorf("get_session of her own: %v", err)
	}
	out, err = s.runUser(&api.UserLogins{Login: "alice"}, "usage_summary", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	m := out.(map[string]any)
	if sp, _ := m["subscription_spend"].([]store.SubscriptionSpend); len(sp) != 0 || m["real_spend"] != nil {
		t.Errorf("usage_summary as a user carries subscription money: %+v", m)
	}
	if sum, _ := m["summary"].(*store.Summary); sum == nil || sum.Events != 1 {
		t.Errorf("usage_summary as alice = %+v; want her 1 event", m["summary"])
	}
}
