package store

import (
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func day(y int, m time.Month, d int) time.Time {
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

func price(plan string, cost float64, from time.Time) model.SubscriptionPlan {
	return model.SubscriptionPlan{Plan: plan, Source: model.SourceClaude, MonthlyCost: cost, EffectiveFrom: from}
}

// An unpriced plan must come back nil, not zero. Zero is a claim that the plan
// was free, and a subscription silently priced at zero makes every ratio built
// on it infinite rather than obviously missing.
func TestPlanPriceUnknownIsNilNeverZero(t *testing.T) {
	s := newStore(t)
	got, err := s.PlanPriceAt("max", model.SourceClaude, day(2026, 9, 1))
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Fatalf("unpriced plan reported a price: %+v", got)
	}
}

// A price change must not rewrite history: last month stays priced at last
// month's price. This is the whole reason plans are a table and not a column.
func TestPlanPriceIsEffectiveDated(t *testing.T) {
	s := newStore(t)
	if err := s.SetPlanPrice(price("max", 200, day(2026, 1, 1))); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPlanPrice(price("max", 250, day(2026, 7, 1))); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct {
		at   time.Time
		want float64
	}{
		{day(2026, 3, 1), 200},
		{day(2026, 6, 30), 200},
		{day(2026, 7, 1), 250}, // effective_from is inclusive
		{day(2026, 9, 1), 250},
	} {
		got, err := s.PlanPriceAt("max", model.SourceClaude, c.at)
		if err != nil || got == nil {
			t.Fatalf("%s: got %+v err=%v", c.at, got, err)
		}
		if got.MonthlyCost != c.want {
			t.Errorf("%s: priced at %v, want %v", c.at.Format(time.RFC3339), got.MonthlyCost, c.want)
		}
	}

	// Before any recorded price the plan is unpriced, not retroactively priced
	// at the earliest figure: nobody has said what it cost then.
	got, err := s.PlanPriceAt("max", model.SourceClaude, day(2025, 12, 1))
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Fatalf("price leaked backwards before effective_from: %+v", got)
	}

	all, err := s.ListPlanPrices()
	if err != nil || len(all) != 2 {
		t.Fatalf("history=%+v err=%v", all, err)
	}
	// Newest first, and the superseded row is closed exactly where the new one opens.
	if all[0].EffectiveTo != nil {
		t.Errorf("current price is closed at %v", all[0].EffectiveTo)
	}
	if all[1].EffectiveTo == nil || !all[1].EffectiveTo.Equal(day(2026, 7, 1)) {
		t.Errorf("superseded price closes at %v, want 2026-07-01", all[1].EffectiveTo)
	}
}

// The same plan name on two vendors is two different prices.
func TestPlanPriceIsPerSource(t *testing.T) {
	s := newStore(t)
	if err := s.SetPlanPrice(price("max", 200, day(2026, 1, 1))); err != nil {
		t.Fatal(err)
	}
	codex := price("max", 60, day(2026, 1, 1))
	codex.Source = model.SourceCodex
	if err := s.SetPlanPrice(codex); err != nil {
		t.Fatal(err)
	}
	for source, want := range map[string]float64{model.SourceClaude: 200, model.SourceCodex: 60} {
		got, err := s.PlanPriceAt("max", source, day(2026, 6, 1))
		if err != nil || got == nil || got.MonthlyCost != want {
			t.Fatalf("%s/max = %+v err=%v, want %v", source, got, err, want)
		}
	}
}

// Re-recording a start date corrects that period's figure; a date behind the
// newest row is refused rather than silently overlapping two periods, which
// would double-count the plan for the overlap.
func TestSetPlanPriceCorrectsInPlaceButRefusesBackdating(t *testing.T) {
	s := newStore(t)
	if err := s.SetPlanPrice(price("max", 200, day(2026, 1, 1))); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPlanPrice(price("max", 210, day(2026, 1, 1))); err != nil {
		t.Fatal(err)
	}
	all, err := s.ListPlanPrices()
	if err != nil || len(all) != 1 || all[0].MonthlyCost != 210 {
		t.Fatalf("correction should replace the figure in place: %+v err=%v", all, err)
	}

	if err := s.SetPlanPrice(price("max", 250, day(2026, 7, 1))); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPlanPrice(price("max", 220, day(2026, 4, 1))); err == nil {
		t.Fatal("inserting a price behind an existing one was accepted; periods now overlap")
	}
}

func TestSetPlanPriceRejectsUndatedAndNegative(t *testing.T) {
	s := newStore(t)
	if err := s.SetPlanPrice(model.SubscriptionPlan{Plan: "max", MonthlyCost: 200}); err == nil {
		t.Error("an undated price was accepted; it cannot be applied to any period")
	}
	if err := s.SetPlanPrice(price("max", -1, day(2026, 1, 1))); err == nil {
		t.Error("a negative monthly cost was accepted")
	}
	if err := s.SetPlanPrice(price("", 200, day(2026, 1, 1))); err == nil {
		t.Error("a price with no plan name was accepted")
	}
}

// Seats are counted from the accounts on the plan, never stored — a stored
// count drifts the moment somebody is added and still looks authoritative.
func TestSubscriptionSpendDerivesSeatsFromAccounts(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	seedAccount(t, s, "acct-b", "ep-2")
	if err := s.SetPlanPrice(price("max", 200, day(2020, 1, 1))); err != nil {
		t.Fatal(err)
	}

	end := time.Now().UTC()
	rows, err := s.SubscriptionSpendOver(AllAccounts, end.Add(-averageMonth), end)
	if err != nil || len(rows) != 1 {
		t.Fatalf("spend=%+v err=%v", rows, err)
	}
	got := rows[0]
	if !got.Priced || got.Seats != 2 || got.Currency != DefaultCurrency {
		t.Fatalf("row=%+v, want 2 priced seats in %s", got, DefaultCurrency)
	}
	// Two seats, one month, 200/month.
	if math.Abs(got.Amount-400) > 0.01 || math.Abs(got.Months-1) > 0.001 {
		t.Errorf("spend=%.4f over %.4f months, want 400.00 over 1", got.Amount, got.Months)
	}
}

// A reporting period that straddles a price change is charged partly at each
// price, not wholly at either.
func TestSubscriptionSpendSplitsAcrossAPriceChange(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	start, change, end := day(2026, 1, 1), day(2026, 2, 1), day(2026, 3, 1)
	if err := s.SetPlanPrice(price("max", 100, start)); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPlanPrice(price("max", 300, change)); err != nil {
		t.Fatal(err)
	}
	// The account must overlap the reporting period to count as a seat.
	if _, err := s.write.Exec(`UPDATE accounts SET first_seen = ?, last_seen = ?`,
		fmtTime(start), fmtTime(end)); err != nil {
		t.Fatal(err)
	}

	rows, err := s.SubscriptionSpendOver(AllAccounts, start, end)
	if err != nil || len(rows) != 1 {
		t.Fatalf("spend=%+v err=%v", rows, err)
	}
	janMonths := change.Sub(start).Seconds() / averageMonth.Seconds()
	febMonths := end.Sub(change).Seconds() / averageMonth.Seconds()
	want := 100*janMonths + 300*febMonths
	if math.Abs(rows[0].Amount-want) > 0.01 {
		t.Errorf("spend=%.4f, want %.4f (%.4f months at 100 + %.4f at 300)",
			rows[0].Amount, want, janMonths, febMonths)
	}
	// Charged wholly at one price would give these; neither is acceptable.
	for _, wrong := range []float64{100 * (janMonths + febMonths), 300 * (janMonths + febMonths)} {
		if math.Abs(rows[0].Amount-wrong) < 0.01 {
			t.Errorf("whole period charged at one price (%.4f)", wrong)
		}
	}
}

// An unpriced plan is REPORTED as unpriced, not dropped. Dropping it returns a
// total that is wrong in the one direction nobody checks — too low — with
// nothing on screen to say so.
func TestSubscriptionSpendReportsUnpricedPlansRatherThanOmittingThem(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	end := time.Now().UTC()
	rows, err := s.SubscriptionSpendOver(AllAccounts, end.Add(-averageMonth), end)
	if err != nil || len(rows) != 1 {
		t.Fatalf("spend=%+v err=%v", rows, err)
	}
	if rows[0].Priced {
		t.Fatalf("plan with no recorded price reported as priced: %+v", rows[0])
	}
	if rows[0].Amount != 0 || rows[0].Seats != 1 {
		t.Errorf("unpriced row should carry seats but no amount: %+v", rows[0])
	}
}

func TestSubscriptionSpendRejectsAnEmptyPeriod(t *testing.T) {
	s := newStore(t)
	at := day(2026, 1, 1)
	if _, err := s.SubscriptionSpendOver(AllAccounts, at, at); err == nil {
		t.Error("a zero-length period was accepted")
	}
}

// THE GUARD (issues #2, #3). Subscription spend is real, billed money;
// cost_usd is notional — "what this would have cost at API rates" — and is
// explicitly not an invoice. Adding them produces a number that means nothing,
// and the failure is silent: it returns a plausible figure. So recording a
// subscription price must leave every notional aggregate byte-for-byte
// unchanged, and the two must never be reachable through one call.
func TestSubscriptionSpendNeverEntersTheNotionalCostTotal(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		ev("acct-a", "ep-1", "u1", 10), ev("acct-a", "ep-1", "u2", 20),
	}); err != nil {
		t.Fatal(err)
	}

	base := ev("acct-a", "ep-1", "u1", 10).TS
	f := Filter{Account: "acct-a", Start: base.Add(-time.Hour), End: base.Add(time.Hour)}
	before, err := s.Summary(f)
	if err != nil {
		t.Fatal(err)
	}
	if before.Cost.Notional() == 0 {
		t.Fatal("fixture produced no notional cost; the guard would pass vacuously")
	}

	// A large, unmistakable subscription price: if it ever leaked into a
	// notional aggregate it could not be mistaken for rounding.
	if err := s.SetPlanPrice(price("max", 99999, day(2020, 1, 1))); err != nil {
		t.Fatal(err)
	}

	after, err := s.Summary(f)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(after, before) {
		t.Errorf("recording a subscription price changed the notional summary:\n before=%+v\n  after=%+v", before, after)
	}

	for _, dim := range []Dimension{BySource, ByModel, ByEndpoint} {
		rows, err := s.UsageByFiltered(f, dim, 10)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range rows {
			if r.Cost.Notional() >= 99999 || r.Cost.Billed() >= 99999 {
				t.Errorf("subscription spend leaked into the notional %v breakdown: %+v", dim, r)
			}
		}
	}

	// And the real figure is still available — separately, by its own call.
	// Over the period the account has actually been seen in: a subscription is
	// billed for the months it exists, which is not the window its stored
	// turns happen to fall in.
	now := time.Now().UTC()
	spend, err := s.SubscriptionSpendOver(AllAccounts, now.Add(-averageMonth), now)
	if err != nil || len(spend) != 1 || !spend[0].Priced {
		t.Fatalf("real subscription spend unavailable: %+v err=%v", spend, err)
	}
	if spend[0].Amount < 99999 {
		t.Errorf("real spend=%v, want at least one month at 99999", spend[0].Amount)
	}
}
