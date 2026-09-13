package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// fakePricer prices from a model -> rate map, in the same shape the real table
// does: absent means unpriced (nil), never zero.
type fakePricer struct {
	rate     map[string]float64 // per output token
	supplied bool               // mimic a pricing bug: derive a supplied figure
}

func (f fakePricer) Apply(evs []model.UsageEvent) {
	for i := range evs {
		e := &evs[i]
		if model.CostIsSupplied(e.Source) {
			if f.supplied {
				// What a future edit could wrongly do: compute rather than pass
				// the invoice through.
				c := 999.0
				e.CostUSD = &c
			}
			// Otherwise leave the supplied figure exactly as it arrived, which
			// is what pricing.vendorBillCost/voiceCost do.
			continue
		}
		r, ok := f.rate[e.Model]
		if !ok {
			e.CostUSD = nil
			if e.Details != nil {
				e.Details.PriceBasis = "unpriced: no rate"
			}
			continue
		}
		c := float64(e.OutputTokens) * r
		e.CostUSD = &c
		if e.Details != nil {
			e.Details.PriceBasis = "test rate"
		}
	}
}

func repriceEvent(uuid, source, mdl string, out int64, cost *float64) model.UsageEvent {
	return model.UsageEvent{
		Source: source, AccountUUID: "acct-a", EndpointID: "ep-a1",
		MessageUUID: uuid, SessionID: "s1",
		TS:    time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC),
		Model: mdl, OutputTokens: out, CostUSD: cost,
		Details: &model.UsageDetails{Provider: "openai"},
	}
}

// The reason this feature exists: a rate stated after the events arrived must be
// able to reach them. Before Reprice, an operator who could not state a contract
// last month had no way to price the month they already had.
func TestReprice_PricesEventsStoredBeforeTheRateExisted(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		repriceEvent("u-1", "gateway", "deepseek-chat", 100, nil), // arrived unpriced
		repriceEvent("u-2", "gateway", "deepseek-chat", 50, nil),
	}); err != nil {
		t.Fatal(err)
	}

	got, err := s.Reprice(fakePricer{rate: map[string]float64{"deepseek-chat": 0.01}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Scanned != 2 || got.Changed != 2 || got.NewlyPriced != 2 || got.Unpriced != 0 {
		t.Fatalf("result = %+v", got)
	}

	var total float64
	var unpriced int64
	if err := s.db.QueryRow(`SELECT COALESCE(SUM(cost_usd),0), SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END)
		FROM usage_events`).Scan(&total, &unpriced); err != nil {
		t.Fatal(err)
	}
	if total != 1.5 || unpriced != 0 {
		t.Fatalf("events: total %v unpriced %d; want 1.5 and 0", total, unpriced)
	}

	// The rollup must agree with the rows underneath it, or the dashboards keep
	// showing the stale money this feature exists to correct.
	var hTotal float64
	var hUnpriced int64
	if err := s.db.QueryRow(`SELECT COALESCE(SUM(cost_usd),0), COALESCE(SUM(unpriced_events),0)
		FROM usage_hourly`).Scan(&hTotal, &hUnpriced); err != nil {
		t.Fatal(err)
	}
	if hTotal != 1.5 || hUnpriced != 0 {
		t.Fatalf("rollup: total %v unpriced %d; want 1.5 and 0", hTotal, hUnpriced)
	}
}

// A rate REMOVED is as real as one added: the figure must go back to absent, not
// linger as the last number anyone happened to compute.
func TestReprice_RemovingARateReturnsTheEventToUnpriced(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	c := 5.0
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		repriceEvent("u-1", "gateway", "qwen-plus", 100, &c),
	}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Reprice(fakePricer{rate: map[string]float64{}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Changed != 1 || got.Unpriced != 1 || got.NewlyPriced != 0 {
		t.Fatalf("result = %+v", got)
	}
	var cost *float64
	if err := s.db.QueryRow(`SELECT cost_usd FROM usage_events`).Scan(&cost); err != nil {
		t.Fatal(err)
	}
	if cost != nil {
		t.Fatalf("cost = %v; want NULL, not a leftover figure", *cost)
	}
}

// THE GUARD. A vendor bill and a voice charge are invoices: no rate table can
// reproduce them, so repricing must refuse rather than overwrite one. The fake
// pricer here does exactly what a careless future edit would.
func TestReprice_RefusesToOverwriteASuppliedCost(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	invoice := 38.7
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		repriceEvent("u-1", "vendor_bill", "video-gen", 0, &invoice),
	}); err != nil {
		t.Fatal(err)
	}
	_, err := s.Reprice(fakePricer{rate: map[string]float64{}, supplied: true}, time.Time{})
	if err == nil {
		t.Fatal("repricing rewrote a supplied cost without complaint")
	}
	for _, want := range []string{"vendor_bill", "supplied cost", "invoice"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
	// Refusing means the transaction rolled back: the invoice is untouched.
	var cost float64
	if err := s.db.QueryRow(`SELECT cost_usd FROM usage_events`).Scan(&cost); err != nil {
		t.Fatal(err)
	}
	if cost != invoice {
		t.Fatalf("invoice = %v; want %v left exactly as supplied", cost, invoice)
	}
}

// A supplied cost passes through a NORMAL reprice untouched — the everyday case,
// not the refusal above. Both sources are covered by deriving them from
// model.CostIsSupplied rather than naming them, so a new supplied source is
// covered the day it is added.
func TestReprice_LeavesSuppliedCostsAlone(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	var evs []model.UsageEvent
	var want []float64
	for i, src := range model.Sources {
		if !model.CostIsSupplied(src) {
			continue
		}
		amount := 10.0 + float64(i)
		evs = append(evs, repriceEvent("u-"+src, src, "line-item", 0, &amount))
		want = append(want, amount)
	}
	if len(evs) == 0 {
		t.Fatal("no supplied-cost source in model.Sources; this test has nothing to protect")
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	got, err := s.Reprice(fakePricer{rate: map[string]float64{"line-item": 1.0}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Changed != 0 {
		t.Fatalf("changed %d supplied figures; want 0", got.Changed)
	}
	rows, err := s.db.Query(`SELECT cost_usd FROM usage_events ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var i int
	for rows.Next() {
		var c float64
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		if c != want[i] {
			t.Errorf("row %d = %v; want %v", i, c, want[i])
		}
		i++
	}
}

// THE INVARIANT that guards repriceColumns. Ingest prices an event; repricing it
// immediately with the same table must change nothing. If it does, reprice is
// reading less of the row than pricing depends on — a rate keyed on a column
// repriceColumns forgot — and every reprice would silently restate money.
func TestReprice_IsANoOpOnFreshlyPricedEvents(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	p := fakePricer{rate: map[string]float64{"qwen-plus": 0.02, "deepseek-chat": 0.01}}

	evs := []model.UsageEvent{
		repriceEvent("u-1", "gateway", "qwen-plus", 100, nil),
		repriceEvent("u-2", "gateway", "deepseek-chat", 7, nil),
		repriceEvent("u-3", "gateway", "no-such-model", 5, nil), // stays unpriced
		repriceEvent("u-4", "claude", "qwen-plus", 3, nil),
	}
	// Price them the way ingest does, then store the result.
	p.Apply(evs)
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	before := snapshotCosts(t, s)

	got, err := s.Reprice(p, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Changed != 0 {
		t.Errorf("reprice changed %d of %d freshly priced events; it must be a no-op", got.Changed, got.Scanned)
	}
	if after := snapshotCosts(t, s); after != before {
		t.Errorf("costs moved on a no-op reprice:\n before %s\n after  %s", before, after)
	}
}

// since bounds the work: an operator correcting this month's contract should not
// have to restate last month's.
func TestReprice_SinceBoundsWhichEventsAreTouched(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	old := repriceEvent("u-old", "gateway", "qwen-plus", 100, nil)
	old.TS = time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	recent := repriceEvent("u-new", "gateway", "qwen-plus", 100, nil)
	if _, _, err := s.InsertEvents([]model.UsageEvent{old, recent}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Reprice(fakePricer{rate: map[string]float64{"qwen-plus": 0.01}},
		time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if got.Scanned != 1 || got.Changed != 1 {
		t.Fatalf("result = %+v; want only the September event scanned", got)
	}
	var cost *float64
	if err := s.db.QueryRow(`SELECT cost_usd FROM usage_events WHERE message_uuid = 'u-old'`).Scan(&cost); err != nil {
		t.Fatal(err)
	}
	if cost != nil {
		t.Fatalf("August event was repriced to %v; --since should have excluded it", *cost)
	}
}

// The price basis travels with the figure. A corrected number under the old
// basis is worse than either alone: it says the figure came from a rate that did
// not produce it.
func TestReprice_RestampsThePriceBasis(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	e := repriceEvent("u-1", "gateway", "qwen-plus", 100, nil)
	e.Details.PriceBasis = "unpriced: no gateway rate configured"
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Reprice(fakePricer{rate: map[string]float64{"qwen-plus": 0.01}}, time.Time{}); err != nil {
		t.Fatal(err)
	}
	var raw string
	if err := s.db.QueryRow(`SELECT details_json FROM usage_events`).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var d model.UsageDetails
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatal(err)
	}
	if d.PriceBasis != "test rate" {
		t.Fatalf("price basis = %q; want the new one, not the unpriced note", d.PriceBasis)
	}
}

// A batch boundary must not be a correctness boundary: repricing more events
// than one page holds has to reach all of them.
func TestReprice_CrossesBatchBoundaries(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	const n = repriceBatch + 37
	evs := make([]model.UsageEvent, 0, n)
	for i := 0; i < n; i++ {
		evs = append(evs, repriceEvent(fmt.Sprintf("u-%d", i), "gateway", "qwen-plus", 1, nil))
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	got, err := s.Reprice(fakePricer{rate: map[string]float64{"qwen-plus": 1.0}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Scanned != n || got.Changed != n {
		t.Fatalf("result = %+v; want %d scanned and changed", got, n)
	}
	var unpriced int64
	if err := s.db.QueryRow(`SELECT SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) FROM usage_events`).Scan(&unpriced); err != nil {
		t.Fatal(err)
	}
	if unpriced != 0 {
		t.Fatalf("%d events left unpriced past the batch boundary", unpriced)
	}
}

func snapshotCosts(t *testing.T, s *Store) string {
	t.Helper()
	rows, err := s.db.Query(`SELECT message_uuid, COALESCE(CAST(cost_usd AS TEXT), 'NULL'), details_json
		FROM usage_events ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out string
	for rows.Next() {
		var uuid, cost, details string
		if err := rows.Scan(&uuid, &cost, &details); err != nil {
			t.Fatal(err)
		}
		out += uuid + "=" + cost + " " + details + "\n"
	}
	return out
}

// Changed counts rows; NetUSD says what happened to the money. An operator
// reading "changed 24,926" cannot tell a rounding shuffle from a doubling, and
// this is a ledger of real charges.
func TestReprice_ReportsTheNetMoneyDelta(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	was := 1.0
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		repriceEvent("u-1", "gateway", "qwen-plus", 100, &was), // 1.00 -> 2.00
		repriceEvent("u-2", "gateway", "qwen-plus", 50, nil),   // unpriced -> 1.00
	}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Reprice(fakePricer{rate: map[string]float64{"qwen-plus": 0.02}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	// u-1: 2.00 - 1.00 = +1.00; u-2: 1.00 - nothing = +1.00
	if got.NetUSD != 2.0 {
		t.Fatalf("NetUSD = %v; want +2.0", got.NetUSD)
	}
	if got.Changed != 2 || got.NewlyPriced != 1 {
		t.Fatalf("result = %+v", got)
	}
}

// MaxAbsUSD is what separates "a rate was corrected by a hair" from "a rate was
// corrected by a factor of ten", which the row count cannot.
func TestReprice_ReportsTheLargestSingleChange(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	tiny, big := 0.999999999, 1.0
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		repriceEvent("u-small", "gateway", "qwen-plus", 50, &tiny), // moves ~1e-9
		repriceEvent("u-big", "gateway", "qwen-plus", 100, &big),   // moves +1.00
	}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Reprice(fakePricer{rate: map[string]float64{"qwen-plus": 0.02}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Changed != 2 {
		t.Fatalf("result = %+v", got)
	}
	// u-small: 1.00 - 0.999999999; u-big: 2.00 - 1.00. The max must be the big one.
	if got.MaxAbsUSD < 0.99 || got.MaxAbsUSD > 1.01 {
		t.Fatalf("MaxAbsUSD = %v; want ~1.0, the largest single move", got.MaxAbsUSD)
	}
}
