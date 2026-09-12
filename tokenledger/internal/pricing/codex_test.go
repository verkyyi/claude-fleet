package pricing

import (
	"github.com/verkyyi/ccquota/internal/model"
	"math"
	"strings"
	"testing"
)

func TestCodexPriceCacheSubsetsAndTiers(t *testing.T) {
	write := int64(20000)
	e := model.UsageEvent{Source: "codex", Model: "gpt-6-astra", InputTokens: 100000, CacheRead: 100000, OutputTokens: 10000, Thinking: 9000, Details: &model.UsageDetails{Provider: "openai", CacheWrite: &write}}
	check := func(want float64) {
		t.Helper()
		v := Default().Cost(&e)
		if v == nil || math.Abs(*v-want) > 1e-8 {
			t.Fatalf("price=%v want=%v basis=%s", v, want, e.Details.PriceBasis)
		}
	}
	check(1.65) // 80K new + 20K writes + 100K cached + 10K output
	if e.TotalTokens() != 210000 {
		t.Fatal("write/reasoning subsets were added twice")
	}
	e.Details.ServiceTier = "priority"
	check(3.3)
	e.Details.ServiceTier = "flex"
	check(.825)
	e.Details.ServiceTier = "standard"
	e.CacheRead = 200000
	check(3.25)
	e.Details.CacheWrite = nil
	if Default().Cost(&e) != nil {
		t.Fatal("missing writes priced as zero")
	}
	e.Details.CacheWrite = &write
	e.Details.Provider = "bedrock"
	if Default().Cost(&e) != nil {
		t.Fatal("third-party provider given OpenAI pricing")
	}
	e.Details.Provider = "openai"
	e.Details.ServiceTier = "unknown"
	if Default().Cost(&e) != nil {
		t.Fatal("unknown tier priced")
	}
	if !strings.Contains(e.Details.PriceBasis, "unpriced") {
		t.Fatal("missing price explanation")
	}
}
