package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/identity"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func TestCodexIngestIsolationAndSourceQueries(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	tok := h.tokens["mac"]
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET machine_id='machine-1', cc_version='2.1.0'`); err != nil {
		t.Fatal(err)
	}
	batch := model.Batch{Identity: *identity.Codex(), AccountOrigin: model.OriginSession,
		Events: []model.UsageEvent{{MessageUUID: "codex:resp", SessionID: "codex:s1",
			TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC), Model: "gpt-5.3-codex",
			InputTokens: 40, CacheRead: 60, OutputTokens: 20, Thinking: 5}}}
	for i := 0; i < 2; i++ {
		res := h.push(t, tok, batch)
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			t.Fatalf("push: %d", res.StatusCode)
		}
	}
	const scope = "account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z"
	var summary struct {
		Tokens, Events, Unpriced int64
		Thinking                 int64 `json:"thinking_tokens"`
	}
	h.getJSON(t, "/v1/summary?"+scope+"&source=codex", &summary)
	if summary.Tokens != 120 || summary.Events != 1 || summary.Thinking != 5 {
		t.Fatalf("Codex summary: %+v", summary)
	}
	var usage struct {
		Buckets []store.Bucket `json:"buckets"`
	}
	h.getJSON(t, "/v1/usage?"+scope+"&by=source", &usage)
	if len(usage.Buckets) != 2 {
		t.Fatalf("source breakdown: %+v", usage)
	}
	var sessions []store.SessionRow
	h.getJSON(t, "/v1/sessions?"+scope+"&source=codex", &sessions)
	if len(sessions) != 1 || sessions[0].SessionID != "codex:s1" {
		t.Fatalf("sessions: %+v", sessions)
	}
	var limits LimitsView
	h.getJSON(t, "/v1/limits?account=codex:local", &limits)
	if limits.Available || limits.Reason == "" || limits.FiveHour != nil {
		t.Fatalf("Codex claims quota: %+v", limits)
	}
	var accts []store.Account
	h.getJSON(t, "/v1/accounts", &accts)
	for _, acct := range accts {
		if acct.AccountUUID == "codex:local" && (acct.Source != "codex" || acct.Email != "" || acct.EndpointCount != 1) {
			t.Fatalf("wrong Codex account attribution: %+v", acct)
		}
	}
	for _, account := range []string{"acct-a", "codex:local"} {
		endpoints, err := h.srv.Store.ListEndpoints(account)
		if err != nil || len(endpoints) != 1 || endpoints[0].AccountUUID != "acct-a" ||
			endpoints[0].MachineID != "machine-1" || endpoints[0].CCVersion != "2.1.0" {
			t.Fatalf("Codex changed the Claude login or endpoint metadata: %+v err=%v", endpoints, err)
		}
	}
	switches, err := h.srv.Store.AccountSwitches("", 10)
	if err != nil || len(switches) != 0 {
		t.Fatalf("Codex fabricated an account switch: %+v %v", switches, err)
	}
}
