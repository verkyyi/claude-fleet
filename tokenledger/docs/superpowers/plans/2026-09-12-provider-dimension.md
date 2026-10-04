# Subproject A — Provider Dimension and Gateway Pricing Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Price every gateway call on the contract that actually served it — `(provider, model)` rather than `model` alone — and make `provider` a groupable, filterable dimension backfilled from data the hub already stores.

**Architecture:** The reporting side already sends the upstream that served each call, as `details.model_provider`, and `store.go:489` already persists `details_json` for every source. So this promotes an existing JSON field to a real column, backfills history from that JSON, threads it through the hourly rollup (which needs a PRIMARY KEY rebuild, following the `migrateSources` precedent), adds it as a `store.Dimension`, and re-keys the gateway rate table on `(provider, model)`. **No ingest contract change and no cross-repo coordination.**

**Tech Stack:** Go 1.25, `modernc.org/sqlite` (JSON1 available — `json_extract` is already used at `internal/store/pricing_coverage.go:38`), standard `testing`.

**Spec:** `docs/superpowers/specs/2026-09-12-tokenledger-provider-and-reorientation-design.md`

## Global Constraints

- **Never sum two kinds of money.** `provider` is a grouping axis *within* the billed kind, never a fourth `CostKind`. `store.CostBySource` gains no `Total()`.
- **Zero is a claim; nil/absent is an admission.** An unpriced event keeps `cost_usd = NULL`, never `0`.
- **Empty provider means "not declared".** Never rendered as a vendor named `unknown`, never merged into a neighbouring bucket.
- **The hub does not map hostnames to vendor slugs.** Provider is stored verbatim as received. A display label comes only from `--pricing`; the hub guesses nothing.
- **Every rate is dated.** An undated rate or FX conversion is rejected at load — existing rule, extended to the new nested block.
- **Identifiers stay `ccquota`** (command, module path, DB path, env vars) per #7. Only user-facing copy says TokenLedger.
- **Migrations are additive and preserve pruned-raw rollup history.** Never reconstruct `usage_hourly` from `usage_events`.
- Run `gofmt -w` on every touched Go file before committing. Full check: `go test ./...`

---

### Task 1: `provider` on the event and on `usage_events`

**Files:**
- Modify: `internal/model/model.go` (add field to `UsageEvent`, after `Model`)
- Modify: `internal/store/store.go` (`migrate()` adds list; the insert statement; the per-event normalization loop)
- Modify: `internal/store/details.go` (backfill in `migrateDetails`)
- Test: `internal/store/sources_test.go` (new tests appended)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `model.UsageEvent.Provider string` — JSON tag `provider,omitempty`.
  - `usage_events.provider TEXT NOT NULL DEFAULT ''`, populated for new rows and backfilled for old ones.
  - Normalization rule, relied on by Task 2: at insert, `e.Provider` falls back to `e.Details.Provider` when empty.

- [ ] **Step 1: Write the failing test**

Append to `internal/store/sources_test.go`:

```go
func TestInsert_ProviderComesFromDetailsWhenUnset(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "u-gw-1", 10)
	e.Source = model.SourceGateway
	e.Model = "qwen-plus"
	e.Details = &model.UsageDetails{Provider: "dashscope.aliyuncs.com"}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	var got string
	if err := s.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-gw-1").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "dashscope.aliyuncs.com" {
		t.Errorf("provider = %q, want dashscope.aliyuncs.com", got)
	}
}

func TestInsert_ExplicitProviderWins(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "u-gw-2", 10)
	e.Source = model.SourceGateway
	e.Provider = "explicit.example"
	e.Details = &model.UsageDetails{Provider: "details.example"}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	var got string
	if err := s.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-gw-2").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "explicit.example" {
		t.Errorf("provider = %q, want explicit.example", got)
	}
}

// Absent is absent. A claude event declares no provider and must not acquire
// an invented one.
func TestInsert_NoProviderStaysEmpty(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	if _, _, err := s.InsertEvents(ident("acct"), "ep1",
		[]model.UsageEvent{ev("acct", "ep1", "u-cc-1", 10)}); err != nil {
		t.Fatal(err)
	}

	var got string
	if err := s.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-cc-1").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Errorf("provider = %q, want empty", got)
	}
}
```

If `store.DB()` does not exist, add it to `internal/store/store.go` next to `Close`:

```go
// DB exposes the handle for tests and migrations that need raw SQL.
func (s *Store) DB() *sql.DB { return s.db }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/store/ -run 'TestInsert_.*Provider|TestInsert_NoProvider' -v`
Expected: FAIL — `e.Provider` undefined, and `no such column: provider`.

- [ ] **Step 3: Add the field**

In `internal/model/model.go`, inside `UsageEvent`, immediately after the `Model` field:

```go
	Model       string    `json:"model"`

	// Provider is the upstream that actually served this request.
	//
	// It is a separate fact from Model and from Source. A gateway with
	// failover reaches the same model id through more than one upstream at
	// more than one contracted price, so the model id alone cannot identify
	// the contract — see internal/pricing/gateway.go. Senders may set it
	// directly; the hub also reads it from Details.Provider, which is what
	// the existing gateway shipper sends.
	//
	// Empty means NOT DECLARED, which is the honest state for a Claude
	// transcript. It is never filled in by inference.
	Provider string `json:"provider,omitempty"`
```

- [ ] **Step 4: Add the column and the insert wiring**

In `internal/store/store.go`, append to the `adds` slice in `migrate()`:

```go
		{"usage_events", "provider", "TEXT NOT NULL DEFAULT ''"},
```

In the same file's insert statement, add `provider` to the column list and one more `?`:

```go
	stmt, err := tx.Prepare(`
		INSERT OR IGNORE INTO usage_events (
		  account_uuid, endpoint_id, session_id, message_uuid, request_id, ts, model,
		  input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
		  cache_read_tokens, thinking_tokens, web_search_requests, web_fetch_requests,
		  cost_usd, cwd, os_user, git_branch, entrypoint, effort, is_sidechain, source,details_json,cache_write_tokens,cache_write_known_events,provider
		) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
```

Add the bind argument in the same position as the column (last) wherever `stmt.Exec(...)` is called for this statement.

In the per-event loop, beside the existing source normalization:

```go
		e.Source = model.UsageSource(e.Source)
		// The shipper sends the upstream inside details; a sender that sets
		// the field directly wins. Neither is inferred when both are absent.
		if e.Provider == "" && e.Details != nil {
			e.Provider = e.Details.Provider
		}
```

Also add `provider TEXT NOT NULL DEFAULT ''` to the `usage_events` definition in `internal/store/schema.sql`, after the `model` column, so fresh databases match migrated ones.

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/store/ -run 'TestInsert_.*Provider|TestInsert_NoProvider' -v`
Expected: PASS (3 tests)

- [ ] **Step 6: Write the backfill test**

Append to `internal/store/sources_test.go`:

```go
// History is already in the database, inside details_json. The migration must
// lift it out rather than starting the dimension from today.
func TestMigrate_BackfillsProviderFromDetails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backfill.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "u-old", 10)
	e.Source = model.SourceGateway
	e.Details = &model.UsageDetails{Provider: "ark.cn-beijing.volces.com"}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	// Simulate a row written before the column existed.
	if _, err := s.DB().Exec(`UPDATE usage_events SET provider = '' WHERE message_uuid = ?`, "u-old"); err != nil {
		t.Fatal(err)
	}
	s.Close()

	s2, err := Open(path) // reopening runs migrate()
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	var got string
	if err := s2.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-old").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "ark.cn-beijing.volces.com" {
		t.Errorf("backfilled provider = %q, want ark.cn-beijing.volces.com", got)
	}
}
```

Add `"path/filepath"` to that file's imports if absent.

- [ ] **Step 7: Run test to verify it fails**

Run: `go test ./internal/store/ -run TestMigrate_BackfillsProviderFromDetails -v`
Expected: FAIL — `backfilled provider = "", want ark.cn-beijing.volces.com`

- [ ] **Step 8: Implement the backfill**

In `internal/store/details.go`, at the end of `migrateDetails` before `return nil`:

```go
	// Lift the provider out of details_json for rows written before the
	// column existed. The value has been arriving since the gateway shipper's
	// first run; it was simply not groupable. Idempotent, and it never
	// overwrites a provider a sender stated directly.
	if _, err := db.Exec(`UPDATE usage_events
		   SET provider = json_extract(details_json, '$.model_provider')
		 WHERE provider = ''
		   AND json_extract(details_json, '$.model_provider') IS NOT NULL`); err != nil {
		return fmt.Errorf("backfill usage_events.provider: %w", err)
	}
```

`migrateDetails` runs after `migrate()` (see `store.go:99-102`), so the column exists by then.

- [ ] **Step 9: Run tests to verify they pass**

Run: `go test ./internal/store/ -v -run 'Provider'`
Expected: PASS. Then `go test ./internal/store/` — full package green.

- [ ] **Step 10: Commit**

```bash
gofmt -w internal/model/model.go internal/store/store.go internal/store/details.go internal/store/sources_test.go
git add internal/model/model.go internal/store/store.go internal/store/details.go internal/store/schema.sql internal/store/sources_test.go
git commit -m "$(cat <<'EOF'
feat(model,store): provider 成为事件上的一等字段 —— 从 details_json 里回填，不用改 ingest 契约

网关早就在送 details.model_provider（upstream 主机名），store 的 INSERT 也一直在写
details_json —— 数据在库里，只是埋在 JSON 里 group 不了。这一步把它提成列并回填历史。

空字符串是「未申报」，不是一个叫 unknown 的厂商：claude 的 transcript 本来就不声明
provider，给它编一个会让后面每一张按厂商分的表都多出一行假数据。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Price a gateway call on `(provider, model)`

**Files:**
- Modify: `internal/pricing/gateway.go`
- Modify: `internal/pricing/pricing.go` (`Cost` passes the event through unchanged; only `gatewayCost` changes — verify no other caller assumes a flat key)
- Test: `internal/pricing/gateway_test.go`

**Interfaces:**
- Consumes: `model.UsageEvent.Provider` (Task 1).
- Produces:
  - `gatewayPricing.byProvider map[string]map[string]Rates` — provider → normalized model → rates.
  - `gatewayOverride.Providers map[string]providerOverride` with `providerOverride{Label string; Models map[string]Rates}`.
  - `price_basis` naming the provider when a provider-specific rate was used. Task 5 surfaces it.

This is the defect the subproject exists for; it ships before the dimension is queryable so the numbers are right as early as possible.

- [ ] **Step 1: Write the failing test**

Append to `internal/pricing/gateway_test.go`:

```go
// The same model id served by two upstreams at two contracted prices. This is
// what the deployment's alias chains actually do on failover, and pricing both
// at one rate puts a wrong number in the one column that claims to be an
// invoice.
const twoProviderFile = `{
  "gateway": {
    "rates_as_of": "2026-09-12",
    "cny_per_usd": 7.0,
    "cny_per_usd_as_of": "2026-09-12",
    "providers": {
      "dashscope.aliyuncs.com":    {"label": "阿里云百炼",
        "models": {"deepseek-v4-flash": {"input": 10.0, "output": 10.0}}},
      "ark.cn-beijing.volces.com": {"label": "火山方舟",
        "models": {"deepseek-v4-flash": {"input": 20.0, "output": 20.0}}}
    }
  }
}`

func gwEvent(provider string) *model.UsageEvent {
	return &model.UsageEvent{
		Source: model.SourceGateway, Model: "deepseek-v4-flash", Provider: provider,
		InputTokens: 1_000_000, OutputTokens: 0,
		Details: &model.UsageDetails{Provider: provider},
	}
}

func TestGatewayCost_SameModelTwoProvidersTwoPrices(t *testing.T) {
	tbl := gatewayTable(t, twoProviderFile)

	cheap := tbl.Cost(gwEvent("dashscope.aliyuncs.com"))
	dear := tbl.Cost(gwEvent("ark.cn-beijing.volces.com"))
	if cheap == nil || dear == nil {
		t.Fatalf("both should price: cheap=%v dear=%v", cheap, dear)
	}
	if math.Abs(*cheap-10.0/7.0) > 1e-9 {
		t.Errorf("dashscope = %v, want %v", *cheap, 10.0/7.0)
	}
	if math.Abs(*dear-20.0/7.0) > 1e-9 {
		t.Errorf("ark = %v, want %v", *dear, 20.0/7.0)
	}
	if *cheap == *dear {
		t.Error("two providers priced identically — the flat key bug is still here")
	}
}

func TestGatewayCost_BasisNamesTheProvider(t *testing.T) {
	tbl := gatewayTable(t, twoProviderFile)
	e := gwEvent("ark.cn-beijing.volces.com")
	tbl.Cost(e)
	if !strings.Contains(e.Details.PriceBasis, "ark.cn-beijing.volces.com") {
		t.Errorf("price basis %q does not name the provider it priced on", e.Details.PriceBasis)
	}
}

// A flat entry means "this price holds whoever serves it" — a legitimate thing
// to say, and the fallback when a provider declares no rate for the model.
func TestGatewayCost_FlatTableAppliesWhenProviderDeclaresNothing(t *testing.T) {
	tbl := gatewayTable(t, `{
	  "gateway": {
	    "rates_as_of": "2026-09-12", "cny_per_usd": 7.0, "cny_per_usd_as_of": "2026-09-12",
	    "models": {"deepseek-v4-flash": {"input": 7.0, "output": 7.0}},
	    "providers": {"ark.cn-beijing.volces.com": {"models": {"qwen-plus": {"input": 1.0, "output": 1.0}}}}
	  }
	}`)
	// ark declares a rate for qwen-plus but not for deepseek-v4-flash, so the
	// flat entry answers.
	got := tbl.Cost(gwEvent("ark.cn-beijing.volces.com"))
	if got == nil {
		t.Fatal("should fall back to the flat table")
	}
	if math.Abs(*got-1.0) > 1e-9 {
		t.Errorf("= %v, want 1.0", *got)
	}
}

// A provider block is authoritative for the models it names: the flat table
// must not silently answer for a contract that stated its own price.
func TestGatewayCost_ProviderBlockBeatsFlatTable(t *testing.T) {
	tbl := gatewayTable(t, `{
	  "gateway": {
	    "rates_as_of": "2026-09-12", "cny_per_usd": 7.0, "cny_per_usd_as_of": "2026-09-12",
	    "models": {"deepseek-v4-flash": {"input": 7.0, "output": 7.0}},
	    "providers": {"ark.cn-beijing.volces.com": {"models": {"deepseek-v4-flash": {"input": 70.0, "output": 70.0}}}}
	  }
	}`)
	got := tbl.Cost(gwEvent("ark.cn-beijing.volces.com"))
	if got == nil || math.Abs(*got-10.0) > 1e-9 {
		t.Errorf("= %v, want 10.0 (the provider's own rate)", got)
	}
}

func TestGatewayCost_UnpricedBasisNamesTheMissingKey(t *testing.T) {
	tbl := gatewayTable(t, twoProviderFile)
	e := gwEvent("openrouter.ai")
	if got := tbl.Cost(e); got != nil {
		t.Fatalf("= %v, want nil for an unconfigured provider", *got)
	}
	if !strings.Contains(e.Details.PriceBasis, "openrouter.ai") {
		t.Errorf("basis %q should name the provider whose rate is missing", e.Details.PriceBasis)
	}
}

func TestGatewayOverride_ProviderRateNeedsRatesAsOf(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pricing.json")
	if err := os.WriteFile(p, []byte(`{"gateway":{"providers":{"a":{"models":{"m":{"input":1,"output":1}}}}}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Default().LoadOverrides(p); err == nil {
		t.Error("an undated provider rate must be rejected")
	}
}

func TestGatewayOverride_BadProviderRateRejectsWholeFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pricing.json")
	if err := os.WriteFile(p, []byte(`{
	  "models": {"claude-opus-5": {"input": 1, "output": 1}},
	  "gateway": {"rates_as_of":"2026-09-12",
	    "providers": {"a": {"models": {"m": {"input": 0, "output": 1}}}}}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}
	tbl := Default()
	if err := tbl.LoadOverrides(p); err == nil {
		t.Fatal("a zero rate must be rejected")
	}
	// And nothing may have been applied.
	e := &model.UsageEvent{Model: "claude-opus-5", InputTokens: 1_000_000}
	if c := tbl.Cost(e); c == nil || math.Abs(*c-5.0) > 1e-9 {
		t.Errorf("built-in rate was disturbed by a rejected file: %v", c)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pricing/ -run TestGateway -v`
Expected: FAIL — `Providers` is not a field of `gatewayOverride`; `SameModelTwoProviders` reports identical prices.

- [ ] **Step 3: Implement the nested rate table**

In `internal/pricing/gateway.go`, replace the `gatewayPricing` struct, `defaultGateway`, `gatewayOverride`, `validate`, `merge`, and `gatewayCost` with:

```go
// providerOverride is one upstream's contract: the rates it charges, and an
// optional human label for display. Label never affects a rate.
type providerOverride struct {
	Label  string           `json:"label"`
	Models map[string]Rates `json:"models"`
}

type gatewayPricing struct {
	rates map[string]Rates // flat: "this price holds whoever serves it"
	// byProvider is provider -> normalized model -> rates. A provider block is
	// authoritative for the models it names; the flat table answers only what
	// the provider left unsaid.
	byProvider map[string]map[string]Rates
	labels     map[string]string
	ratesAsOf  string
	cnyPerUSD  float64
	fxAsOf     string
	source     string
}

func defaultGateway() gatewayPricing {
	r := make(map[string]Rates, len(gatewayRates))
	for id, v := range gatewayRates {
		r[id] = v
	}
	return gatewayPricing{
		rates:      r,
		byProvider: map[string]map[string]Rates{},
		labels:     map[string]string{},
		ratesAsOf:  GatewayRatesAsOf,
		cnyPerUSD:  GatewayCNYPerUSD,
		fxAsOf:     GatewayFXAsOf,
		source:     GatewayPriceSource,
	}
}

type gatewayOverride struct {
	Models      map[string]Rates            `json:"models"`
	Providers   map[string]providerOverride `json:"providers"`
	RatesAsOf   string                      `json:"rates_as_of"`
	CNYPerUSD   *float64                    `json:"cny_per_usd"`
	CNYAsOf     string                      `json:"cny_per_usd_as_of"`
	PriceSource string                      `json:"price_source"`
}

func (o *gatewayOverride) validate(path string) error {
	anyRate := len(o.Models) > 0
	for _, p := range o.Providers {
		if len(p.Models) > 0 {
			anyRate = true
		}
	}
	if anyRate && o.RatesAsOf == "" {
		return fmt.Errorf(`pricing overrides %s: gateway rates need "rates_as_of" — an undated rate cannot be disclosed in a price basis`, path)
	}
	if err := validateGatewayRates(path, "", o.Models); err != nil {
		return err
	}
	for name, p := range o.Providers {
		if name == "" {
			return fmt.Errorf(`pricing overrides %s: gateway.providers has an empty key — the empty provider means "not declared" and cannot carry a contract`, path)
		}
		if err := validateGatewayRates(path, name, p.Models); err != nil {
			return err
		}
	}
	if o.CNYPerUSD != nil {
		if *o.CNYPerUSD <= 0 {
			return fmt.Errorf("pricing overrides %s: gateway.cny_per_usd must be positive", path)
		}
		if o.CNYAsOf == "" {
			return fmt.Errorf(`pricing overrides %s: gateway.cny_per_usd needs "cny_per_usd_as_of" — a conversion is only honest with the date it was set`, path)
		}
	}
	return nil
}

func validateGatewayRates(path, provider string, models map[string]Rates) error {
	where := "gateway model %q"
	if provider != "" {
		where = "gateway provider " + provider + " model %q"
	}
	for id, r := range models {
		// Zero is not a discount. A gateway call is never free, and a rate
		// left at zero would understate a real bill in silence.
		if r.Input <= 0 || r.Output <= 0 {
			return fmt.Errorf("pricing overrides %s: "+where+" needs positive input and output rates in CNY per million tokens", path, id)
		}
		if r.CacheWrite5m != 0 || r.CacheWrite1h != 0 || r.CacheRead != 0 {
			return fmt.Errorf("pricing overrides %s: "+where+" sets a cache rate, but this source reports no cache tokens", path, id)
		}
	}
	return nil
}

func (g *gatewayPricing) merge(o *gatewayOverride) {
	for id, r := range o.Models {
		g.rates[Normalize(id)] = Rates{Input: r.Input, Output: r.Output}
	}
	for name, p := range o.Providers {
		if p.Label != "" {
			g.labels[name] = p.Label
		}
		if len(p.Models) == 0 {
			continue
		}
		at := g.byProvider[name]
		if at == nil {
			at = map[string]Rates{}
			g.byProvider[name] = at
		}
		for id, r := range p.Models {
			at[Normalize(id)] = Rates{Input: r.Input, Output: r.Output}
		}
	}
	if o.RatesAsOf != "" {
		g.ratesAsOf = o.RatesAsOf
	}
	if o.CNYPerUSD != nil {
		g.cnyPerUSD = *o.CNYPerUSD
		g.fxAsOf = o.CNYAsOf
	}
	if o.PriceSource != "" {
		g.source = o.PriceSource
	}
}

// rateFor finds the contract that served this call.
//
// A provider block is authoritative for the models it names, so the flat table
// is consulted only when the provider stated no rate for this model. Returning
// the provider that supplied the rate ("" for the flat table) is what lets the
// price basis disclose which contract produced the figure.
func (g *gatewayPricing) rateFor(provider, modelID string) (Rates, string, bool) {
	id := Normalize(modelID)
	if m, ok := g.byProvider[provider]; ok {
		if r, ok := m[id]; ok {
			return r, provider, true
		}
	}
	if r, ok := g.rates[id]; ok {
		return r, "", true
	}
	return Rates{}, "", false
}

// GatewayProviderLabel is the operator-supplied display name for an upstream,
// or "" when none was stated. The hub never invents one: a hostname it cannot
// name is shown as the hostname.
func (t *Table) GatewayProviderLabel(provider string) string { return t.gw.labels[provider] }

// gatewayCost prices one pay-per-call gateway event on the contract that
// actually served it, converting the vendor's CNY rate to USD at the pinned
// constant and disclosing both the conversion and the contract.
func (t *Table) gatewayCost(e *model.UsageEvent) *float64 {
	d := e.Details
	if d == nil {
		// Nowhere to stamp the basis. A converted figure presented without
		// its conversion is exactly what this design refuses, so the event
		// stays unpriced rather than arriving as a bare number.
		return nil
	}
	g := &t.gw
	d.PriceVersion = "gateway-" + g.ratesAsOf
	d.PriceSource = g.source

	provider := e.Provider
	if provider == "" {
		provider = d.Provider
	}

	r, pricedBy, ok := g.rateFor(provider, e.Model)
	if !ok {
		// Name the provider, not just the model: with failover across
		// upstreams "which contract is missing a rate" is the actionable half.
		switch provider {
		case "":
			d.PriceBasis = "unpriced: no gateway rate configured for this model, and the call declared no provider"
		default:
			d.PriceBasis = fmt.Sprintf("unpriced: no gateway rate configured for provider %s, model %s", provider, e.Model)
		}
		return nil
	}
	if e.InputTokens < 0 || e.OutputTokens < 0 {
		d.PriceBasis = "unpriced: implausible token counts"
		return nil
	}
	// The source reports no cache breakdown, so the three cache columns are
	// legitimately 0 and the configured rates cover input and output only. A
	// non-zero count here means the adapter grew a breakdown the rates do not
	// price: cheaper to admit than to undercount a real invoice.
	if e.CacheCreate5m != 0 || e.CacheCreate1h != 0 || e.CacheRead != 0 {
		d.PriceBasis = "unpriced: gateway rates cover input and output only"
		return nil
	}
	if g.cnyPerUSD <= 0 {
		d.PriceBasis = "unpriced: no usable CNY/USD rate"
		return nil
	}

	const perMillion = 1_000_000.0
	cny := float64(e.InputTokens)/perMillion*r.Input + float64(e.OutputTokens)/perMillion*r.Output
	usd := cny / g.cnyPerUSD
	contract := "any provider"
	if pricedBy != "" {
		contract = "provider " + pricedBy
	}
	d.PriceBasis = fmt.Sprintf("billed: %s, CNY %g in / %g out per MTok as of %s, converted at %.4f CNY/USD pinned %s",
		contract, r.Input, r.Output, g.ratesAsOf, g.cnyPerUSD, g.fxAsOf)
	return &usd
}
```

Update the doc comment on `gatewayRates` to say the flat map now means "any provider", and that per-contract rates live in `providers`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/pricing/ -v`
Expected: PASS, including the pre-existing gateway tests (the flat `models` form still works unchanged).

- [ ] **Step 5: Update the overrides documentation**

In `README.md`, in the gateway pricing section (around line 780), replace the example block with:

````markdown
```json
{
  "gateway": {
    "rates_as_of": "2026-09-12",
    "cny_per_usd": 7.09,
    "cny_per_usd_as_of": "2026-09-12",
    "price_source": "https://internal.example/gateway/pricing",
    "models": { "vendor-large": { "input": 7.0, "output": 70.0 } },
    "providers": {
      "dashscope.aliyuncs.com": {
        "label": "阿里云百炼",
        "models": { "qwen-plus": { "input": 0.8, "output": 2.0 } }
      },
      "ark.cn-beijing.volces.com": {
        "label": "火山方舟",
        "models": { "deepseek-v4-flash": { "input": 0.5, "output": 1.5 } }
      }
    }
  }
}
```

A gateway that fans out to several upstreams reaches the same model id at more
than one contracted price, and failover decides which one served any given
call — so a rate keyed on the model alone prices some calls at another
vendor's number. State each contract under `providers`, keyed by the provider
string the reporting side sends (this deployment sends the upstream hostname).

`models` at the top level still means **this price holds whoever serves it**,
and answers only what a provider left unsaid: a provider block is
authoritative for the models it names. `label` is display only. Every priced
event's `price_basis` names the contract it used.
````

- [ ] **Step 6: Commit**

```bash
gofmt -w internal/pricing/gateway.go internal/pricing/gateway_test.go
go test ./... >/dev/null && echo OK
git add internal/pricing/gateway.go internal/pricing/gateway_test.go README.md
git commit -m "$(cat <<'EOF'
fix(pricing): 网关按 (供应商, 模型) 计价 —— 同一模型两家上游两个价，此前共用一个费率

gatewayCost 一直按 Normalize(e.Model) 单键查表，而网关自己的 catalog.json 用的是
vendor/model，别名链还会跨厂商 fallback：chat-fast 可能落在 dashscope / deepseek / ark
三家中任意一家，取决于当时谁没挂。一个裸模型名因此对应多份合同、多个价。

这一列不是可以将就的那种数字 —— gateway 的 cost_usd 是 billed，本仓唯一断言「这就是
发票」的一列。--pricing 的扁平 models 也表达不了两家不同价。

providers 块按合同报价，对它写明的模型有最终解释权；顶层 models 保留，含义是「不论谁
服务都是这个价」，只回答 provider 没说的那部分。price_basis 里写明这笔钱按哪份合同算的。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `provider` in the hourly rollup

**Files:**
- Modify: `internal/store/schema.sql` (`usage_hourly` definition and PRIMARY KEY)
- Modify: `internal/store/rollup.go` (`rollupInsertSQL`, `rollupUpsert`)
- Create: `internal/store/provider_migration.go`
- Modify: `internal/store/store.go` (call the new migration)
- Modify: `internal/store/details.go` (`enrichCodex`'s `usage_hourly` UPDATE gains `provider`)
- Test: `internal/store/provider_migration_test.go`, `internal/store/rollup_equiv_test.go`

**Interfaces:**
- Consumes: `usage_events.provider` (Task 1).
- Produces: `usage_hourly.provider` inside the PRIMARY KEY, so Task 4's `ByProvider` can group the rollup as well as raw events.

- [ ] **Step 1: Write the failing test**

Create `internal/store/provider_migration_test.go`:

```go
package store

import (
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// Rollup history outlives the raw events it was built from, so the migration
// must carry every existing row across rather than rebuilding from
// usage_events — a rebuild silently drops every hour whose raw rows were
// pruned.
func TestMigrateProvider_PreservesRollupHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollup.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acct", "ep1")
	if _, _, err := s.InsertEvents(ident("acct"), "ep1",
		[]model.UsageEvent{ev("acct", "ep1", "u1", 100), ev("acct", "ep1", "u2", 200)}); err != nil {
		t.Fatal(err)
	}
	// Prune the raw events: only the rollup remains, as in production.
	if _, err := s.DB().Exec(`DELETE FROM usage_events`); err != nil {
		t.Fatal(err)
	}
	var wantRows int
	var wantOut int64
	if err := s.DB().QueryRow(`SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM usage_hourly`).Scan(&wantRows, &wantOut); err != nil {
		t.Fatal(err)
	}
	if wantRows == 0 {
		t.Fatal("fixture produced no rollup rows")
	}
	s.Close()

	s2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	var gotRows int
	var gotOut int64
	if err := s2.DB().QueryRow(`SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM usage_hourly`).Scan(&gotRows, &gotOut); err != nil {
		t.Fatal(err)
	}
	if gotRows != wantRows || gotOut != wantOut {
		t.Errorf("after migration: %d rows / %d output tokens; want %d / %d", gotRows, gotOut, wantRows, wantOut)
	}

	// Pre-migration rows genuinely predate the dimension and say so by being
	// empty. Inventing a provider for them would be a fabricated breakdown.
	var blank int
	if err := s2.DB().QueryRow(`SELECT COUNT(*) FROM usage_hourly WHERE provider = ''`).Scan(&blank); err != nil {
		t.Fatal(err)
	}
	if blank != wantRows {
		t.Errorf("%d pre-migration rows have a provider; want all %d empty", wantRows-blank, wantRows)
	}
}

// Two providers serving the same model in the same hour are two rollup rows,
// not one. If provider is missing from the PRIMARY KEY they collapse and the
// per-contract figures are lost forever.
func TestRollup_ProviderSplitsRows(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	mk := func(uuid, provider string, out int64) model.UsageEvent {
		e := ev("acct", "ep1", uuid, out)
		e.Source = model.SourceGateway
		e.Model = "deepseek-v4-flash"
		e.Details = &model.UsageDetails{Provider: provider}
		return e
	}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{
		mk("g1", "dashscope.aliyuncs.com", 10),
		mk("g2", "ark.cn-beijing.volces.com", 20),
	}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.DB().Query(`SELECT provider, output_tokens FROM usage_hourly
		WHERE source = 'gateway' ORDER BY provider`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[string]int64{}
	for rows.Next() {
		var p string
		var out int64
		if err := rows.Scan(&p, &out); err != nil {
			t.Fatal(err)
		}
		got[p] = out
	}
	if len(got) != 2 {
		t.Fatalf("got %d rollup rows (%v); want one per provider", len(got), got)
	}
	if got["dashscope.aliyuncs.com"] != 10 || got["ark.cn-beijing.volces.com"] != 20 {
		t.Errorf("rollup rows = %v", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/store/ -run 'TestMigrateProvider|TestRollup_ProviderSplitsRows' -v`
Expected: FAIL — `no such column: provider` on `usage_hourly`.

- [ ] **Step 3: Update the schema**

In `internal/store/schema.sql`, in the `usage_hourly` definition, add the column after `model` and add it to the PRIMARY KEY:

```sql
  model         TEXT NOT NULL DEFAULT '',
  provider      TEXT NOT NULL DEFAULT '',
```

```sql
  PRIMARY KEY (hour, account_uuid, endpoint_id, session_id, os_user, cwd,
               model, provider, git_branch, effort, entrypoint, is_sidechain, source)
```

- [ ] **Step 4: Write the migration**

Create `internal/store/provider_migration.go`:

```go
package store

import (
	"database/sql"
	"fmt"
	"strings"
)

// migrateHourlyProvider adds usage_hourly.provider to the PRIMARY KEY.
//
// SQLite cannot alter a primary key, so this is the rename-recreate-copy dance
// migrateSources already performs for `source`, and it copies rather than
// rebuilds for the same reason: rollup history outlives the raw events it came
// from, and reconstructing from usage_events would silently drop every hour
// whose raw rows have been pruned.
//
// Existing rows get '' — NOT a provider inferred from source or model. Those
// hours genuinely predate the dimension; a fabricated breakdown that adds up
// is worse than an honest blank one that does not, and ProviderNote is what
// tells a reader which is which.
func migrateHourlyProvider(db *sql.DB) error {
	has, err := hasColumn(db, "usage_hourly", "provider")
	if err != nil || has {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`ALTER TABLE usage_hourly RENAME TO usage_hourly_before_provider`); err != nil {
		return err
	}
	start := strings.Index(schemaSQL, "CREATE TABLE IF NOT EXISTS usage_hourly (")
	if start < 0 {
		return fmt.Errorf("usage_hourly definition not found in schema.sql")
	}
	end := start + strings.Index(schemaSQL[start:], ";") + 1
	if _, err := tx.Exec(schemaSQL[start:end]); err != nil {
		return err
	}
	const columns = `hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
		effort, entrypoint, is_sidechain, source, events, input_tokens, output_tokens,
		cache_create_5m_tokens, cache_create_1h_tokens, cache_read_tokens, thinking_tokens,
		cost_usd, unpriced_events, min_ts, max_ts, cache_write_tokens, cache_write_known_events`
	if _, err := tx.Exec(`INSERT INTO usage_hourly (` + columns + `, provider)
		SELECT ` + columns + `, '' FROM usage_hourly_before_provider;
		DROP TABLE usage_hourly_before_provider;
		CREATE INDEX IF NOT EXISTS idx_hourly_account_hour ON usage_hourly(account_uuid, hour);
		CREATE INDEX IF NOT EXISTS idx_hourly_session ON usage_hourly(account_uuid, session_id)`); err != nil {
		return fmt.Errorf("migrate hourly provider: %w", err)
	}
	return tx.Commit()
}

// ProviderNote explains an empty provider bucket, which has two causes that a
// reader must not conflate with each other or with a vendor named "unknown".
const ProviderNote = "An empty provider means the reporting side declared none: " +
	"Claude transcripts carry no upstream, and hourly rows aggregated before this " +
	"hub gained the provider dimension were not re-attributed — they are reported " +
	"blank rather than assigned to a vendor they may not belong to."
```

- [ ] **Step 5: Call it, and write provider on the rollup path**

In `internal/store/store.go`'s `migrate()`, before `return migrateDetails(db)`:

```go
	if err := migrateHourlyProvider(db); err != nil {
		return err
	}
```

In `internal/store/rollup.go`, add `provider` to `rollupInsertSQL`'s column list, its `VALUES` list and its `ON CONFLICT` target:

```go
const rollupInsertSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider, git_branch,
  effort, entrypoint, is_sidechain, source,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts,cache_write_tokens,cache_write_known_events
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?, 1,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider,
            git_branch, effort, entrypoint, is_sidechain, source) DO UPDATE SET
```

(the `DO UPDATE SET` body is unchanged)

In `rollupUpsert`, add `e.Provider` to the argument list in the position matching the column.

In `internal/store/details.go`, `enrichCodex`'s `usage_hourly` UPDATE gains `AND provider=?` in its WHERE clause with `e.Provider` bound in the matching position. Codex events carry a provider (`session_meta.model_provider`), so omitting it would target the wrong row once two providers exist for one Codex model.

- [ ] **Step 6: Run tests to verify they pass**

Run: `go test ./internal/store/ -run 'TestMigrateProvider|TestRollup_ProviderSplitsRows' -v`
Expected: PASS

- [ ] **Step 7: Extend the rollup-equivalence test**

`rollup_equiv_test.go` asserts the raw and rollup paths agree. After this migration they agree on tokens, events and cost but may disagree on `provider` for any period where raw rows survive but the rollup predates the migration. Append to `internal/store/rollup_equiv_test.go`:

```go
// Raw and rollup agree on every figure. They may disagree on provider for
// hours whose rollup row predates the dimension — that gap is documented by
// ProviderNote, and this test pins it to provider alone.
func TestRollupEquiv_ProviderGapDoesNotMoveTotals(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "gp1", 100)
	e.Source = model.SourceGateway
	e.Model = "qwen-plus"
	e.Details = &model.UsageDetails{Provider: "dashscope.aliyuncs.com"}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	// Simulate a rollup row written before the dimension existed.
	if _, err := s.DB().Exec(`UPDATE usage_hourly SET provider = ''`); err != nil {
		t.Fatal(err)
	}

	var rawTok, rollTok int64
	if err := s.DB().QueryRow(`SELECT COALESCE(SUM(output_tokens),0) FROM usage_events`).Scan(&rawTok); err != nil {
		t.Fatal(err)
	}
	if err := s.DB().QueryRow(`SELECT COALESCE(SUM(output_tokens),0) FROM usage_hourly`).Scan(&rollTok); err != nil {
		t.Fatal(err)
	}
	if rawTok != rollTok {
		t.Errorf("totals moved: raw %d, rollup %d", rawTok, rollTok)
	}
}
```

- [ ] **Step 8: Run the full store package**

Run: `go test ./internal/store/ -v`
Expected: PASS, including every pre-existing rollup and equivalence test.

- [ ] **Step 9: Commit**

```bash
gofmt -w internal/store/rollup.go internal/store/details.go internal/store/store.go internal/store/provider_migration.go internal/store/provider_migration_test.go internal/store/rollup_equiv_test.go
go test ./... >/dev/null && echo OK
git add internal/store/schema.sql internal/store/rollup.go internal/store/details.go internal/store/store.go internal/store/provider_migration.go internal/store/provider_migration_test.go internal/store/rollup_equiv_test.go
git commit -m "$(cat <<'EOF'
feat(store): provider 进小时汇总的主键 —— 同一模型两家上游是两行，不是一行

SQLite 改不了主键，所以走 migrateSources 加 source 时那套重命名-重建-灌数据。
灌而不是重算，理由和当年一样：汇总的历史比原始事件活得久，从 usage_events 重建会
把所有原始行已被裁掉的小时静默丢光。

老行的 provider 一律留空，不按 source 或 model 反推。那些小时确实早于这个维度；
一个凑得上数的编造分档，比一个凑不上数的诚实空档更坏 —— ProviderNote 负责说清是哪种。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `ByProvider` dimension and `Filter.Provider`

**Files:**
- Modify: `internal/store/query.go` (`ByProvider`, `column()`)
- Modify: `internal/store/filter.go` (`Filter.Provider`, `eq`)
- Test: `internal/store/query_test.go`, `internal/store/cost_guard_test.go`

**Interfaces:**
- Consumes: `usage_events.provider` (Task 1), `usage_hourly.provider` (Task 3).
- Produces:
  - `store.ByProvider Dimension = "provider"`
  - `store.Filter.Provider string`
  Both consumed by Task 5.

- [ ] **Step 1: Write the failing test**

Append to `internal/store/query_test.go`:

```go
func TestUsageBy_Provider(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	mk := func(uuid, provider string, out int64) model.UsageEvent {
		e := ev("acct", "ep1", uuid, out)
		e.Source = model.SourceGateway
		e.Model = "deepseek-v4-flash"
		e.Details = &model.UsageDetails{Provider: provider}
		return e
	}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{
		mk("p1", "dashscope.aliyuncs.com", 30),
		mk("p2", "ark.cn-beijing.volces.com", 10),
		mk("p3", "dashscope.aliyuncs.com", 5),
	}); err != nil {
		t.Fatal(err)
	}

	start := time.Date(2026, 8, 31, 0, 0, 0, 0, time.UTC)
	got, err := s.UsageBy(AllAccounts, ByProvider, start, start.Add(48*time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d buckets, want 2: %+v", len(got), got)
	}
	if got[0].Key != "dashscope.aliyuncs.com" || got[0].Events != 2 {
		t.Errorf("top bucket = %q with %d events; want dashscope.aliyuncs.com with 2", got[0].Key, got[0].Events)
	}
}

func TestFilter_Provider(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	mk := func(uuid, provider string) model.UsageEvent {
		e := ev("acct", "ep1", uuid, 10)
		e.Source = model.SourceGateway
		e.Details = &model.UsageDetails{Provider: provider}
		return e
	}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{
		mk("f1", "dashscope.aliyuncs.com"), mk("f2", "ark.cn-beijing.volces.com"),
	}); err != nil {
		t.Fatal(err)
	}

	f := Filter{
		Account:  AllAccounts,
		Start:    time.Date(2026, 8, 31, 0, 0, 0, 0, time.UTC),
		End:      time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC),
		Provider: "ark.cn-beijing.volces.com",
	}
	sum, err := s.Summary(f)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Events != 1 {
		t.Errorf("filtered summary has %d events, want 1", sum.Events)
	}
}
```

If `Store.Summary` has a different name or signature, use whichever function `internal/api/review.go:42`'s neighbourhood calls to build a summary from a `Filter`, and assert its event count the same way.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/store/ -run 'TestUsageBy_Provider|TestFilter_Provider' -v`
Expected: FAIL — `undefined: ByProvider`, `unknown field Provider in struct literal`.

- [ ] **Step 3: Add the dimension**

In `internal/store/query.go`, in the `Dimension` const block after `ByModel`:

```go
	// ByProvider is the upstream that actually served the request.
	//
	// It is not derivable from the model id and not derivable from the source.
	// A gateway with failover reaches one model id through several upstreams
	// at several contracted prices, so this is the axis that answers "which
	// contract did this money go to". The empty bucket means the reporting
	// side declared no provider; see ProviderNote.
	ByProvider Dimension = "provider"
```

and in `column()` after the `ByModel` case:

```go
	case ByProvider:
		return "provider", nil
```

- [ ] **Step 4: Add the filter**

In `internal/store/filter.go`, extend the struct field list:

```go
	Endpoint, OSUser, CWD, Model, Provider, Branch, Team, Session, Source string
```

and in `where`, beside the other `eq` calls:

```go
	eq("provider", f.Provider)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/store/ -run 'TestUsageBy_Provider|TestFilter_Provider' -v`
Expected: PASS

- [ ] **Step 6: Add the money guard**

Append to `internal/store/cost_guard_test.go`:

```go
// Provider is a grouping axis inside the billed kind, never a fourth kind of
// money. A provider bucket's cost must still arrive split by source and
// classified exactly as its source is.
func TestProviderBuckets_IntroduceNoNewMoneyKind(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "k1", 10)
	e.Source = model.SourceGateway
	e.Details = &model.UsageDetails{Provider: "ark.cn-beijing.volces.com"}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	start := time.Date(2026, 8, 31, 0, 0, 0, 0, time.UTC)
	got, err := s.UsageBy(AllAccounts, ByProvider, start, start.Add(48*time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range got {
		for _, c := range b.Cost {
			if c.Kind != model.CostKind(c.Source) {
				t.Errorf("provider bucket %q: source %q classified %q, want %q",
					b.Key, c.Source, c.Kind, model.CostKind(c.Source))
			}
		}
	}
}
```

- [ ] **Step 7: Run the guard and the full package**

Run: `go test ./internal/store/ -v`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
gofmt -w internal/store/query.go internal/store/filter.go internal/store/query_test.go internal/store/cost_guard_test.go
go test ./... >/dev/null && echo OK
git add internal/store/query.go internal/store/filter.go internal/store/query_test.go internal/store/cost_guard_test.go
git commit -m "$(cat <<'EOF'
feat(store): provider 成为普通的分组维度与过滤项 —— 「这笔钱进了哪份合同」

provider 既推不出来也代不掉：模型 id 推不出来（同一 id 走三家），source 也推不出来
（一个 source 后面挂着四个上游）。所以它是自己的一根轴，跟 model / project / user 平级。

它落在 billed 这一档**里面**，不是第四种钱 —— cost_guard 钉死这一条：分档结果仍按
source 拆，kind 仍由 source 决定，provider 分组不产生任何新的钱。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Expose provider on the HTTP API and MCP

**Files:**
- Modify: `internal/api/scope.go:51` (parse `?provider=`)
- Modify: `internal/api/query.go` (accept `by=provider`; attach the note)
- Modify: `internal/mcp/mcp.go:737-739` (filter args) and the usage tool schemas
- Test: `internal/api/` and `internal/mcp/` test files matching the existing naming

**Interfaces:**
- Consumes: `store.ByProvider`, `store.Filter.Provider` (Task 4), `store.ProviderNote` (Task 3), `pricing.Table.GatewayProviderLabel` (Task 2).
- Produces: `?provider=` and `by=provider` on `/v1/usage` and `/v1/summary`; a `provider` argument on the MCP usage tools; `provider_note` on any response containing an empty provider bucket. Subproject B consumes all of these.

- [ ] **Step 1: Write the failing test**

Add to the API test file that already exercises `/v1/usage` (follow its existing helper for standing up a server):

```go
func TestUsage_ByProvider(t *testing.T) {
	srv, s := newTestServer(t) // whatever the package's existing helper is called
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "a1", 10)
	e.Source = model.SourceGateway
	e.Details = &model.UsageDetails{Provider: "ark.cn-beijing.volces.com"}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	var got struct {
		Buckets []struct {
			Key string `json:"key"`
		} `json:"buckets"`
	}
	getJSON(t, srv, "/v1/usage?by=provider&since=90d", &got)
	if len(got.Buckets) != 1 || got.Buckets[0].Key != "ark.cn-beijing.volces.com" {
		t.Errorf("buckets = %+v; want one keyed ark.cn-beijing.volces.com", got.Buckets)
	}
}

func TestUsage_ProviderFilterNarrows(t *testing.T) {
	srv, s := newTestServer(t)
	seedAccount(t, s, "acct", "ep1")

	mk := func(uuid, provider string) model.UsageEvent {
		e := ev("acct", "ep1", uuid, 10)
		e.Source = model.SourceGateway
		e.Details = &model.UsageDetails{Provider: provider}
		return e
	}
	if _, _, err := s.InsertEvents(ident("acct"), "ep1", []model.UsageEvent{
		mk("b1", "ark.cn-beijing.volces.com"), mk("b2", "dashscope.aliyuncs.com"),
	}); err != nil {
		t.Fatal(err)
	}

	var got struct {
		Events int64 `json:"events"`
	}
	getJSON(t, srv, "/v1/summary?provider=dashscope.aliyuncs.com&since=90d", &got)
	if got.Events != 1 {
		t.Errorf("events = %d, want 1", got.Events)
	}
}

// An empty bucket has two causes and neither is a vendor. The response says so
// rather than leaving a blank row for the reader to interpret.
func TestUsage_EmptyProviderCarriesTheNote(t *testing.T) {
	srv, s := newTestServer(t)
	seedAccount(t, s, "acct", "ep1")
	if _, _, err := s.InsertEvents(ident("acct"), "ep1",
		[]model.UsageEvent{ev("acct", "ep1", "c1", 10)}); err != nil { // claude: no provider
		t.Fatal(err)
	}

	var got struct {
		ProviderNote string `json:"provider_note"`
	}
	getJSON(t, srv, "/v1/usage?by=provider&since=90d", &got)
	if got.ProviderNote == "" {
		t.Error("a response with an empty provider bucket must explain it")
	}
}
```

Replace `newTestServer` / `getJSON` with the package's actual helpers; read the neighbouring test for the exact names before writing.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/api/ -run 'TestUsage_.*Provider' -v`
Expected: FAIL — `by=provider` rejected as an unknown dimension; no `provider_note`.

- [ ] **Step 3: Wire the API**

In `internal/api/scope.go:51`, add the parse beside `Model`:

```go
		Model: q.Get("model"), Provider: q.Get("provider"), Branch: q.Get("branch"), Team: q.Get("team"), Session: q.Get("session"),
```

In `internal/api/query.go`, wherever the `by=` value is validated against the known dimensions, add `provider`. Then, in the response assembly for any handler that can produce provider buckets, attach the note when a bucket key is empty:

```go
	// Two different absences share the empty bucket — a source that declares
	// no upstream, and rows that predate the dimension. Naming them beats
	// leaving a blank row for the reader to guess at.
	for _, b := range buckets {
		if b.Key == "" {
			out["provider_note"] = store.ProviderNote
			break
		}
	}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/api/ -run 'TestUsage_.*Provider' -v`
Expected: PASS

- [ ] **Step 5: Wire MCP**

In `internal/mcp/mcp.go`, at the filter construction (currently lines 737-739):

```go
		Model: str(args, "model"), Provider: str(args, "provider"), Branch: str(args, "branch"),
		Team: str(args, "team"), Session: str(args, "session"),
		Source: str(args, "source"),
```

Add `provider` to the argument schema of every usage tool that already accepts `model`, described as:

```
The upstream that actually served the call — for a gateway with failover this
is NOT derivable from the model id, since one model id is reachable through
several upstreams at several contracted prices. An empty value in a result
means the reporting side declared none.
```

Add `usage_by_provider` alongside the existing `usage_by_*` tools, with the same argument set and this description:

```
Token and cost totals grouped by the upstream that served each call. Use it to
answer "which contract did this money go to" — a question the model breakdown
cannot answer, because failover sends one model id to several upstreams at
several prices. Gateway rows are BILLED (a real per-call charge); rows from
subscription sources are NOTIONAL and must never be added to them.
```

- [ ] **Step 6: Run the MCP tests and the full suite**

Run: `go test ./internal/mcp/ -v && go test ./...`
Expected: PASS. If `internal/mcp` has a golden list of tool names, update it in this commit.

- [ ] **Step 7: Update the README**

In the MCP tools table, add `usage_by_provider`. In the cost/kinds section (around line 811), add after the existing table:

```markdown
Provider is a grouping axis *inside* the billed kind, never a fourth kind of
money. `usage_by_provider` returns the same per-source `cost` split as every
other breakdown, and an empty provider is the reporting side declaring none —
not a vendor called "unknown".
```

- [ ] **Step 8: Commit**

```bash
gofmt -w internal/api/scope.go internal/api/query.go internal/mcp/mcp.go
go test ./... >/dev/null && echo OK
git add internal/api internal/mcp README.md
git commit -m "$(cat <<'EOF'
feat(api,mcp): provider 出面 —— ?provider= 过滤、by=provider 分组、usage_by_provider 工具

「这笔钱进了哪份合同」这个问题，模型分档答不了：failover 会把同一个模型 id 送到几家
上游、几个价。所以它需要自己的分组，而不是让人从模型名去猜。

空桶带 provider_note：空不是一个叫 unknown 的厂商，它有两个来源 —— 报送方本来就不声明
（claude 的 transcript），以及那些早于这个维度的汇总行。两者都不该被读成一家供应商。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Migration rehearsal against a copy of production, then release

**Files:**
- Modify: `README.md` (upgrade note)
- No source changes expected; if the rehearsal finds one, it goes in its own commit with a regression test.

**Interfaces:**
- Consumes: everything above.
- Produces: a verified binary and a green migration on real data. Subproject B starts from here.

- [ ] **Step 1: Full suite and a race check**

```bash
cd /Users/verkyyi/projects/ccquota-scratch-1
go build ./... && go vet ./... && go test ./... && go test -race ./internal/store/
```
Expected: all green.

- [ ] **Step 2: Rehearse the migration on a copy of the production database**

The migration is one-way (the `usage_hourly` rebuild), so it is exercised on a copy first. **Do not point this at the live file.**

```bash
mkdir -p /tmp/ccq-rehearsal
# Copy the production DB off the hub host to /tmp/ccq-rehearsal/prod-copy.db first
# (the hub runs in k8s; see doc/k8s-yamls/ccquota/prod/ in the monorepo).
ls -l /tmp/ccq-rehearsal/prod-copy.db
sqlite3 /tmp/ccq-rehearsal/prod-copy.db \
  'SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM usage_hourly;' \
  > /tmp/ccq-rehearsal/before.txt
cat /tmp/ccq-rehearsal/before.txt
```

- [ ] **Step 3: Run the migration and compare**

```bash
go build -o /tmp/ccq-rehearsal/ccquota ./cmd/ccquota
CCQUOTA_DB=/tmp/ccq-rehearsal/prod-copy.db /tmp/ccq-rehearsal/ccquota report --since 1h >/dev/null
sqlite3 /tmp/ccq-rehearsal/prod-copy.db \
  'SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM usage_hourly;' \
  > /tmp/ccq-rehearsal/after.txt
diff /tmp/ccq-rehearsal/before.txt /tmp/ccq-rehearsal/after.txt && echo "rollup preserved"
```

Expected: no diff. Any difference stops the release — the migration lost or duplicated rollup history.

(If `report` is not the right command to force a migration, any subcommand that opens the store will do; `ccquota --help` lists them.)

- [ ] **Step 4: Confirm the backfill found real data**

```bash
sqlite3 /tmp/ccq-rehearsal/prod-copy.db \
  "SELECT provider, COUNT(*) FROM usage_events WHERE source='gateway' GROUP BY provider ORDER BY 2 DESC;"
```

Expected: non-empty upstream hostnames (`dashscope.aliyuncs.com`, `ark.cn-beijing.volces.com`, …), not one blank row. A single blank row means the shipper's `details.model_provider` is not reaching storage — stop and investigate before releasing.

- [ ] **Step 5: Add the upgrade note**

In `README.md`, under the section covering upgrades, add:

```markdown
### Upgrading to the provider dimension

This release adds `provider` to `usage_events` and to `usage_hourly`'s primary
key. The `usage_hourly` change rebuilds the table (SQLite cannot alter a
primary key), so **take a backup before the first start** — `~/.ccquota/backups/`
is the conventional place.

Existing raw events are backfilled from `details.model_provider`, which the
gateway shipper has been sending all along. Hourly rows aggregated before the
upgrade keep an empty provider: they are reported blank rather than assigned to
a vendor they may not belong to, and every response containing such a bucket
carries `provider_note` saying so.

Gateway rates keyed on a bare model id keep working and now mean "this price
holds whoever serves it". State per-contract rates under `gateway.providers`
when two upstreams serve one model id at different prices.
```

- [ ] **Step 6: Commit and open the PR**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: 升级说明 —— provider 维度的迁移会重建 usage_hourly，先备份

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
git push -u origin scratch-1
gh pr create --title "feat: 供应商维度与网关计价修正 —— 同一模型多家上游不再共用一个价" --body "$(cat <<'EOF'
## 为什么

`gatewayCost` 按 `Normalize(e.Model)` 单键查费率，而网关自己的 `catalog.json` 用的是
`vendor/model`，别名链还会跨厂商 fallback。四个上游共用一个裸模型名的价 —— 而 gateway 的
`cost_usd` 是 `billed`，本仓唯一断言「这就是发票」的一列。

修的成本比预想低：shipper 早就在送 `details.model_provider`，`store.go` 的 INSERT 也一直
在写 `details_json`。数据在库里，只是 group 不了。不改 ingest 契约，历史能回填。

## 做了什么

- `provider` 提成 `usage_events` 的列，从 `details_json` 回填历史
- 网关计价改按 `(provider, model)`；`--pricing` 新增 `gateway.providers` 块，顶层 `models`
  保留并明确为「不论谁服务都是这个价」
- `provider` 进 `usage_hourly` 主键（重建表，照 `migrateSources` 的先例；灌而不重算，
  保住原始行已被裁掉的那些小时）
- `store.ByProvider` 维度 + `Filter.Provider`；`?provider=` / `by=provider` / `usage_by_provider`
- 空 provider 一律带 `provider_note`：空是「未申报」，不是一个叫 unknown 的厂商

## 验证

- `go test ./...` 全绿；`go test -race ./internal/store/`
- 拿生产库副本演练迁移：`usage_hourly` 行数与 token 总量前后一致
- 回填确认查到真实上游主机名，不是一片空白

## 不在本次范围

alias 维度（`chat-fast` 这类调用方要的能力）没有上报，「降级到更贵那家花了多少」还答不了，
需要 shipper 多送一个字段，跨仓，留作后续。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7: Merge and deploy**

Merge once CI is green. Deployment is the hub's k8s rollout in the monorepo
(`doc/k8s-yamls/ccquota/prod/`) — **confirm with the operator before rolling
production**, and take the database backup named in Step 5 first.

- [ ] **Step 8: Verify against the live hub**

After the rollout:

```bash
curl -s -H "Authorization: Bearer $CCQUOTA_VIEWER_TOKEN" \
  "https://ccquota.24haowan.com/v1/usage?by=provider&source=gateway&since=90d" \
  | python3 -m json.tool
```

Expected: buckets keyed by real upstream hostnames, each carrying a `cost` list
whose gateway entry is `kind: "billed"`. This is the gate for starting
subproject B — B's consumption table has no data to render without it.

---

## Self-Review

**Spec coverage.** §3.1 → Task 1 (verbatim storage, empty = not declared) and Task 2 (no hostname→vendor mapping; label from `--pricing` only). §3.2 → Tasks 1 and 3 (column, backfill, PK rebuild, no rollup reconstruction, `rollup_equiv` extension). §3.3 → Task 4. §3.4 → Task 2 (lookup order, nested overrides, flat form retained, basis names the provider, the two-provider guard test). §3.5 → Task 4 Step 6. §3.6 → Task 3 (`ProviderNote`) and Task 5 (attaching it). §5 testing → distributed across every task. §6 release → Task 6. §7 follow-ups → out of scope, restated in the PR body.

**Placeholders.** None. Two places name a lookup rather than a literal — the API/MCP test helpers in Task 5 Step 1 and the summary function in Task 4 Step 1 — because those helper names vary by file and inventing one would be worse than telling the implementer to read the neighbouring test. Both say exactly which file to read.

**Type consistency.** `model.UsageEvent.Provider` (Task 1) is read by `gatewayCost` (Task 2), written by `rollupUpsert` (Task 3), grouped by `ByProvider` (Task 4) and filtered by `Filter.Provider` (Task 4), all spelled identically. `store.ProviderNote` is defined in Task 3 and consumed in Task 5. `providerOverride{Label, Models}` and `gatewayPricing.byProvider` appear only in Task 2. `Table.GatewayProviderLabel` is defined in Task 2 and first used by subproject B.
