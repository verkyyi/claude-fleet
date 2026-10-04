package pricing

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func writeOverrides(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pricing.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadPlanPrices(t *testing.T) {
	path := writeOverrides(t, `{
	  "plans": [
	    {"plan": "max", "source": "claude", "monthly_cost": 200, "currency": "USD",
	     "effective_from": "2026-01-01T00:00:00Z"},
	    {"plan": "plus", "monthly_cost": 20, "effective_from": "2026-02-01T00:00:00Z"}
	  ]
	}`)
	plans, err := LoadPlanPrices(path)
	if err != nil || len(plans) != 2 {
		t.Fatalf("plans=%+v err=%v", plans, err)
	}
	if plans[0].Plan != "max" || plans[0].MonthlyCost != 200 || plans[0].Currency != "USD" {
		t.Errorf("max=%+v", plans[0])
	}
	if !plans[0].EffectiveFrom.Equal(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("effective_from=%v", plans[0].EffectiveFrom)
	}
	// An omitted source is Claude, matching every other source-bearing row.
	if plans[1].Source != model.SourceClaude {
		t.Errorf("plus source=%q, want %q", plans[1].Source, model.SourceClaude)
	}
}

// Overrides are optional, same as the per-token ones: a hub that has not
// priced its plans must still start, and report them as unpriced.
func TestLoadPlanPricesMissingFileIsNotAnError(t *testing.T) {
	plans, err := LoadPlanPrices(filepath.Join(t.TempDir(), "absent.json"))
	if err != nil || plans != nil {
		t.Fatalf("plans=%+v err=%v", plans, err)
	}
}

// An undated price cannot be applied to any reporting period, and a price
// silently dropped is a total that is quietly too low. Refuse loudly instead.
func TestLoadPlanPricesRejectsIncompleteRows(t *testing.T) {
	for name, body := range map[string]string{
		"no effective_from": `{"plans":[{"plan":"max","monthly_cost":200}]}`,
		"no plan name":      `{"plans":[{"monthly_cost":200,"effective_from":"2026-01-01T00:00:00Z"}]}`,
		"unparseable date":  `{"plans":[{"plan":"max","monthly_cost":200,"effective_from":"January 2026"}]}`,
	} {
		if _, err := LoadPlanPrices(writeOverrides(t, body)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// The two kinds of money stay apart in the type system. A file carrying only
// plan prices must leave the notional rate table untouched, and a file
// carrying only model rates must yield no plans: nothing in either path can
// turn one into the other.
func TestPlanPricesAndTokenRatesDoNotCross(t *testing.T) {
	plansOnly := writeOverrides(t, `{"plans":[{"plan":"max","monthly_cost":200,"effective_from":"2026-01-01T00:00:00Z"}]}`)
	table := Default()
	before := table.rates["claude-opus-5"]
	if err := table.LoadOverrides(plansOnly); err != nil {
		t.Fatal(err)
	}
	if table.rates["claude-opus-5"] != before {
		t.Errorf("a subscription price changed a token rate: %+v -> %+v", before, table.rates["claude-opus-5"])
	}
	if len(table.rates) != len(Default().rates) {
		t.Errorf("a subscription price was added to the rate table: %d keys, want %d",
			len(table.rates), len(Default().rates))
	}

	ratesOnly := writeOverrides(t, `{"models":{"claude-opus-5":{"input":9,"output":90}}}`)
	plans, err := LoadPlanPrices(ratesOnly)
	if err != nil || len(plans) != 0 {
		t.Errorf("token rates surfaced as subscription plans: %+v err=%v", plans, err)
	}
}
