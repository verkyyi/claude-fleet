package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

// The findings envelope must match the rest of the rollup-backed endpoints
// (handleSummary, handleLimitsHistory, MCP usage_history): account_uuid,
// all_accounts, and the ALIGNED window actually queried -- not the raw query
// string, and not a bare array. "now" has no period to align, so since/until
// must be omitted entirely rather than echoing a fake window.
type findingsEnvelope struct {
	AccountUUID string           `json:"account_uuid"`
	AllAccounts bool             `json:"all_accounts"`
	Since       *time.Time       `json:"since"`
	Until       *time.Time       `json:"until"`
	View        string           `json:"view"`
	Findings    []findingSummary `json:"findings"`
}

type findingSummary struct {
	Kind, Severity string
	Scope          map[string]string
}

func TestFindingsReviewAndNow(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)

	// since/until are deliberately NOT hour-aligned here (12:15, 14:45) to
	// prove the response echoes the ALIGNED window s.scope() actually queried
	// (12:00-15:00), not the raw query string.
	var review findingsEnvelope
	h.getJSON(t, "/v1/findings?account=all&since=2026-08-31T12:15:00Z&until=2026-08-31T14:45:00Z", &review)
	if review.View != "review" {
		t.Errorf("view = %q, want %q", review.View, "review")
	}
	if review.AccountUUID != "*" || !review.AllAccounts {
		t.Errorf("account_uuid=%q all_accounts=%v, want *,true for account=all", review.AccountUUID, review.AllAccounts)
	}
	wantSince := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	wantUntil := time.Date(2026, 8, 31, 15, 0, 0, 0, time.UTC)
	if review.Since == nil || !review.Since.Equal(wantSince) {
		t.Errorf("since = %v, want the widened %v (not the raw 12:15 query)", review.Since, wantSince)
	}
	if review.Until == nil || !review.Until.Equal(wantUntil) {
		t.Errorf("until = %v, want the widened %v (not the raw 14:45 query)", review.Until, wantUntil)
	}
	// s-small's one turn is unpriced (cost nil) -> unpriced_model must fire; nothing else has data
	if len(review.Findings) != 1 || review.Findings[0].Kind != "unpriced_model" {
		t.Fatalf("%+v", review.Findings)
	}

	// Now: the endpoint last reported at ingest (seconds ago) -> not stale; no windows, no live -> empty.
	// since/until must be ABSENT from the JSON entirely, not merely null --
	// checked against the raw bytes, since a missing key and an explicit null
	// both unmarshal to a nil *time.Time.
	_, rawNow := h.get(t, "/v1/findings?account=all&view=now")
	var nowRaw map[string]json.RawMessage
	if err := json.Unmarshal(rawNow, &nowRaw); err != nil {
		t.Fatal(err)
	}
	if _, present := nowRaw["since"]; present {
		t.Errorf("view=now must omit \"since\" entirely, got %s", rawNow)
	}
	if _, present := nowRaw["until"]; present {
		t.Errorf("view=now must omit \"until\" entirely, got %s", rawNow)
	}

	var now findingsEnvelope
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if now.View != "now" {
		t.Errorf("view = %q, want %q", now.View, "now")
	}
	if now.AccountUUID != "*" || !now.AllAccounts {
		t.Errorf("account_uuid=%q all_accounts=%v, want *,true for account=all", now.AccountUUID, now.AllAccounts)
	}
	if len(now.Findings) != 0 {
		t.Fatalf("%+v", now.Findings)
	}
	// make the endpoint stale
	old := time.Now().Add(-3 * time.Hour)
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET last_seen = ?`, old.UTC().Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now.Findings) != 1 || now.Findings[0].Kind != "stale_agent" {
		t.Fatalf("%+v", now.Findings)
	}
	_ = model.Batch{}
}

// Regression for a real production bug (measured against a 292,753-event
// snapshot of the prod hub): GatherReview used to feed runaway() a bounded
// top-N sample of sessions and let it derive the median from THAT sample.
// The top N by tokens is, by construction, biased toward the largest
// sessions -- its own median is nowhere near the true population median --
// so on a hub with more sessions than the pull limit, the resulting
// threshold could exceed even the genuine outlier it exists to catch, and
// the rule silently never fired.
//
// This seeds realistic proportions: many (600) tiny sessions that dominate
// the TRUE population median, a long tail of 500 "medium" sessions big
// enough to fill up an old top-500 pull on their own, and one genuine
// outlier. It fails against the pre-fix gatherer (pull=500, slice-derived
// median) and passes once the median comes from store.SessionTokenMedian
// over the full population instead.
func TestFindings_RunawayUsesPopulationMedianNotSample(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "bulk")
	// Establish the account/endpoint records the same way a real batch does.
	seed := batchFor("acct-a", "bulk", []string{"seed-0"}, "/seed")
	if resp := h.push(t, tok, seed); resp.StatusCode != http.StatusOK {
		t.Fatalf("seed push: %d", resp.StatusCode)
	}

	const (
		smallCount  = 600
		mediumCount = 500
		smallOut    = int64(500)         // 2 turns -> 1,000 tokens/session
		mediumOut   = int64(15_000_000)  // 2 turns -> 30,000,000 tokens/session
		outlierOut  = int64(250_000_000) // 2 turns -> 500,000,000 tokens
	)
	ts := time.Date(2026, 8, 20, 12, 0, 0, 0, time.UTC)
	mk := func(session string, turn int, out int64) model.UsageEvent {
		return model.UsageEvent{
			AccountUUID: "acct-a", EndpointID: "ep_bulk", SessionID: session,
			MessageUUID: fmt.Sprintf("%s-%d", session, turn), TS: ts,
			Model: "claude-sonnet-5", OutputTokens: out,
		}
	}
	var evs []model.UsageEvent
	for i := 0; i < smallCount; i++ {
		session := fmt.Sprintf("small-%d", i)
		evs = append(evs, mk(session, 0, smallOut), mk(session, 1, smallOut))
	}
	for i := 0; i < mediumCount; i++ {
		session := fmt.Sprintf("medium-%d", i)
		evs = append(evs, mk(session, 0, mediumOut), mk(session, 1, mediumOut))
	}
	evs = append(evs, mk("outlier", 0, outlierOut), mk("outlier", 1, outlierOut))

	if _, _, err := h.srv.Store.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}

	var got findingsEnvelope
	h.getJSON(t, "/v1/findings?account=acct-a&since=2026-08-20T00:00:00Z&until=2026-08-21T00:00:00Z", &got)

	var runaways []findingSummary
	for _, f := range got.Findings {
		if f.Kind == "runaway_session" {
			runaways = append(runaways, f)
		}
	}
	if len(runaways) != 1 || runaways[0].Scope["session"] != "outlier" {
		t.Fatalf("runaway findings = %+v, want exactly one naming the outlier session; all findings: %+v", runaways, got.Findings)
	}
}

// The wire shape of a finding's attribution, end to end through the real
// ingest path and the real handler.
//
// This is the issue's headline bug as a test: GatherNowSource held the whole
// store.Endpoint -- OSUser and Team included -- and passed only Label, so the
// stale-agent alert could not say whose machine it was while the hub knew
// exactly. It asserts the two shapes that matter and nothing in between:
//
//   - known  -> owner.user / owner.team, verbatim, untranslated
//   - unknown-> the "owner" KEY IS ABSENT, not null and not an empty object,
//     because downstream tests presence to decide whether to print the line.
//
// Both endpoints are stale, so the second one also proves the weaker property
// the issue calls out: a finding with no attribution still SHOWS UP. Losing
// the alert because nobody owns the box would be worse than the bug.
func TestFindingsNow_OwnerOnTheWire(t *testing.T) {
	h := newHarness(t)

	// ep_mac: the hub knows both halves. os_user arrives on the batch's
	// identity; team is operator-side and has only one writer.
	macTok := h.enroll(t, "mac")
	if resp := h.push(t, macTok, batchFor("acct-a", "mac", []string{"m-1"}, "/srv/api")); resp.StatusCode != http.StatusOK {
		t.Fatalf("push mac: %d", resp.StatusCode)
	}
	if err := h.srv.Store.SetEndpointTeam("ep_mac", "infra"); err != nil {
		t.Fatal(err)
	}

	// ep_anon: enrolled, reporting, and attributed to nobody. Clearing os_user
	// in SQL is the only way to get there -- the ingest identity always carries
	// one -- and it is the state of any endpoint enrolled before the column
	// existed.
	anonTok := h.enroll(t, "anon")
	if resp := h.push(t, anonTok, batchFor("acct-a", "anon", []string{"a-1"}, "/srv/api")); resp.StatusCode != http.StatusOK {
		t.Fatalf("push anon: %d", resp.StatusCode)
	}
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET os_user = '' WHERE endpoint_id = 'ep_anon'`); err != nil {
		t.Fatal(err)
	}

	// Both past findings.StaleAfter, so both rules fire and the two shapes appear in one
	// response rather than two runs that could diverge.
	old := time.Now().Add(-3 * time.Hour).UTC().Format(time.RFC3339Nano)
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET last_seen = ?`, old); err != nil {
		t.Fatal(err)
	}

	var env struct {
		Findings []struct {
			Kind  string `json:"kind"`
			Title string `json:"title"`
			Owner *struct {
				User string `json:"user"`
				Team string `json:"team"`
			} `json:"owner"`
		} `json:"findings"`
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &env)
	if len(env.Findings) != 2 {
		t.Fatalf("want two stale_agent findings, got %+v", env.Findings)
	}
	for _, f := range env.Findings {
		if f.Kind != "stale_agent" {
			t.Fatalf("unexpected finding %q: %+v", f.Kind, f)
		}
		switch {
		case strings.Contains(f.Title, "mac"):
			if f.Owner == nil || f.Owner.User != "ci" || f.Owner.Team != "infra" {
				t.Errorf("mac is a known (login, team): owner = %+v, want ci/infra", f.Owner)
			}
		case strings.Contains(f.Title, "anon"):
			if f.Owner != nil {
				t.Errorf("anon has no attribution: owner = %+v, want none", f.Owner)
			}
		default:
			t.Errorf("finding names neither endpoint: %q", f.Title)
		}
	}

	// Absent, not null: a missing key and an explicit null both decode to a nil
	// pointer above, so the distinction has to be read off the raw bytes.
	_, raw := h.get(t, "/v1/findings?account=all&view=now")
	var rawEnv struct {
		Findings []map[string]json.RawMessage `json:"findings"`
	}
	if err := json.Unmarshal(raw, &rawEnv); err != nil {
		t.Fatal(err)
	}
	var withOwner, withoutOwner int
	for _, f := range rawEnv.Findings {
		if _, present := f["owner"]; present {
			withOwner++
			continue
		}
		withoutOwner++
	}
	if withOwner != 1 || withoutOwner != 1 {
		t.Errorf("want exactly one finding carrying \"owner\" and one omitting the key entirely, got %d/%d: %s",
			withOwner, withoutOwner, raw)
	}

	// The MCP surface reads the same gatherer and does NOT translate -- a login
	// and a team name are somebody's actual names. Checked here because
	// internal/mcp cannot see this package's harness.
	in, err := h.srv.GatherNowSource(store.AllAccounts, "")
	if err != nil {
		t.Fatal(err)
	}
	var mac *findings.EndpointSeen
	for i := range in.Endpoints {
		if in.Endpoints[i].Label == "mac" {
			mac = &in.Endpoints[i]
		}
	}
	if mac == nil || mac.OSUser != "ci" || mac.Team != "infra" {
		t.Errorf("GatherNowSource must pass OSUser and Team, not just Label: %+v", in.Endpoints)
	}
}
