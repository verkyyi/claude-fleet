package mcp

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// seedCodexEvent puts a Codex figure next to the Claude one, so an agent
// calling these tools is looking at both sources at once.
func seedCodexEvent(t *testing.T, st *store.Store) {
	t.Helper()
	c := 100.0
	if _, _, err := st.InsertEvents([]model.UsageEvent{{
		Source: model.SourceCodex, AccountUUID: "acct", EndpointID: "ep",
		MessageUUID: "cx1", SessionID: "s-cx", TS: time.Now().UTC().Add(-time.Minute),
		Model: "gpt-5", OutputTokens: 500, CostUSD: &c, CWD: "/w",
	}}); err != nil {
		t.Fatal(err)
	}
}

func structured(t *testing.T, res map[string]any) map[string]any {
	t.Helper()
	out, ok := res["result"].(map[string]any)["structuredContent"].(map[string]any)
	if !ok {
		t.Fatalf("no structuredContent: %+v", res)
	}
	return out
}

// costOf pulls one source's figure out of a bucket's split, the way an agent
// reading these payloads has to.
func costOf(t *testing.T, bucket map[string]any, source string) map[string]any {
	t.Helper()
	entries, ok := bucket["cost"].([]any)
	if !ok {
		t.Fatalf("bucket has no per-source cost list: %+v", bucket)
	}
	for _, e := range entries {
		m := e.(map[string]any)
		if m["source"] == source {
			return m
		}
	}
	return nil
}

// Every usage_by_* tool must hand back cost split by source, with each entry
// saying which kind of money it is, and no blended figure anywhere.
func TestUsageToolsReturnCostPerSource(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct", "ep", "/w", "u1", "u2")
	seedCodexEvent(t, st)

	for _, tool := range []string{"usage_by_account", "usage_by_endpoint", "usage_by_project", "usage_by_source"} {
		out := structured(t, call(t, ts, tool, map[string]any{"account": "all"}))
		buckets, _ := out["buckets"].([]any)
		if len(buckets) == 0 {
			t.Fatalf("%s returned no buckets: %+v", tool, out)
		}
		var claude, codex float64
		for _, b := range buckets {
			bucket := b.(map[string]any)
			entries, ok := bucket["cost"].([]any)
			if !ok {
				t.Fatalf("%s bucket carries no cost split: %+v", tool, bucket)
			}
			if _, blended := bucket["cost_usd"]; blended {
				t.Errorf("%s still emits a blended cost_usd: %+v", tool, bucket)
			}
			for _, e := range entries {
				m := e.(map[string]any)
				kind, _ := m["kind"].(string)
				if kind == "" {
					t.Errorf("%s cost entry has no kind: %+v", tool, m)
				}
				switch m["source"] {
				case model.SourceClaude:
					claude += m["cost_usd"].(float64)
					if kind != model.CostNotional {
						t.Errorf("%s calls claude money %q", tool, kind)
					}
				case model.SourceCodex:
					codex += m["cost_usd"].(float64)
					if kind != model.CostNotional {
						t.Errorf("%s calls codex money %q", tool, kind)
					}
				}
			}
		}
		if claude != 2 || codex != 100 {
			t.Errorf("%s: claude=%v codex=%v, want 2 and 100", tool, claude, codex)
		}
		// And the envelope says where each figure's rates come from.
		if _, ok := out["pricing"].([]any); !ok {
			t.Errorf("%s carries no per-source provenance: %+v", tool, out)
		}
		if note, _ := out["cost_note"].(string); note != pricing.MixedSourceNote {
			t.Errorf("%s unfiltered cost_note = %q, want the mixed-source note", tool, note)
		}
	}
}

// usage_summary is the tool an agent reaches for when asked "what did this
// cost", so it has to make the difference between an estimate and an invoice
// impossible to miss.
func TestUsageSummaryReportsNotionalAndRealSpend(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct", "ep", "/w", "u1", "u2")
	seedCodexEvent(t, st)
	if err := st.SetPlanPrice(model.SubscriptionPlan{
		Plan: "max", Source: model.SourceClaude, MonthlyCost: 200, Currency: "USD",
		EffectiveFrom: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	out := structured(t, call(t, ts, "usage_summary", map[string]any{"account": "all"}))
	if out["cost_notional"].(float64) != 102 {
		t.Errorf("cost_notional = %v, want 102 (claude 2 + codex 100)", out["cost_notional"])
	}
	if _, billed := out["cost_billed"]; billed {
		t.Errorf("usage_summary still carries cost_billed: %+v", out)
	}
	summary := out["summary"].(map[string]any)
	if _, blended := summary["cost_usd"]; blended {
		t.Errorf("usage_summary still emits a blended cost_usd: %+v", summary)
	}
	if costOf(t, summary, model.SourceCodex)["kind"] != model.CostNotional {
		t.Errorf("summary does not mark codex money as notional: %+v", summary["cost"])
	}

	rs := out["real_spend"].(map[string]any)
	if rs["subscription"].(float64) <= 0 {
		t.Fatalf("real_spend has no subscription term: %+v", rs)
	}
	if rs["total"].(float64) != rs["subscription"].(float64) {
		t.Errorf("real_spend.total is not its subscription term (the notional figure entered it?): %+v", rs)
	}
	if len(out["subscription_spend"].([]any)) == 0 {
		t.Error("usage_summary reports no subscription spend")
	}
}

// A source filter is the sanctioned way to make one figure mean one thing, so
// the note beside it must be that source's own — not, as before, "anything
// that is not Claude gets the Codex note".
func TestUsageToolsCostNoteFollowsTheSource(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct", "ep", "/w", "u1")
	seedCodexEvent(t, st)

	for _, tc := range []struct{ source, want string }{
		{model.SourceClaude, pricing.ClaudePriceNote},
		{model.SourceCodex, pricing.OpenAIPriceNote},
	} {
		out := structured(t, call(t, ts, "usage_summary", map[string]any{"account": "all", "source": tc.source}))
		if got, _ := out["cost_note"].(string); got != tc.want {
			t.Errorf("source=%s cost_note = %q, want its own note", tc.source, got)
		}
		provs := out["pricing"].([]any)
		if len(provs) != 1 || provs[0].(map[string]any)["source"] != tc.source {
			t.Errorf("source=%s provenance = %+v, want exactly its own", tc.source, provs)
		}
	}
}

// usage_history folds hours into buckets; the split has to survive the fold.
func TestUsageHistoryKeepsTheSplitThroughTheFold(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct", "ep", "/w", "u1", "u2")
	seedCodexEvent(t, st)

	out := structured(t, call(t, ts, "usage_history", map[string]any{"account": "all", "granularity": "day"}))
	series := out["series"].([]any)
	if len(series) == 0 {
		t.Fatalf("no series: %+v", out)
	}
	var claude, codex float64
	for _, b := range series {
		bucket := b.(map[string]any)
		if _, blended := bucket["cost_usd"]; blended {
			t.Errorf("a folded bucket carries a blended cost_usd: %+v", bucket)
		}
		if c := costOf(t, bucket, model.SourceClaude); c != nil {
			claude += c["cost_usd"].(float64)
		}
		if c := costOf(t, bucket, model.SourceCodex); c != nil {
			codex += c["cost_usd"].(float64)
		}
	}
	if claude != 2 || codex != 100 {
		t.Errorf("folded series: claude=%v codex=%v, want 2 and 100", claude, codex)
	}
}

// The descriptions are the only thing standing between an agent and a
// confident sentence about money it misread, so pin the rule into them.
func TestToolDescriptionsStateWhatTheFiguresAre(t *testing.T) {
	specs := map[string]string{}
	for _, s := range toolSpecs() {
		specs[s.Name] = s.Description
	}
	for _, name := range []string{
		"usage_summary", "usage_history", "usage_by_account", "usage_by_source",
		"usage_by_user", "usage_by_endpoint", "usage_by_project", "usage_by_session",
	} {
		d, ok := specs[name]
		if !ok {
			t.Fatalf("%s is no longer registered", name)
		}
		for _, want := range []string{"PER SOURCE", "NOTIONAL", "Real spend is the subscription"} {
			if !strings.Contains(d, want) {
				t.Errorf("%s's description does not say %q:\n%s", name, want, d)
			}
		}
	}
	// The source chip must offer every source.
	chip := chipProps["source"].(map[string]any)
	enum, _ := chip["enum"].([]string)
	if len(enum) != len(model.Sources) {
		t.Fatalf("source chip enum = %v, want every source in model.Sources (%v)", enum, model.Sources)
	}
}
