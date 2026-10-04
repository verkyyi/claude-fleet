# ccquota Dashboard Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hub dashboard with two views (Now / Review) driven by one URL-encoded scope (subscription · span · brush · seven drill-down chips), backed by an hourly rollup, new query endpoints and a findings engine.

**Architecture:** An `usage_hourly` rollup table (keyed by hour + every dimension + session) is maintained inside the ingest transaction and answers every Review query; a `store.Filter` carries scope + chips through store → API → MCP. The frontend is split into ES modules with no bundler: DOM-free logic in `web/dist/lib/` (tested with `node --test`), views in `now.js` / `review.js` / `session.js`, one loader with sequence numbers so stale responses are dropped.

**Tech Stack:** Go 1.25, modernc sqlite (pure Go), `net/http`, hand-written HTML/CSS/ES modules, Node 22 built-in test runner (no npm packages), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-02-ccquota-dashboard-redesign-design.md`

## Global Constraints

- No frontend build step; `web/dist` is embedded by `go build` (`web/embed.go`, `all:dist`). No npm packages anywhere.
- `go test -race ./...`, `gofmt -l .` empty, `go vet ./...` clean — the CI gate (`.github/workflows/ci.yml`).
- Every store query is scoped by account: `Filter.Account` is a uuid or `store.AllAccounts` (`"*"`); `""` is refused.
- Rollup-backed endpoints align the requested range outward to whole UTC hours and report the aligned `since`/`until`.
- Chip parameter names on the API: `endpoint`, `user`, `project`, `model`, `branch`, `team`, `session`. In the URL hash: `machine`, `login`, `project`, `model`, `branch`, `team`, `session`.
- Performance budget: every Review request < 300 ms at `span=90d` on the mini's data.
- Costs are notional and always labelled so; `cost_usd` NULL means unpriced, never 0.
- Fixed series palette order `--s1…--s8`; ≥ 2 series always get a legend; every chart card has a table view.
- Work happens on branch `dashboard-redesign` in `~/projects/ccquota`; commit after every task.

## File structure

Backend (Go):

| file | responsibility |
|---|---|
| `internal/store/filter.go` (new) | `Filter` struct + SQL `where` builder (whitelist) |
| `internal/store/rollup.go` (new) | `usage_hourly` DDL, upsert statement, backfill/rebuild, `rollup_meta` |
| `internal/store/rollup_query.go` (new) | rollup-backed aggregates: `UsageByFiltered`, `HourlyByModel`, `Summary`, `Sessions`, `SessionTurns` |
| `internal/store/limits_history.go` (new) | `LimitsHistory` raw points from `limit_snapshots` |
| `internal/store/schema.sql` (modify) | add the two tables |
| `internal/store/store.go` (modify) | `Open` calls `ensureRollup`; `InsertEvents` upserts the rollup per inserted row |
| `internal/store/query.go` (modify) | `Bucket` gains composition fields; `ByEffort`, `ByEntrypoint`; `AccountSwitches`/`EndpointAccounts` gain `account` |
| `internal/api/scope.go` (new) | parse `Filter` (+ strict times) and `compare=1` from a request |
| `internal/api/review.go` (new) | `/v1/summary`, `/v1/sessions`, `/v1/sessions/{id}`, `/v1/limits/history`, `/v1/findings` |
| `internal/api/limitshistory.go` (new) | downsampling + critical-time pure functions |
| `internal/api/history.go` (new) | fold hourly rows into hour/6h/day series with optional model stack |
| `internal/api/query.go` (modify) | `/v1/usage`, `/v1/history` use the rollup + chips + compare; switches/endpoint-accounts take `account` |
| `internal/api/live.go` (modify) | live sessions carry `os_user` |
| `internal/api/server.go` (modify) | routes; `Cache-Control: no-cache` on UI assets |
| `internal/findings/findings.go` (new) | `Finding`, `Inputs`, `NowInputs`, `Review()`, `Now()` — pure rules |
| `internal/api/findings.go` (new) | gathers inputs from the store and serves `/v1/findings` |
| `internal/mcp/mcp.go` (modify) | `usage_summary`, `list_sessions`, `get_session`, `get_findings` |
| `cmd/ccquota/hub.go` (modify) | `--rebuild-rollup`; log the backfill |

Frontend (`web/dist`, ES modules):

| file | responsibility |
|---|---|
| `index.html` (rewrite) | shell: scope bar, view containers, detail overlay, tooltip; `<script type="module" src="app.js">` |
| `styles.css` (new) | all CSS (moved out of index.html) + scope bar, chips, brush, KPI, heatmap, overlay, mobile |
| `app.js` (new) | boot, hash router, loader wiring, view switching, refresh timers |
| `lib/state.js` (new) | URL ⇄ state codec; selection resolution; API query-string mapping |
| `lib/brush.js` (new) | bucket math, snapping, default/fit selection |
| `lib/fold.js` (new) | hourly series → local dow×hour grid; busiest/quietest sentences |
| `lib/format.js` (new) | number/time formatters, deltas, `shortProject` |
| `lib/seq.js` (new) | `createLoader()` — sequence numbers + abort |
| `lib/dom.js` (new) | `el`, `escapeHTML`, tooltip |
| `charts.js` (new) | rankedBars, stackedBars+brush, stackedArea, lines, heatmap, kpi, composition, table toggle |
| `scope.js` (new) | scope bar, chips, brush wiring |
| `now.js` (new) | Now view (hero, alerts, wall, live, fleet) |
| `review.js` (new) | Review view (nine blocks) |
| `session.js` (new) | session detail overlay |
| `web/package.json` (new) | `{"type":"module"}` so Node loads `lib/*.js` as ESM |
| `web/test/*.test.mjs` (new) | Node tests for `lib/` |
| `.github/workflows/ci.yml` (modify) | `web` job: `node --test web/test/` |

---

### Task 1: `store.Filter` and the WHERE builder

**Files:**
- Create: `internal/store/filter.go`
- Test: `internal/store/filter_test.go`

**Interfaces:**
- Produces: `type Filter struct{ Account string; Start, End time.Time; Endpoint, OSUser, CWD, Model, Branch, Team, Session string }`; `func (f Filter) where(tsCol string) (clause string, args []any, err error)` — `clause` is a complete `WHERE …` fragment ending in the time bounds, using `tsCol` (`"ts"` for `usage_events`, `"hour"` for `usage_hourly`); `func (f Filter) Prev() Filter` (same length, ending at `Start`); `func (f Filter) AlignHours() Filter` (Start floored, End ceiled to the hour).

- [ ] **Step 1: Write the failing tests**

```go
// internal/store/filter_test.go
package store

import (
	"strings"
	"testing"
	"time"
)

func TestFilterWhereRefusesEmptyAccount(t *testing.T) {
	_, _, err := (Filter{}).where("ts")
	if err == nil {
		t.Fatal("empty account must be refused")
	}
}

func TestFilterWhereAllAccountsHasNoAccountClause(t *testing.T) {
	f := Filter{Account: AllAccounts, Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC()}
	clause, args, err := f.where("ts")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(clause, "account_uuid") {
		t.Fatalf("spanning filter must not scope by account: %s", clause)
	}
	if len(args) != 2 {
		t.Fatalf("want 2 time args, got %v", args)
	}
}

func TestFilterWhereIncludesEveryChip(t *testing.T) {
	f := Filter{Account: "acct", Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC(),
		Endpoint: "ep", OSUser: "u", CWD: "/p", Model: "m", Branch: "b", Team: "t", Session: "s"}
	clause, args, err := f.where("hour")
	if err != nil {
		t.Fatal(err)
	}
	for _, col := range []string{"account_uuid = ?", "endpoint_id = ?", "os_user = ?", "cwd = ?",
		"model = ?", "git_branch = ?", "session_id = ?", "SELECT endpoint_id FROM endpoints WHERE team = ?",
		"hour >= ?", "hour < ?"} {
		if !strings.Contains(clause, col) {
			t.Errorf("clause lacks %q: %s", col, clause)
		}
	}
	// account, ep, u, /p, m, b, t, s, start, end
	if len(args) != 10 {
		t.Fatalf("want 10 args, got %d: %v", len(args), args)
	}
	if args[len(args)-2] != "1970-01-01T00:00:00Z" {
		t.Fatalf("start must be RFC3339 UTC, got %v", args[len(args)-2])
	}
}

func TestFilterPrevAndAlign(t *testing.T) {
	start := time.Date(2026, 9, 2, 10, 20, 0, 0, time.UTC)
	end := time.Date(2026, 9, 2, 12, 5, 0, 0, time.UTC)
	f := Filter{Account: AllAccounts, Start: start, End: end}
	p := f.Prev()
	if !p.End.Equal(start) || !p.Start.Equal(start.Add(-(end.Sub(start)))) {
		t.Fatalf("prev = %v..%v", p.Start, p.End)
	}
	a := f.AlignHours()
	if !a.Start.Equal(time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)) ||
		!a.End.Equal(time.Date(2026, 9, 2, 13, 0, 0, 0, time.UTC)) {
		t.Fatalf("aligned = %v..%v", a.Start, a.End)
	}
	if !a.AlignHours().Start.Equal(a.Start) || !a.AlignHours().End.Equal(a.End) {
		t.Fatal("aligning twice must be idempotent")
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/projects/ccquota && go test ./internal/store -run 'TestFilter' -v`
Expected: FAIL — `undefined: Filter`.

- [ ] **Step 3: Implement**

```go
// internal/store/filter.go
package store

import (
	"fmt"
	"strings"
	"time"
)

// Filter is the scope every Review query runs under: one subscription (or
// all), a half-open time range, and at most one value per drill-down
// dimension. An empty string on a dimension means "no constraint".
type Filter struct {
	Account    string
	Start, End time.Time

	Endpoint, OSUser, CWD, Model, Branch, Team, Session string
}

// Prev is the period of the same length that ends where this one starts.
func (f Filter) Prev() Filter {
	p := f
	p.End = f.Start
	p.Start = f.Start.Add(-f.End.Sub(f.Start))
	return p
}

// AlignHours widens the range outward to whole UTC hours: the rollup can only
// answer at hour resolution, and cutting a bucket in half would under-count.
func (f Filter) AlignHours() Filter {
	a := f
	a.Start = f.Start.UTC().Truncate(time.Hour)
	if e := f.End.UTC(); e.Equal(e.Truncate(time.Hour)) {
		a.End = e
	} else {
		a.End = e.Truncate(time.Hour).Add(time.Hour)
	}
	return a
}

// where builds the WHERE fragment. Column names are fixed here — the caller's
// strings only ever become bind arguments — which is what keeps this
// injection-proof.
func (f Filter) where(tsCol string) (string, []any, error) {
	if f.Account == "" {
		return "", nil, fmt.Errorf("account is required: pass a uuid, or store.AllAccounts to span every subscription")
	}
	if tsCol != "ts" && tsCol != "hour" {
		return "", nil, fmt.Errorf("unknown time column %q", tsCol)
	}
	var parts []string
	var args []any
	if f.Account != AllAccounts {
		parts = append(parts, "account_uuid = ?")
		args = append(args, f.Account)
	}
	eq := func(col, v string) {
		if v != "" {
			parts = append(parts, col+" = ?")
			args = append(args, v)
		}
	}
	eq("endpoint_id", f.Endpoint)
	eq("os_user", f.OSUser)
	eq("cwd", f.CWD)
	eq("model", f.Model)
	eq("git_branch", f.Branch)
	eq("session_id", f.Session)
	if f.Team != "" {
		parts = append(parts, "endpoint_id IN (SELECT endpoint_id FROM endpoints WHERE team = ?)")
		args = append(args, f.Team)
	}
	parts = append(parts, tsCol+" >= ?", tsCol+" < ?")
	args = append(args, fmtTime(f.Start), fmtTime(f.End))
	return "WHERE " + strings.Join(parts, " AND "), args, nil
}
```

Check what `fmtTime` produces: `grep -n 'const rfc' internal/store/store.go`. If it is `time.RFC3339Nano`, `fmtTime(time.Unix(0,0))` yields `1970-01-01T00:00:00Z` (nanos omitted when zero) and the test above holds.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/store -run 'TestFilter' -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add internal/store/filter.go internal/store/filter_test.go
git commit -m "feat(store): Filter — one scope struct for account, range and drill-down chips"
```

---

### Task 2: the hourly rollup — table, upsert, backfill, rebuild

**Files:**
- Modify: `internal/store/schema.sql` (append)
- Create: `internal/store/rollup.go`
- Modify: `internal/store/store.go` (`Open`, `InsertEvents`)
- Test: `internal/store/rollup_test.go`

**Interfaces:**
- Produces: table `usage_hourly` (columns exactly as in spec §8.1), table `rollup_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)`; `const rollupVersion = "1"`; `func (s *Store) RebuildRollup() (rows int64, err error)`; `func (s *Store) RollupRows() (int64, error)`; unexported `hourKey(t time.Time) string` = `t.UTC().Truncate(time.Hour).Format("2006-01-02T15:00:00Z")`; unexported `rollupUpsert(tx *sql.Tx, e *model.UsageEvent) error`.

- [ ] **Step 1: Append the DDL to `schema.sql`**

```sql
-- Hourly rollup of usage_events, keyed by every dimension the dashboard can
-- drill down on plus the session. One row here stands for every turn in that
-- hour with the same (account, endpoint, session, login, project, model,
-- branch, effort, entrypoint, sidechain). The mini's 290k events collapse to a
-- few thousand rows, which is what makes brushing a 90-day timeline cheap.
--
-- Maintained in the same transaction as the event insert, so it can never
-- drift from usage_events; rebuilt from scratch when rollup_meta's version
-- changes. Pruning raw events leaves it alone on purpose: totals and sessions
-- keep working past the retention window, only per-turn detail is lost.
CREATE TABLE IF NOT EXISTS usage_hourly (
  hour          TEXT NOT NULL,   -- 'YYYY-MM-DDTHH:00:00Z', the bucket start
  account_uuid  TEXT NOT NULL,
  endpoint_id   TEXT NOT NULL,
  session_id    TEXT NOT NULL DEFAULT '',
  os_user       TEXT NOT NULL DEFAULT '',
  cwd           TEXT NOT NULL DEFAULT '',
  model         TEXT NOT NULL DEFAULT '',
  git_branch    TEXT NOT NULL DEFAULT '',
  effort        TEXT NOT NULL DEFAULT '',
  entrypoint    TEXT NOT NULL DEFAULT '',
  is_sidechain  INTEGER NOT NULL DEFAULT 0,

  events                 INTEGER NOT NULL DEFAULT 0,
  input_tokens           INTEGER NOT NULL DEFAULT 0,
  output_tokens          INTEGER NOT NULL DEFAULT 0,
  cache_create_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_create_1h_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens      INTEGER NOT NULL DEFAULT 0,
  thinking_tokens        INTEGER NOT NULL DEFAULT 0,
  cost_usd               REAL    NOT NULL DEFAULT 0,   -- priced turns only
  unpriced_events        INTEGER NOT NULL DEFAULT 0,   -- turns with NULL cost
  min_ts                 TEXT NOT NULL,
  max_ts                 TEXT NOT NULL,
  PRIMARY KEY (hour, account_uuid, endpoint_id, session_id, os_user, cwd,
               model, git_branch, effort, entrypoint, is_sidechain)
);
CREATE INDEX IF NOT EXISTS idx_hourly_account_hour ON usage_hourly(account_uuid, hour);
CREATE INDEX IF NOT EXISTS idx_hourly_session ON usage_hourly(account_uuid, session_id);

CREATE TABLE IF NOT EXISTS rollup_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

- [ ] **Step 2: Write the failing tests**

```go
// internal/store/rollup_test.go
package store

import (
	"path/filepath"
	"testing"
	"time"
)

func TestRollupFollowsInsertsAndIgnoresDedup(t *testing.T) {
	s := openTemp(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	e1 := ev("acct-a", "ep-a1", "u-1", 100) // 12:00
	e2 := ev("acct-a", "ep-a1", "u-2", 50)  // same hour, same key
	e3 := ev("acct-a", "ep-a1", "u-3", 7)
	e3.TS = e3.TS.Add(90 * time.Minute) // 13:30 -> a second hour row
	e3.CostUSD = nil                    // unpriced
	if _, _, err := s.InsertEvents([]model.UsageEvent{e1, e2, e3, e1}); err != nil { // e1 twice = dedup
		t.Fatal(err)
	}
	var rows int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 2 {
		t.Fatalf("want 2 hourly rows, got %d", rows)
	}
	var events, out, unpriced int64
	var cost float64
	var minTS, maxTS string
	err := s.db.QueryRow(`SELECT events, output_tokens, unpriced_events, cost_usd, min_ts, max_ts
		FROM usage_hourly WHERE hour = '2026-08-31T12:00:00Z'`).Scan(&events, &out, &unpriced, &cost, &minTS, &maxTS)
	if err != nil {
		t.Fatal(err)
	}
	if events != 2 || out != 150 || unpriced != 0 || cost != 3.0 {
		t.Fatalf("12:00 row = events %d out %d unpriced %d cost %v", events, out, unpriced, cost)
	}
	err = s.db.QueryRow(`SELECT events, unpriced_events, cost_usd FROM usage_hourly
		WHERE hour = '2026-08-31T13:00:00Z'`).Scan(&events, &unpriced, &cost)
	if err != nil {
		t.Fatal(err)
	}
	if events != 1 || unpriced != 1 || cost != 0 {
		t.Fatalf("13:00 row = events %d unpriced %d cost %v", events, unpriced, cost)
	}
}

func TestRollupBackfillMatchesIncremental(t *testing.T) {
	s := openTemp(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	var evs []model.UsageEvent
	for i := 0; i < 40; i++ {
		e := ev("acct-a", "ep-a1", "u-"+string(rune('a'+i%26))+string(rune('a'+i/26)), int64(i))
		e.TS = e.TS.Add(time.Duration(i*37) * time.Minute)
		if i%5 == 0 {
			e.Model = "claude-opus-5"
		}
		if i%7 == 0 {
			e.IsSidechain = true
		}
		if i%11 == 0 {
			e.CostUSD = nil
		}
		evs = append(evs, e)
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	incremental := dumpRollup(t, s)
	if n, err := s.RebuildRollup(); err != nil || n == 0 {
		t.Fatalf("rebuild: n=%d err=%v", n, err)
	}
	rebuilt := dumpRollup(t, s)
	if incremental != rebuilt {
		t.Fatalf("rebuild differs from incremental upserts:\n%s\n---\n%s", incremental, rebuilt)
	}
}

func TestOpenBackfillsEmptyRollupAndHonoursVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "r.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acct-a", "ep-a1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-a1", "u-1", 5)}); err != nil {
		t.Fatal(err)
	}
	// Simulate a database written by a hub that predates the rollup.
	if _, err := s.db.Exec(`DELETE FROM usage_hourly; DELETE FROM rollup_meta`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if n, _ := s.RollupRows(); n != 1 {
		t.Fatalf("Open must backfill an empty rollup, rows=%d", n)
	}
	var v string
	if err := s.db.QueryRow(`SELECT value FROM rollup_meta WHERE key='usage_hourly_version'`).Scan(&v); err != nil || v != rollupVersion {
		t.Fatalf("version stamp = %q err=%v", v, err)
	}
}

func openTemp(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func dumpRollup(t *testing.T, s *Store) string {
	t.Helper()
	rows, err := s.db.Query(`SELECT hour, model, is_sidechain, events, output_tokens, cost_usd, unpriced_events, min_ts, max_ts
		FROM usage_hourly ORDER BY hour, model, is_sidechain`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out string
	for rows.Next() {
		var hour, model, minTS, maxTS string
		var side, events, outTok, unpriced int64
		var cost float64
		if err := rows.Scan(&hour, &model, &side, &events, &outTok, &cost, &unpriced, &minTS, &maxTS); err != nil {
			t.Fatal(err)
		}
		out += fmt.Sprintf("%s %s %d %d %d %.4f %d %s %s\n", hour, model, side, events, outTok, cost, unpriced, minTS, maxTS)
	}
	return out
}
```

Add `"fmt"` and `"github.com/verkyyi/ccquota/internal/model"` to the imports (check the module path with `head -1 go.mod`). If `store_test.go` already defines a temp-open helper under another name, use that name instead of adding `openTemp`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/store -run 'TestRollup|TestOpenBackfills' -v`
Expected: FAIL — `no such table: usage_hourly` / `undefined: RebuildRollup`.

- [ ] **Step 4: Implement `rollup.go`**

```go
// internal/store/rollup.go
package store

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// rollupVersion is stamped into rollup_meta. Bump it when the rollup's key or
// columns change: Open then rebuilds the table from usage_events.
const rollupVersion = "1"

func hourKey(t time.Time) string {
	return t.UTC().Truncate(time.Hour).Format("2006-01-02T15:00:00Z")
}

const rollupInsertSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
  effort, entrypoint, is_sidechain,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts
) VALUES (?,?,?,?,?,?,?,?,?,?,?, 1,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(hour, account_uuid, endpoint_id, session_id, os_user, cwd, model,
            git_branch, effort, entrypoint, is_sidechain) DO UPDATE SET
  events                 = events + 1,
  input_tokens           = input_tokens + excluded.input_tokens,
  output_tokens          = output_tokens + excluded.output_tokens,
  cache_create_5m_tokens = cache_create_5m_tokens + excluded.cache_create_5m_tokens,
  cache_create_1h_tokens = cache_create_1h_tokens + excluded.cache_create_1h_tokens,
  cache_read_tokens      = cache_read_tokens + excluded.cache_read_tokens,
  thinking_tokens        = thinking_tokens + excluded.thinking_tokens,
  cost_usd               = cost_usd + excluded.cost_usd,
  unpriced_events        = unpriced_events + excluded.unpriced_events,
  min_ts                 = min(min_ts, excluded.min_ts),
  max_ts                 = max(max_ts, excluded.max_ts)`

// rollupUpsert folds one freshly inserted event into its hourly row.
func rollupUpsert(stmt *sql.Stmt, e *model.UsageEvent) error {
	var cost float64
	var unpriced int64
	if e.CostUSD != nil {
		cost = *e.CostUSD
	} else {
		unpriced = 1
	}
	side := 0
	if e.IsSidechain {
		side = 1
	}
	ts := fmtTime(e.TS)
	_, err := stmt.Exec(
		hourKey(e.TS), e.AccountUUID, e.EndpointID, e.SessionID, e.OSUser, e.CWD, e.Model, e.GitBranch,
		e.Effort, e.Entrypoint, side,
		e.InputTokens, e.OutputTokens, e.CacheCreate5m, e.CacheCreate1h,
		e.CacheRead, e.Thinking, cost, unpriced, ts, ts)
	return err
}

const rollupBackfillSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
  effort, entrypoint, is_sidechain,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts)
SELECT strftime('%Y-%m-%dT%H:00:00Z', ts), account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
       effort, entrypoint, is_sidechain,
       COUNT(*), SUM(input_tokens), SUM(output_tokens), SUM(cache_create_5m_tokens), SUM(cache_create_1h_tokens),
       SUM(cache_read_tokens), SUM(thinking_tokens), COALESCE(SUM(cost_usd), 0),
       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), MIN(ts), MAX(ts)
FROM usage_events
GROUP BY 1,2,3,4,5,6,7,8,9,10,11`

// RebuildRollup recomputes usage_hourly from usage_events in one transaction
// and stamps the current version. Returns the number of rollup rows.
func (s *Store) RebuildRollup() (int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM usage_hourly`); err != nil {
		return 0, fmt.Errorf("clear rollup: %w", err)
	}
	res, err := tx.Exec(rollupBackfillSQL)
	if err != nil {
		return 0, fmt.Errorf("backfill rollup: %w", err)
	}
	n, _ := res.RowsAffected()
	if _, err := tx.Exec(`INSERT INTO rollup_meta(key, value) VALUES ('usage_hourly_version', ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, rollupVersion); err != nil {
		return 0, fmt.Errorf("stamp rollup version: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return n, nil
}

// RollupRows counts usage_hourly.
func (s *Store) RollupRows() (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&n)
	return n, err
}

// ensureRollup rebuilds the rollup when it is missing or from another version.
// Called from Open; returns how many rows were built (0 = nothing to do).
func ensureRollup(s *Store) (int64, error) {
	var version string
	err := s.db.QueryRow(`SELECT value FROM rollup_meta WHERE key = 'usage_hourly_version'`).Scan(&version)
	if err != nil && err != sql.ErrNoRows {
		return 0, fmt.Errorf("read rollup version: %w", err)
	}
	rows, err := s.RollupRows()
	if err != nil {
		return 0, err
	}
	var events int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&events); err != nil {
		return 0, err
	}
	if version == rollupVersion && (rows > 0 || events == 0) {
		return 0, nil
	}
	return s.RebuildRollup()
}
```

- [ ] **Step 5: Wire it into `store.go`**

In `Open`, after `migrate(db)` succeeds and before `return &Store{db: db}, nil`:

```go
	st := &Store{db: db}
	if _, err := ensureRollup(st); err != nil {
		db.Close()
		return nil, err
	}
	return st, nil
```

Expose the count for the hub's log line: add a field `BackfilledRollup int64` to `Store` and set it from `ensureRollup`'s return (`st.BackfilledRollup, err = ensureRollup(st)`).

In `InsertEvents`, after `stmt` is prepared, prepare the rollup statement and use it for every inserted row:

```go
	rstmt, err := tx.Prepare(rollupInsertSQL)
	if err != nil {
		return 0, 0, fmt.Errorf("prepare rollup upsert: %w", err)
	}
	defer rstmt.Close()
	…
		if n, _ := res.RowsAffected(); n > 0 {
			inserted++
			if err := rollupUpsert(rstmt, e); err != nil {
				return 0, 0, fmt.Errorf("rollup event %s: %w", e.MessageUUID, err)
			}
		} else {
			deduped++
		}
```

- [ ] **Step 6: Run the store tests**

Run: `go test ./internal/store -v 2>&1 | tail -20`
Expected: all PASS, including the three new tests. If `TestRollupBackfillMatchesIncremental` fails on `min_ts`/`max_ts` formatting, make the Go and SQL sides agree: the upsert writes `fmtTime(e.TS)`, the backfill copies `ts` verbatim — both are what `InsertEvents` stored, so they must be byte-identical.

- [ ] **Step 7: Commit**

```bash
git add internal/store/schema.sql internal/store/rollup.go internal/store/store.go internal/store/rollup_test.go
git commit -m "feat(store): hourly rollup keyed by every dimension, maintained in the ingest transaction"
```

---

### Task 3: rollup-backed aggregates

**Files:**
- Modify: `internal/store/query.go` (`Bucket`, dimensions)
- Create: `internal/store/rollup_query.go`
- Create: `internal/store/limits_history.go`
- Test: `internal/store/rollup_query_test.go`

**Interfaces:**
- Consumes: `Filter` (Task 1), `usage_hourly` (Task 2), existing `Bucket`, `Dimension`, `labelEndpoints`, `labelAccounts`, `labelTeams`.
- Produces:
  - `Bucket` gains `InputTokens, OutputTokens, CacheReadTokens, CacheCreateTokens, ThinkingTokens int64` (json `input_tokens`… with `omitempty`) and `PrevTokens int64`, `PrevCostUSD float64`, `PrevEvents int64` (json `prev_tokens`… `omitempty`).
  - `const ByEffort Dimension = "effort"`, `ByEntrypoint Dimension = "entrypoint"` (added to `column()`).
  - `func (s *Store) UsageByFiltered(f Filter, d Dimension, limit int) ([]Bucket, error)`
  - `type HourRow struct{ Hour, Model string; Events, Tokens int64; CostUSD float64; Unpriced, Sidechain int64 }`; `func (s *Store) HourlyByModel(f Filter) ([]HourRow, error)`
  - `type Summary struct{ Events, Tokens, Sessions int64; CostUSD float64; Unpriced, InputTokens, OutputTokens, CacheReadTokens, CacheCreateTokens, ThinkingTokens, SidechainTokens, SidechainEvents int64 }` (json snake_case); `func (s *Store) Summary(f Filter) (*Summary, error)`
  - `type SessionRow struct{ SessionID, AccountUUID, EndpointID, Endpoint, OSUser, CWD, Model string; Models []string; Started, Ended time.Time; Turns, Tokens int64; CostUSD float64; Unpriced, OutputTokens, CacheReadTokens, InputTokens, CacheCreateTokens, SidechainTokens int64; CacheHit, SidechainShare float64 }`; `func (s *Store) Sessions(f Filter, sort string, limit, offset int) ([]SessionRow, error)`; `func (s *Store) Session(account, id string) (*SessionRow, error)`
  - `type Turn struct{ TS time.Time; Model, Effort string; InputTokens, OutputTokens, CacheReadTokens, CacheCreateTokens, ThinkingTokens int64; CostUSD *float64; IsSidechain bool }`; `func (s *Store) SessionTurns(account, id string) ([]Turn, error)`
  - `type LimitPoint struct{ AccountUUID string; T time.Time; FiveHour, SevenDay float64 }`; `func (s *Store) LimitsHistory(account string, start, end time.Time) ([]LimitPoint, error)`

- [ ] **Step 1: Extend `Bucket` and the dimensions in `query.go`**

```go
type Bucket struct {
	Key       string  `json:"key"`
	Label     string  `json:"label"`
	Events    int64   `json:"events"`
	Tokens    int64   `json:"tokens"`
	CostUSD   float64 `json:"cost_usd"`
	Unpriced  int64   `json:"unpriced_events"`
	Sidechain int64   `json:"sidechain_tokens"`

	// Composition, filled by rollup-backed queries only.
	InputTokens       int64 `json:"input_tokens,omitempty"`
	OutputTokens      int64 `json:"output_tokens,omitempty"`
	CacheReadTokens   int64 `json:"cache_read_tokens,omitempty"`
	CacheCreateTokens int64 `json:"cache_create_tokens,omitempty"`
	ThinkingTokens    int64 `json:"thinking_tokens,omitempty"`

	// The same key in the previous period, when the caller asked to compare.
	PrevEvents  int64   `json:"prev_events,omitempty"`
	PrevTokens  int64   `json:"prev_tokens,omitempty"`
	PrevCostUSD float64 `json:"prev_cost_usd,omitempty"`
}
```

Add to the const block: `ByEffort Dimension = "effort"` and `ByEntrypoint Dimension = "entrypoint"`, and to `column()`: `case ByEffort: return "effort", nil` and `case ByEntrypoint: return "entrypoint", nil`.

- [ ] **Step 2: Write the failing tests**

```go
// internal/store/rollup_query_test.go
package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// seedReview builds two sessions on two projects across three hours.
func seedReview(t *testing.T, s *Store) {
	t.Helper()
	seedAccount(t, s, "acct-a", "ep-a1")
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	mk := func(uuid, session, cwd, model string, min int, out, cacheRead, input int64, side bool, priced bool) model.UsageEvent {
		e := ev("acct-a", "ep-a1", uuid, out)
		e.SessionID, e.CWD, e.Model = session, cwd, model
		e.TS = base.Add(time.Duration(min) * time.Minute)
		e.CacheRead, e.InputTokens, e.IsSidechain = cacheRead, input, side
		e.OSUser, e.Effort, e.Entrypoint = "verkyyi", "xhigh", "cli"
		if !priced {
			e.CostUSD = nil
		}
		return e
	}
	evs := []model.UsageEvent{
		mk("1", "s-big", "/p/alpha", "claude-opus-5", 0, 100, 900, 10, false, true),
		mk("2", "s-big", "/p/alpha", "claude-opus-5", 30, 100, 900, 10, true, true),
		mk("3", "s-big", "/p/alpha", "claude-haiku-4-5", 70, 50, 100, 10, false, false),
		mk("4", "s-small", "/p/beta", "claude-opus-5", 130, 20, 80, 0, false, true),
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
}

func reviewFilter() Filter {
	return Filter{Account: "acct-a",
		Start: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
		End:   time.Date(2026, 8, 31, 15, 0, 0, 0, time.UTC)}
}

func TestUsageByFilteredMatchesEventsAndCarriesComposition(t *testing.T) {
	s := openTemp(t)
	seedReview(t, s)
	f := reviewFilter()
	got, err := s.UsageByFiltered(f, ByProject, 10)
	if err != nil {
		t.Fatal(err)
	}
	want, err := s.UsageBy("acct-a", ByProject, f.Start, f.End, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || len(want) != 2 || got[0].Key != "/p/alpha" {
		t.Fatalf("got %+v want %+v", got, want)
	}
	for i := range got {
		if got[i].Tokens != want[i].Tokens || got[i].Events != want[i].Events ||
			got[i].CostUSD != want[i].CostUSD || got[i].Unpriced != want[i].Unpriced || got[i].Sidechain != want[i].Sidechain {
			t.Fatalf("row %d: rollup %+v vs events %+v", i, got[i], want[i])
		}
	}
	if got[0].CacheReadTokens != 1900 || got[0].OutputTokens != 250 || got[0].InputTokens != 30 {
		t.Fatalf("composition: %+v", got[0])
	}
	// A chip narrows it.
	f.Model = "claude-haiku-4-5"
	got, _ = s.UsageByFiltered(f, ByProject, 10)
	if len(got) != 1 || got[0].Events != 1 || got[0].Unpriced != 1 {
		t.Fatalf("model chip: %+v", got)
	}
}

func TestHourlyByModel(t *testing.T) {
	s := openTemp(t)
	seedReview(t, s)
	rows, err := s.HourlyByModel(reviewFilter())
	if err != nil {
		t.Fatal(err)
	}
	// 12:00 opus (2 turns), 13:00 haiku, 14:00 opus
	if len(rows) != 3 || rows[0].Hour != "2026-08-31T12:00:00Z" || rows[0].Model != "claude-opus-5" || rows[0].Events != 2 {
		t.Fatalf("%+v", rows)
	}
}

func TestSummary(t *testing.T) {
	s := openTemp(t)
	seedReview(t, s)
	sum, err := s.Summary(reviewFilter())
	if err != nil {
		t.Fatal(err)
	}
	if sum.Events != 4 || sum.Sessions != 2 || sum.Unpriced != 1 || sum.OutputTokens != 270 ||
		sum.CacheReadTokens != 1980 || sum.SidechainEvents != 1 || sum.CostUSD != 4.5 {
		t.Fatalf("%+v", sum)
	}
}

func TestSessionsAndTurns(t *testing.T) {
	s := openTemp(t)
	seedReview(t, s)
	rows, err := s.Sessions(reviewFilter(), "tokens", 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].SessionID != "s-big" || rows[0].Turns != 3 || rows[0].Model != "claude-opus-5" ||
		len(rows[0].Models) != 2 || rows[0].Ended.Sub(rows[0].Started) != 70*time.Minute || rows[0].CWD != "/p/alpha" {
		t.Fatalf("%+v", rows)
	}
	if rows[0].CacheHit < 0.9 || rows[0].CacheHit > 1 || rows[0].SidechainShare <= 0 {
		t.Fatalf("ratios: %+v", rows[0])
	}
	if rows, _ = s.Sessions(reviewFilter(), "started", 1, 1); len(rows) != 1 || rows[0].SessionID != "s-big" {
		t.Fatalf("started desc, offset 1: %+v", rows)
	}
	turns, err := s.SessionTurns("acct-a", "s-big")
	if err != nil || len(turns) != 3 || !turns[1].IsSidechain || turns[2].CostUSD != nil {
		t.Fatalf("turns=%+v err=%v", turns, err)
	}
	one, err := s.Session("acct-a", "s-small")
	if err != nil || one == nil || one.Turns != 1 {
		t.Fatalf("session=%+v err=%v", one, err)
	}
	if _, err := s.Sessions(reviewFilter(), "drop table", 10, 0); err == nil {
		t.Fatal("unknown sort must be refused")
	}
}

func TestLimitsHistory(t *testing.T) {
	s := openTemp(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	at := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i, pct := range []float64{10, 95, 50} {
		snap := &model.LimitsSnapshot{AccountUUID: "acct-a", EndpointID: "ep-a1", ObservedAt: at.Add(time.Duration(i) * time.Minute)}
		snap.FiveHour.Utilization = pct
		snap.SevenDay.Utilization = 20
		if err := s.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
	}
	pts, err := s.LimitsHistory(AllAccounts, at, at.Add(time.Hour))
	if err != nil || len(pts) != 3 || pts[1].FiveHour != 95 || pts[1].AccountUUID != "acct-a" {
		t.Fatalf("pts=%+v err=%v", pts, err)
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/store -run 'TestUsageByFiltered|TestHourlyByModel|TestSummary|TestSessionsAndTurns|TestLimitsHistory' -v`
Expected: FAIL — undefined methods.

- [ ] **Step 4: Implement `rollup_query.go`**

```go
// internal/store/rollup_query.go
package store

import (
	"database/sql"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

const hourlyTokens = `(input_tokens + output_tokens + cache_create_5m_tokens + cache_create_1h_tokens + cache_read_tokens)`

// UsageByFiltered is UsageBy over the rollup, under a Filter, with the token
// composition filled in. Team is a join, as in UsageBy.
func (s *Store) UsageByFiltered(f Filter, d Dimension, limit int) ([]Bucket, error) {
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	if d == ByTeam {
		col = `COALESCE((SELECT e.team FROM endpoints e WHERE e.endpoint_id = usage_hourly.endpoint_id), '')`
	}
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}
	q := fmt.Sprintf(`
		SELECT %s AS k, SUM(events), SUM%s, SUM(cost_usd), SUM(unpriced_events),
		       SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),
		       SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
		       SUM(cache_create_5m_tokens + cache_create_1h_tokens), SUM(thinking_tokens)
		FROM usage_hourly %s
		GROUP BY k ORDER BY 3 DESC LIMIT ?`, col, hourlyTokens, hourlyTokens, where)
	rows, err := s.db.Query(q, append(args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("usage by %s (rollup): %w", d, err)
	}
	defer rows.Close()
	var out []Bucket
	for rows.Next() {
		var b Bucket
		if err := rows.Scan(&b.Key, &b.Events, &b.Tokens, &b.CostUSD, &b.Unpriced, &b.Sidechain,
			&b.InputTokens, &b.OutputTokens, &b.CacheReadTokens, &b.CacheCreateTokens, &b.ThinkingTokens); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	switch d {
	case ByEndpoint:
		s.labelEndpoints(out)
	case ByAccount:
		s.labelAccounts(out)
	case ByTeam:
		labelTeams(out)
	}
	return out, nil
}

// HourRow is one (hour, model) cell of the rollup.
type HourRow struct {
	Hour      string  `json:"hour"`
	Model     string  `json:"model"`
	Events    int64   `json:"events"`
	Tokens    int64   `json:"tokens"`
	CostUSD   float64 `json:"cost_usd"`
	Unpriced  int64   `json:"unpriced_events"`
	Sidechain int64   `json:"sidechain_tokens"`
}

// HourlyByModel returns the rollup grouped by hour and model, oldest first.
// Callers fold it into coarser buckets; hours are the finest the store knows.
func (s *Store) HourlyByModel(f Filter) ([]HourRow, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	rows, err := s.db.Query(fmt.Sprintf(`
		SELECT hour, model, SUM(events), SUM%s, SUM(cost_usd), SUM(unpriced_events),
		       SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END)
		FROM usage_hourly %s GROUP BY hour, model ORDER BY hour, model`, hourlyTokens, hourlyTokens, where), args...)
	if err != nil {
		return nil, fmt.Errorf("hourly by model: %w", err)
	}
	defer rows.Close()
	var out []HourRow
	for rows.Next() {
		var r HourRow
		if err := rows.Scan(&r.Hour, &r.Model, &r.Events, &r.Tokens, &r.CostUSD, &r.Unpriced, &r.Sidechain); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Summary is the KPI strip's data: everything additive over a Filter.
type Summary struct {
	Events            int64   `json:"events"`
	Tokens            int64   `json:"tokens"`
	Sessions          int64   `json:"sessions"`
	CostUSD           float64 `json:"cost_usd"`
	Unpriced          int64   `json:"unpriced_events"`
	InputTokens       int64   `json:"input_tokens"`
	OutputTokens      int64   `json:"output_tokens"`
	CacheReadTokens   int64   `json:"cache_read_tokens"`
	CacheCreateTokens int64   `json:"cache_create_tokens"`
	ThinkingTokens    int64   `json:"thinking_tokens"`
	SidechainTokens   int64   `json:"sidechain_tokens"`
	SidechainEvents   int64   `json:"sidechain_events"`
}

func (s *Store) Summary(f Filter) (*Summary, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	var sum Summary
	err = s.db.QueryRow(fmt.Sprintf(`
		SELECT COALESCE(SUM(events),0), COALESCE(SUM%s,0), COUNT(DISTINCT session_id),
		       COALESCE(SUM(cost_usd),0), COALESCE(SUM(unpriced_events),0),
		       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0),
		       COALESCE(SUM(cache_create_5m_tokens + cache_create_1h_tokens),0), COALESCE(SUM(thinking_tokens),0),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),0),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN events ELSE 0 END),0)
		FROM usage_hourly %s`, hourlyTokens, hourlyTokens, where), args...).Scan(
		&sum.Events, &sum.Tokens, &sum.Sessions, &sum.CostUSD, &sum.Unpriced,
		&sum.InputTokens, &sum.OutputTokens, &sum.CacheReadTokens, &sum.CacheCreateTokens, &sum.ThinkingTokens,
		&sum.SidechainTokens, &sum.SidechainEvents)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	return &sum, nil
}

// SessionRow is one session as the sessions table shows it.
type SessionRow struct {
	SessionID   string    `json:"session_id"`
	AccountUUID string    `json:"account_uuid"`
	EndpointID  string    `json:"endpoint_id"`
	Endpoint    string    `json:"endpoint"`
	OSUser      string    `json:"os_user"`
	CWD         string    `json:"cwd"`
	Model       string    `json:"model"`  // the model with the most tokens
	Models      []string  `json:"models"` // every model seen, most tokens first
	Started     time.Time `json:"started"`
	Ended       time.Time `json:"ended"`
	Turns       int64     `json:"turns"`
	Tokens      int64     `json:"tokens"`
	CostUSD     float64   `json:"cost_usd"`
	Unpriced    int64     `json:"unpriced_events"`
	OutputTokens      int64 `json:"output_tokens"`
	InputTokens       int64 `json:"input_tokens"`
	CacheReadTokens   int64 `json:"cache_read_tokens"`
	CacheCreateTokens int64 `json:"cache_create_tokens"`
	SidechainTokens   int64 `json:"sidechain_tokens"`
	CacheHit       float64 `json:"cache_hit"`       // cache_read / (cache_read + input + cache_create)
	SidechainShare float64 `json:"sidechain_share"` // sidechain_tokens / tokens
}

var sessionSorts = map[string]string{
	"tokens":   "tokens DESC",
	"cost":     "cost_usd DESC",
	"started":  "started DESC",
	"duration": "(julianday(ended) - julianday(started)) DESC",
	"turns":    "turns DESC",
}

// Sessions lists sessions under a Filter, from the rollup. The Filter's
// Session field narrows to one session (used by Session).
func (s *Store) Sessions(f Filter, sortBy string, limit, offset int) ([]SessionRow, error) {
	order, ok := sessionSorts[sortBy]
	if sortBy == "" {
		order, ok = sessionSorts["tokens"], true
	}
	if !ok {
		return nil, fmt.Errorf("unknown sort %q", sortBy)
	}
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	q := fmt.Sprintf(`
		SELECT * FROM (
		  SELECT session_id, MAX(account_uuid) AS account_uuid, MAX(endpoint_id) AS endpoint_id,
		         MAX(os_user) AS os_user, MAX(cwd) AS cwd,
		         MIN(min_ts) AS started, MAX(max_ts) AS ended,
		         SUM(events) AS turns, SUM%s AS tokens, SUM(cost_usd) AS cost_usd, SUM(unpriced_events) AS unpriced,
		         SUM(output_tokens) AS output_tokens, SUM(input_tokens) AS input_tokens,
		         SUM(cache_read_tokens) AS cache_read, SUM(cache_create_5m_tokens + cache_create_1h_tokens) AS cache_create,
		         SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END) AS sidechain
		  FROM usage_hourly %s AND session_id != ''
		  GROUP BY session_id
		) ORDER BY %s LIMIT ? OFFSET ?`, hourlyTokens, hourlyTokens, where, order)
	rows, err := s.db.Query(q, append(args, limit, offset)...)
	if err != nil {
		return nil, fmt.Errorf("sessions: %w", err)
	}
	defer rows.Close()
	var out []SessionRow
	var ids []string
	for rows.Next() {
		var r SessionRow
		var started, ended string
		if err := rows.Scan(&r.SessionID, &r.AccountUUID, &r.EndpointID, &r.OSUser, &r.CWD, &started, &ended,
			&r.Turns, &r.Tokens, &r.CostUSD, &r.Unpriced, &r.OutputTokens, &r.InputTokens,
			&r.CacheReadTokens, &r.CacheCreateTokens, &r.SidechainTokens); err != nil {
			return nil, err
		}
		r.Started, _ = time.Parse(rfc, started)
		r.Ended, _ = time.Parse(rfc, ended)
		if d := r.CacheReadTokens + r.InputTokens + r.CacheCreateTokens; d > 0 {
			r.CacheHit = float64(r.CacheReadTokens) / float64(d)
		}
		if r.Tokens > 0 {
			r.SidechainShare = float64(r.SidechainTokens) / float64(r.Tokens)
		}
		out = append(out, r)
		ids = append(ids, r.SessionID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := s.fillSessionModels(f.Account, out, ids); err != nil {
		return nil, err
	}
	s.labelSessionEndpoints(out)
	return out, nil
}

// fillSessionModels sets Model/Models for a page of sessions in one query.
func (s *Store) fillSessionModels(account string, rows []SessionRow, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	ph := strings.TrimRight(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, 0, len(ids)+1)
	where := "WHERE session_id IN (" + ph + ")"
	if account != AllAccounts {
		where = "WHERE account_uuid = ? AND session_id IN (" + ph + ")"
		args = append(args, account)
	}
	for _, id := range ids {
		args = append(args, id)
	}
	res, err := s.db.Query(fmt.Sprintf(`SELECT session_id, model, SUM%s AS t FROM usage_hourly %s
		GROUP BY session_id, model ORDER BY session_id, t DESC`, hourlyTokens, where), args...)
	if err != nil {
		return fmt.Errorf("session models: %w", err)
	}
	defer res.Close()
	models := map[string][]string{}
	for res.Next() {
		var id, m string
		var t int64
		if err := res.Scan(&id, &m, &t); err != nil {
			return err
		}
		models[id] = append(models[id], m)
	}
	for i := range rows {
		rows[i].Models = models[rows[i].SessionID]
		if len(rows[i].Models) > 0 {
			rows[i].Model = rows[i].Models[0]
		}
	}
	return res.Err()
}

func (s *Store) labelSessionEndpoints(rows []SessionRow) {
	eps, err := s.ListEndpoints("")
	if err != nil {
		return
	}
	byID := map[string]string{}
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		byID[e.ID] = label
	}
	for i := range rows {
		rows[i].Endpoint = byID[rows[i].EndpointID]
	}
}

// Session returns one session's header row, or nil when unknown.
func (s *Store) Session(account, id string) (*SessionRow, error) {
	f := Filter{Account: account, Session: id,
		Start: time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC), End: time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC)}
	rows, err := s.Sessions(f, "tokens", 1, 0)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// Turn is one API call inside a session, from the raw events.
type Turn struct {
	TS                time.Time `json:"ts"`
	Model             string    `json:"model"`
	Effort            string    `json:"effort"`
	InputTokens       int64     `json:"input_tokens"`
	OutputTokens      int64     `json:"output_tokens"`
	CacheReadTokens   int64     `json:"cache_read_tokens"`
	CacheCreateTokens int64     `json:"cache_create_tokens"`
	ThinkingTokens    int64     `json:"thinking_tokens"`
	CostUSD           *float64  `json:"cost_usd"`
	IsSidechain       bool      `json:"is_sidechain"`
}

// SessionTurns lists a session's turns oldest first. Empty when the raw events
// were pruned; the caller reports that rather than showing an empty chart.
func (s *Store) SessionTurns(account, id string) ([]Turn, error) {
	where, args := "WHERE session_id = ?", []any{id}
	if account != AllAccounts {
		where, args = "WHERE account_uuid = ? AND session_id = ?", []any{account, id}
	}
	rows, err := s.db.Query(`SELECT ts, model, effort, input_tokens, output_tokens, cache_read_tokens,
		cache_create_5m_tokens + cache_create_1h_tokens, thinking_tokens, cost_usd, is_sidechain
		FROM usage_events `+where+` ORDER BY ts`, args...)
	if err != nil {
		return nil, fmt.Errorf("session turns: %w", err)
	}
	defer rows.Close()
	var out []Turn
	for rows.Next() {
		var t Turn
		var ts string
		var cost sql.NullFloat64
		var side int
		if err := rows.Scan(&ts, &t.Model, &t.Effort, &t.InputTokens, &t.OutputTokens, &t.CacheReadTokens,
			&t.CacheCreateTokens, &t.ThinkingTokens, &cost, &side); err != nil {
			return nil, err
		}
		t.TS, _ = time.Parse(rfc, ts)
		if cost.Valid {
			c := cost.Float64
			t.CostUSD = &c
		}
		t.IsSidechain = side == 1
		out = append(out, t)
	}
	return out, rows.Err()
}

var _ = sort.Strings // keep the import honest if the model ordering above changes
var _ model.UsageEvent
```

Remove the two trailing `var _` lines if `sort` / `model` end up unused (gofmt/vet will tell you); they are placeholders for the compiler only.

- [ ] **Step 5: Implement `limits_history.go`**

```go
// internal/store/limits_history.go
package store

import (
	"fmt"
	"time"
)

// LimitPoint is one utilization observation.
type LimitPoint struct {
	AccountUUID string    `json:"account_uuid"`
	T           time.Time `json:"t"`
	FiveHour    float64   `json:"five_hour_pct"`
	SevenDay    float64   `json:"seven_day_pct"`
}

// LimitsHistory returns every snapshot in [start, end) for one account or all,
// ordered by account then time. Several endpoints may observe the same account;
// their readings agree (the figure is account-wide) and are all returned.
func (s *Store) LimitsHistory(account string, start, end time.Time) ([]LimitPoint, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required")
	}
	q := `SELECT account_uuid, observed_at, five_hour_pct, seven_day_pct FROM limit_snapshots
	      WHERE ` + accountClause(account) + ` observed_at >= ? AND observed_at < ?
	      ORDER BY account_uuid, observed_at`
	rows, err := s.db.Query(q, accountArgs(account, fmtTime(start), fmtTime(end))...)
	if err != nil {
		return nil, fmt.Errorf("limits history: %w", err)
	}
	defer rows.Close()
	var out []LimitPoint
	for rows.Next() {
		var p LimitPoint
		var at string
		if err := rows.Scan(&p.AccountUUID, &at, &p.FiveHour, &p.SevenDay); err != nil {
			return nil, err
		}
		p.T, _ = time.Parse(rfc, at)
		out = append(out, p)
	}
	return out, rows.Err()
}
```

- [ ] **Step 6: Run the store tests**

Run: `go test ./internal/store -v 2>&1 | tail -30`
Expected: all PASS. If `TestSessionsAndTurns` fails on `Models`, check the ORDER BY in `fillSessionModels` (most tokens first within a session).

- [ ] **Step 7: Commit**

```bash
git add internal/store
git commit -m "feat(store): rollup-backed usage, hourly-by-model, summary, sessions, turns and limits history"
```

---

### Task 4: rollup equivalence property test

**Files:**
- Test: `internal/store/rollup_equiv_test.go`

**Interfaces:** consumes Tasks 1–3.

- [ ] **Step 1: Write the test**

```go
// internal/store/rollup_equiv_test.go
package store

import (
	"fmt"
	"math/rand"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// The rollup must agree with the raw events for every filter and every
// hour-aligned range. If this ever fails, the rollup is lying to the dashboard.
func TestRollupEquivalence(t *testing.T) {
	s := openTemp(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	seedAccount(t, s, "acct-b", "ep-b1")
	rng := rand.New(rand.NewSource(42))
	base := time.Date(2026, 8, 20, 0, 0, 0, 0, time.UTC)
	accounts := []string{"acct-a", "acct-b"}
	eps := map[string]string{"acct-a": "ep-a1", "acct-b": "ep-b1"}
	models := []string{"claude-opus-5", "claude-haiku-4-5", "claude-fable-5-1"}
	cwds := []string{"/p/one", "/p/two", "/p/three"}
	var evs []model.UsageEvent
	for i := 0; i < 600; i++ {
		acct := accounts[rng.Intn(2)]
		e := ev(acct, eps[acct], fmt.Sprintf("u-%d", i), int64(rng.Intn(500)))
		e.TS = base.Add(time.Duration(rng.Intn(10*24*60)) * time.Minute)
		e.SessionID = fmt.Sprintf("s-%d", rng.Intn(25))
		e.Model, e.CWD = models[rng.Intn(3)], cwds[rng.Intn(3)]
		e.GitBranch = []string{"main", "feat"}[rng.Intn(2)]
		e.OSUser = []string{"u1", "u2"}[rng.Intn(2)]
		e.Effort = []string{"xhigh", "high", ""}[rng.Intn(3)]
		e.InputTokens, e.CacheRead = int64(rng.Intn(50)), int64(rng.Intn(5000))
		e.IsSidechain = rng.Intn(6) == 0
		if e.Model == "claude-fable-5-1" {
			e.CostUSD = nil
		}
		evs = append(evs, e)
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	dims := []Dimension{ByEndpoint, ByProject, BySession, ByModel, ByBranch, ByUser, ByAccount}
	for trial := 0; trial < 40; trial++ {
		f := Filter{Account: []string{"acct-a", "acct-b", AllAccounts}[rng.Intn(3)]}
		h1, h2 := rng.Intn(240), rng.Intn(240)
		if h1 > h2 {
			h1, h2 = h2, h1
		}
		f.Start, f.End = base.Add(time.Duration(h1)*time.Hour), base.Add(time.Duration(h2+1)*time.Hour)
		switch rng.Intn(5) {
		case 0:
			f.Model = models[rng.Intn(3)]
		case 1:
			f.CWD = cwds[rng.Intn(3)]
		case 2:
			f.OSUser = "u1"
		case 3:
			f.Session = fmt.Sprintf("s-%d", rng.Intn(25))
		}
		d := dims[rng.Intn(len(dims))]
		got, err := s.UsageByFiltered(f, d, 100)
		if err != nil {
			t.Fatal(err)
		}
		want, err := s.usageByEventsFiltered(f, d)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != len(want) {
			t.Fatalf("trial %d %+v by %s: rollup %d rows, events %d rows", trial, f, d, len(got), len(want))
		}
		for i := range got {
			g, w := got[i], want[i]
			if g.Key != w.Key || g.Events != w.Events || g.Tokens != w.Tokens || g.Unpriced != w.Unpriced ||
				g.Sidechain != w.Sidechain || fmt.Sprintf("%.6f", g.CostUSD) != fmt.Sprintf("%.6f", w.CostUSD) {
				t.Fatalf("trial %d %+v by %s row %d: rollup %+v vs events %+v", trial, f, d, i, g, w)
			}
		}
	}
}

// usageByEventsFiltered is the oracle: the same aggregate straight off usage_events.
func (s *Store) usageByEventsFiltered(f Filter, d Dimension) ([]Bucket, error) {
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	where, args, err := f.where("ts")
	if err != nil {
		return nil, err
	}
	q := fmt.Sprintf(`SELECT %s AS k, COUNT(*), %s, COALESCE(SUM(cost_usd),0),
		SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END),
		COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN input_tokens + output_tokens + cache_create_5m_tokens
		  + cache_create_1h_tokens + cache_read_tokens ELSE 0 END),0)
		FROM usage_events %s GROUP BY k ORDER BY 3 DESC, k LIMIT 100`, col, tokenSumExpr, where)
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Bucket
	for rows.Next() {
		var b Bucket
		if err := rows.Scan(&b.Key, &b.Events, &b.Tokens, &b.CostUSD, &b.Unpriced, &b.Sidechain); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}
```

Ties in `ORDER BY 3 DESC` can order rows differently between the two queries; if the test flakes on equal-token rows, add `, k` to the rollup query's ORDER BY in `UsageByFiltered` (the API does not care about tie order).

- [ ] **Step 2: Run it**

Run: `go test ./internal/store -run TestRollupEquivalence -v`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add internal/store/rollup_equiv_test.go internal/store/rollup_query.go
git commit -m "test(store): rollup equals raw events for random filters and ranges"
```

---

### Task 5: API scope parsing, history folding, `/v1/usage` + `/v1/history` on the rollup

**Files:**
- Create: `internal/api/scope.go`
- Create: `internal/api/history.go`
- Modify: `internal/api/query.go` (`handleUsage`, `handleHistory`, `timeRange`)
- Test: `internal/api/scope_test.go`, `internal/api/history_test.go`

**Interfaces:**
- Consumes: `store.Filter`, `UsageByFiltered`, `HourlyByModel`, `requireAccount`, `parseWhen`, `writeJSON`, `httpError`.
- Produces:
  - `func (s *Server) scope(w http.ResponseWriter, r *http.Request) (store.Filter, bool)` — resolves account (as `requireAccount`), strict `since`/`until` (malformed ⇒ 400 and `false`), chips from `endpoint`,`user`,`project`,`model`,`branch`,`team`,`session`; the returned filter is **hour-aligned**.
  - `func wantsCompare(r *http.Request) bool` (`compare=1`).
  - `type Series struct{ Key string; Events, Tokens int64; CostUSD float64; Unpriced, Sidechain int64; Stack []store.Bucket }` (json: `key, events, tokens, cost_usd, unpriced_events, sidechain_tokens, stack,omitempty`).
  - `func foldHours(rows []store.HourRow, g string, stack bool, topModels []string) ([]Series, error)` — `g` ∈ `hour`, `6h`, `day`; keys `2026-09-02T06:00` (hour), `2026-09-02T06` (6h, bucket start 00/06/12/18), `2026-09-02` (day); with `stack`, each Series carries `Stack` = one Bucket per model in `topModels` order plus `other`, zero-filled.
  - `func topModels(rows []store.HourRow, n int) []string` — by total tokens desc.

- [ ] **Step 1: Write the failing tests**

```go
// internal/api/scope_test.go
package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

func TestScopeParsesChipsAndAlignsHours(t *testing.T) {
	h := newHarness(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/summary?account=all&since=2026-09-02T10:20:00Z&until=2026-09-02T12:05:00Z"+
		"&endpoint=ep1&user=u&project=%2Fp&model=m&branch=b&team=t&session=s", nil)
	f, ok := h.srv.scope(rec, req)
	if !ok {
		t.Fatalf("scope refused: %s", rec.Body.String())
	}
	if f.Account != store.AllAccounts || f.Endpoint != "ep1" || f.OSUser != "u" || f.CWD != "/p" ||
		f.Model != "m" || f.Branch != "b" || f.Team != "t" || f.Session != "s" {
		t.Fatalf("%+v", f)
	}
	if !f.Start.Equal(time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)) || !f.End.Equal(time.Date(2026, 9, 2, 13, 0, 0, 0, time.UTC)) {
		t.Fatalf("not hour-aligned: %v..%v", f.Start, f.End)
	}
}

func TestScopeRejectsMalformedTime(t *testing.T) {
	h := newHarness(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/summary?account=all&since=yesterday", nil)
	if _, ok := h.srv.scope(rec, req); ok || rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got ok=%v code=%d", ok, rec.Code)
	}
}
```

```go
// internal/api/history_test.go
package api

import (
	"testing"

	"github.com/verkyyi/ccquota/internal/store"
)

func hr(hour, model string, tokens int64) store.HourRow {
	return store.HourRow{Hour: hour, Model: model, Events: 1, Tokens: tokens}
}

func TestFoldHoursIntoSixHourBucketsWithStack(t *testing.T) {
	rows := []store.HourRow{
		hr("2026-09-02T05:00:00Z", "opus", 10),
		hr("2026-09-02T06:00:00Z", "opus", 20),
		hr("2026-09-02T07:00:00Z", "haiku", 5),
		hr("2026-09-02T07:00:00Z", "sonnet", 1),
	}
	top := topModels(rows, 2) // opus, haiku
	if len(top) != 2 || top[0] != "opus" || top[1] != "haiku" {
		t.Fatalf("top=%v", top)
	}
	out, err := foldHours(rows, "6h", true, top)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 || out[0].Key != "2026-09-02T00" || out[1].Key != "2026-09-02T06" {
		t.Fatalf("%+v", out)
	}
	if out[1].Tokens != 26 || out[1].Events != 3 {
		t.Fatalf("%+v", out[1])
	}
	// stack: opus 20, haiku 5, other 1 — every series has all three entries
	st := out[1].Stack
	if len(st) != 3 || st[0].Key != "opus" || st[0].Tokens != 20 || st[1].Tokens != 5 || st[2].Key != "other" || st[2].Tokens != 1 {
		t.Fatalf("stack=%+v", st)
	}
	if len(out[0].Stack) != 3 || out[0].Stack[1].Tokens != 0 {
		t.Fatalf("zero-filled stack expected: %+v", out[0].Stack)
	}
	if _, err := foldHours(rows, "week", false, nil); err == nil {
		t.Fatal("unknown granularity must be refused")
	}
	day, _ := foldHours(rows, "day", false, nil)
	if len(day) != 1 || day[0].Key != "2026-09-02" || day[0].Tokens != 36 {
		t.Fatalf("day=%+v", day)
	}
	hour, _ := foldHours(rows, "hour", false, nil)
	if len(hour) != 3 || hour[0].Key != "2026-09-02T05:00" {
		t.Fatalf("hour=%+v", hour)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/api -run 'TestScope|TestFoldHours' -v`
Expected: FAIL — undefined `scope`, `foldHours`.

- [ ] **Step 3: Implement `scope.go`**

```go
// internal/api/scope.go
package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// scope resolves the subscription, the range and the drill-down chips of a
// Review request. Malformed times are a 400: silently substituting a default
// range for a typo is how a dashboard shows the wrong week with confidence.
//
// The range is widened to whole hours because the rollup cannot split one.
func (s *Server) scope(w http.ResponseWriter, r *http.Request) (store.Filter, bool) {
	account, ok := s.requireAccount(w, r)
	if !ok {
		return store.Filter{}, false
	}
	q := r.URL.Query()
	now := time.Now().UTC()
	end := now
	if v := q.Get("until"); v != "" {
		t, ok := parseWhen(v, now)
		if !ok {
			httpError(w, http.StatusBadRequest, "until: want RFC3339 or a relative duration like 7d")
			return store.Filter{}, false
		}
		end = t
	}
	start := end.Add(-defaultRange)
	if v := q.Get("since"); v != "" {
		t, ok := parseWhen(v, now)
		if !ok {
			httpError(w, http.StatusBadRequest, "since: want RFC3339 or a relative duration like 7d")
			return store.Filter{}, false
		}
		start = t
	}
	if !start.Before(end) {
		httpError(w, http.StatusBadRequest, "since must be before until")
		return store.Filter{}, false
	}
	f := store.Filter{
		Account: account, Start: start, End: end,
		Endpoint: q.Get("endpoint"), OSUser: q.Get("user"), CWD: q.Get("project"),
		Model: q.Get("model"), Branch: q.Get("branch"), Team: q.Get("team"), Session: q.Get("session"),
	}
	return f.AlignHours(), true
}

func wantsCompare(r *http.Request) bool { return r.URL.Query().Get("compare") == "1" }
```

- [ ] **Step 4: Implement `history.go`**

```go
// internal/api/history.go
package api

import (
	"fmt"
	"sort"
	"strconv"

	"github.com/verkyyi/ccquota/internal/store"
)

// Series is one bucket of a time series, optionally stacked by model.
type Series struct {
	Key       string         `json:"key"`
	Events    int64          `json:"events"`
	Tokens    int64          `json:"tokens"`
	CostUSD   float64        `json:"cost_usd"`
	Unpriced  int64          `json:"unpriced_events"`
	Sidechain int64          `json:"sidechain_tokens"`
	Stack     []store.Bucket `json:"stack,omitempty"`
}

// bucketKey maps an hour key 'YYYY-MM-DDTHH:00:00Z' to the bucket it falls in.
func bucketKey(hour, g string) (string, error) {
	if len(hour) < 13 {
		return "", fmt.Errorf("bad hour key %q", hour)
	}
	switch g {
	case "hour":
		return hour[:13] + ":00", nil
	case "6h":
		h, err := strconv.Atoi(hour[11:13])
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%sT%02d", hour[:10], (h/6)*6), nil
	case "day":
		return hour[:10], nil
	}
	return "", fmt.Errorf("unknown granularity %q (want hour, 6h or day)", g)
}

// topModels ranks models by tokens, most first.
func topModels(rows []store.HourRow, n int) []string {
	tot := map[string]int64{}
	for _, r := range rows {
		tot[r.Model] += r.Tokens
	}
	names := make([]string, 0, len(tot))
	for m := range tot {
		names = append(names, m)
	}
	sort.Slice(names, func(i, j int) bool {
		if tot[names[i]] != tot[names[j]] {
			return tot[names[i]] > tot[names[j]]
		}
		return names[i] < names[j]
	})
	if len(names) > n {
		names = names[:n]
	}
	return names
}

// foldHours sums hourly rows into buckets of granularity g, oldest first. With
// stack, every bucket carries one entry per model in top plus "other", in that
// order and zero-filled, so a client can draw the stack without joining.
func foldHours(rows []store.HourRow, g string, stack bool, top []string) ([]Series, error) {
	if _, err := bucketKey("2000-01-01T00:00:00Z", g); err != nil {
		return nil, err
	}
	idx := map[string]int{}
	var out []Series
	pos := map[string]int{}
	for i, m := range top {
		pos[m] = i
	}
	for _, r := range rows {
		k, err := bucketKey(r.Hour, g)
		if err != nil {
			return nil, err
		}
		i, ok := idx[k]
		if !ok {
			i = len(out)
			idx[k] = i
			s := Series{Key: k}
			if stack {
				for _, m := range top {
					s.Stack = append(s.Stack, store.Bucket{Key: m})
				}
				s.Stack = append(s.Stack, store.Bucket{Key: "other"})
			}
			out = append(out, s)
		}
		s := &out[i]
		s.Events += r.Events
		s.Tokens += r.Tokens
		s.CostUSD += r.CostUSD
		s.Unpriced += r.Unpriced
		s.Sidechain += r.Sidechain
		if stack {
			j, ok := pos[r.Model]
			if !ok {
				j = len(top)
			}
			s.Stack[j].Tokens += r.Tokens
			s.Stack[j].Events += r.Events
			s.Stack[j].CostUSD += r.CostUSD
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
```

- [ ] **Step 5: Route `/v1/usage` and `/v1/history` through the rollup**

Replace the bodies of `handleUsage` and `handleHistory` in `internal/api/query.go`:

```go
func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	dim := store.Dimension(q.Get("by"))
	if dim == "" {
		dim = store.ByEndpoint
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	buckets, err := s.Store.UsageByFiltered(f, dim, limit)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if wantsCompare(r) {
		prev, err := s.Store.UsageByFiltered(f.Prev(), dim, 500)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		byKey := map[string]store.Bucket{}
		for _, b := range prev {
			byKey[b.Key] = b
		}
		for i := range buckets {
			if p, ok := byKey[buckets[i].Key]; ok {
				buckets[i].PrevEvents, buckets[i].PrevTokens, buckets[i].PrevCostUSD = p.Events, p.Tokens, p.CostUSD
			}
		}
	}
	if buckets == nil {
		buckets = []store.Bucket{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": f.Account,
		"all_accounts": f.Account == store.AllAccounts,
		"by":           string(dim),
		"since":        f.Start,
		"until":        f.End,
		"buckets":      buckets,
		"disclaimer":   shareDisclaimer,
		"scope_note":   scopeNote(f.Account),
	})
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	g := q.Get("granularity")
	if g == "" {
		g = "day"
	}
	rows, err := s.Store.HourlyByModel(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	stack := q.Get("stack") == "model"
	top := topModels(rows, 6)
	series, err := foldHours(rows, g, stack, top)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	models, err := s.Store.UsageByFiltered(f, store.ByModel, 50)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if series == nil {
		series = []Series{}
	}
	if models == nil {
		models = []store.Bucket{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": f.Account,
		"all_accounts": f.Account == store.AllAccounts,
		"granularity":  g,
		"since":        f.Start,
		"until":        f.End,
		"series":       series,
		"by_model":     models,
		"stack_models": append(top, "other"),
		"scope_note":   scopeNote(f.Account),
	})
}
```

The old `timeRange` stays for the other callers (`/v1/limits`, share, MCP).

- [ ] **Step 6: Run the API tests**

Run: `go test ./internal/api 2>&1 | tail -20`
Expected: PASS. Existing tests that assert `/v1/usage` or `/v1/history` output may need their expected `since`/`until` hour-aligned or their fixture events placed on whole hours; adjust the fixtures, not the alignment rule. The existing hour-granularity key format (`%Y-%m-%dT%H:00`) is preserved by `bucketKey`.

- [ ] **Step 7: Commit**

```bash
git add internal/api/scope.go internal/api/history.go internal/api/query.go internal/api/scope_test.go internal/api/history_test.go
git commit -m "feat(api): scope parsing with chips, hour folding with model stack; usage/history on the rollup"
```

---

### Task 6: `/v1/summary`, `/v1/sessions`, `/v1/sessions/{id}`, `/v1/limits/history`

**Files:**
- Create: `internal/api/limitshistory.go`
- Create: `internal/api/review.go`
- Modify: `internal/api/server.go` (routes)
- Test: `internal/api/limitshistory_test.go`, `internal/api/review_test.go`

**Interfaces:**
- Consumes: Task 3 store functions, `scope`, `wantsCompare`.
- Produces:
  - `type LimitSeries struct{ AccountUUID, Label string; Points []store.LimitPoint; CriticalSeconds, PrevCriticalSeconds int64; CriticalEpisodes int }` (json `account_uuid, label, points, critical_seconds, prev_critical_seconds, critical_episodes`).
  - `func downsample(pts []store.LimitPoint, start, end time.Time, n int) []store.LimitPoint` — one point per slot, the max `FiveHour` in the slot (its own timestamp and SevenDay kept).
  - `func criticalTime(pts []store.LimitPoint) (seconds int64, episodes int)` — gaps between consecutive points while the earlier is ≥ 90, each gap capped at 600 s; episode = a transition into ≥ 90 (the first point counts).
  - Routes: `/v1/summary`, `/v1/sessions`, `/v1/sessions/` (prefix, id after), `/v1/limits/history`.

- [ ] **Step 1: Write the failing tests**

```go
// internal/api/limitshistory_test.go
package api

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

func lp(min int, pct float64) store.LimitPoint {
	return store.LimitPoint{AccountUUID: "a", T: time.Date(2026, 9, 1, 10, min, 0, 0, time.UTC), FiveHour: pct, SevenDay: 1}
}

func TestCriticalTimeCapsGapsAndCountsEpisodes(t *testing.T) {
	pts := []store.LimitPoint{lp(0, 95), lp(2, 96), lp(30, 50), lp(31, 92), lp(33, 10)}
	secs, eps := criticalTime(pts)
	// 0→2 = 120s, 2→30 capped at 600s (a 28-minute polling hole is not 28 minutes of critical),
	// 31→33 = 120s; two episodes.
	if secs != 840 || eps != 2 {
		t.Fatalf("secs=%d eps=%d", secs, eps)
	}
	if s, e := criticalTime(nil); s != 0 || e != 0 {
		t.Fatal("empty")
	}
	if s, e := criticalTime([]store.LimitPoint{lp(0, 95)}); s != 0 || e != 1 {
		t.Fatalf("single critical point: secs=%d eps=%d", s, e)
	}
}

func TestDownsampleKeepsPeaks(t *testing.T) {
	var pts []store.LimitPoint
	for m := 0; m < 60; m++ {
		p := lp(m, 10)
		if m == 37 {
			p.FiveHour = 99
		}
		pts = append(pts, p)
	}
	start, end := pts[0].T, pts[0].T.Add(time.Hour)
	out := downsample(pts, start, end, 6)
	if len(out) != 6 {
		t.Fatalf("want 6 points, got %d", len(out))
	}
	if out[3].FiveHour != 99 || out[3].T.Minute() != 37 {
		t.Fatalf("peak lost: %+v", out[3])
	}
	if got := downsample(pts, start, end, 1000); len(got) != 60 {
		t.Fatalf("fewer points than slots must pass through: %d", len(got))
	}
}
```

```go
// internal/api/review_test.go
package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// seedReviewHarness pushes two sessions through the real ingest path.
func seedReviewHarness(t *testing.T, h *harness) {
	t.Helper()
	tok := h.enroll(t, "mac")
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	c := 1.5
	mk := func(uuid, session, cwd string, min int, out int64, priced bool) model.UsageEvent {
		e := model.UsageEvent{AccountUUID: "acct-a", EndpointID: "ep_mac", SessionID: session, MessageUUID: uuid,
			TS: base.Add(time.Duration(min) * time.Minute), Model: "claude-opus-5", OutputTokens: out, CacheRead: 900,
			CWD: cwd, OSUser: "verkyyi"}
		if priced {
			e.CostUSD = &c
		}
		return e
	}
	batch := model.Batch{Identity: testIdentity("acct-a"), Events: []model.UsageEvent{
		mk("1", "s-big", "/p/alpha", 0, 100, true), mk("2", "s-big", "/p/alpha", 30, 100, true),
		mk("3", "s-small", "/p/beta", 130, 20, false)}}
	if res := h.push(t, tok, batch); res.StatusCode != http.StatusOK {
		t.Fatalf("push: %d", res.StatusCode)
	}
}

func TestSummaryEndpoint(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	var got struct {
		Events, Sessions int64
		Prev             *struct{ Events int64 } `json:"prev"`
	}
	h.getJSON(t, "/v1/summary?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z&compare=1", &got)
	if got.Events != 3 || got.Sessions != 2 || got.Prev == nil || got.Prev.Events != 0 {
		t.Fatalf("%+v", got)
	}
}

func TestSessionsEndpoints(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	var rows []struct {
		SessionID string `json:"session_id"`
		Turns     int64  `json:"turns"`
		Endpoint  string `json:"endpoint"`
	}
	h.getJSON(t, "/v1/sessions?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z&project=%2Fp%2Falpha", &rows)
	if len(rows) != 1 || rows[0].SessionID != "s-big" || rows[0].Turns != 2 || rows[0].Endpoint != "mac" {
		t.Fatalf("%+v", rows)
	}
	var one struct {
		Session struct{ Turns int64 } `json:"session"`
		Turns   []struct{ Model string } `json:"turns"`
		Pruned  bool `json:"pruned"`
	}
	h.getJSON(t, "/v1/sessions/s-big?account=all", &one)
	if one.Session.Turns != 2 || len(one.Turns) != 2 || one.Pruned {
		t.Fatalf("%+v", one)
	}
	if code := h.getCode(t, "/v1/sessions/nope?account=all"); code != http.StatusNotFound {
		t.Fatalf("unknown session: %d", code)
	}
}

func TestLimitsHistoryEndpoint(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	at := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i, pct := range []float64{10, 95, 95, 20} {
		snap := &model.LimitsSnapshot{AccountUUID: "acct-a", EndpointID: "ep_mac", ObservedAt: at.Add(time.Duration(i) * time.Minute)}
		snap.FiveHour.Utilization = pct
		if err := h.srv.Store.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
	}
	var got struct {
		Accounts []struct {
			Points           []json.RawMessage `json:"points"`
			CriticalSeconds  int64             `json:"critical_seconds"`
			CriticalEpisodes int               `json:"critical_episodes"`
		} `json:"accounts"`
	}
	h.getJSON(t, "/v1/limits/history?account=all&since=2026-09-01T09:00:00Z&until=2026-09-01T11:00:00Z", &got)
	if len(got.Accounts) != 1 || len(got.Accounts[0].Points) != 4 || got.Accounts[0].CriticalSeconds != 120 || got.Accounts[0].CriticalEpisodes != 1 {
		t.Fatalf("%+v", got)
	}
}
```

`h.getJSON` / `h.getCode` / `testIdentity`: check `server_test.go` for existing helpers that GET with the viewer token (`grep -n 'func (h \*harness)' internal/api/*_test.go`). If none decode JSON, add to `server_test.go`:

```go
func (h *harness) getCode(t *testing.T, path string) int {
	t.Helper()
	req, _ := http.NewRequest("GET", h.http.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	return res.StatusCode
}

func (h *harness) getJSON(t *testing.T, path string, into any) {
	t.Helper()
	req, _ := http.NewRequest("GET", h.http.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: %d", path, res.StatusCode)
	}
	if err := json.NewDecoder(res.Body).Decode(into); err != nil {
		t.Fatal(err)
	}
}
```

and use whatever identity constructor the existing ingest tests use for `model.Batch.Identity` in place of `testIdentity` (look at how `push` callers build a batch in `server_test.go`).

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/api -run 'TestCriticalTime|TestDownsample|TestSummaryEndpoint|TestSessionsEndpoints|TestLimitsHistoryEndpoint' -v`
Expected: FAIL.

- [ ] **Step 3: Implement `limitshistory.go`**

```go
// internal/api/limitshistory.go
package api

import (
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

const criticalPct = 90.0

// maxCriticalGap caps how much time one snapshot can vouch for. Agents poll
// every two minutes; a gap far longer than that is an outage, not ten hours
// of critical.
const maxCriticalGap = 600 * time.Second

// LimitSeries is one subscription's utilization over a period.
type LimitSeries struct {
	AccountUUID         string             `json:"account_uuid"`
	Label               string             `json:"label"`
	Points              []store.LimitPoint `json:"points"`
	CriticalSeconds     int64              `json:"critical_seconds"`
	PrevCriticalSeconds int64              `json:"prev_critical_seconds"`
	CriticalEpisodes    int                `json:"critical_episodes"`
}

// criticalTime sums the time spent at or above criticalPct on the 5-hour
// window, and counts entries into that state.
func criticalTime(pts []store.LimitPoint) (int64, int) {
	var secs time.Duration
	episodes := 0
	in := false
	for i, p := range pts {
		hot := p.FiveHour >= criticalPct
		if hot && !in {
			episodes++
		}
		in = hot
		if hot && i+1 < len(pts) {
			gap := pts[i+1].T.Sub(p.T)
			if gap > maxCriticalGap {
				gap = maxCriticalGap
			}
			if gap > 0 {
				secs += gap
			}
		}
	}
	return int64(secs / time.Second), episodes
}

// downsample keeps at most n points: the range is cut into n slots and the
// point with the highest 5-hour reading in each slot survives, so a spike is
// never averaged away.
func downsample(pts []store.LimitPoint, start, end time.Time, n int) []store.LimitPoint {
	if n <= 0 || len(pts) <= n {
		return pts
	}
	slot := end.Sub(start) / time.Duration(n)
	if slot <= 0 {
		return pts
	}
	best := make([]*store.LimitPoint, n)
	for i := range pts {
		k := int(pts[i].T.Sub(start) / slot)
		if k < 0 {
			k = 0
		}
		if k >= n {
			k = n - 1
		}
		if best[k] == nil || pts[i].FiveHour > best[k].FiveHour {
			best[k] = &pts[i]
		}
	}
	out := make([]store.LimitPoint, 0, n)
	for _, b := range best {
		if b != nil {
			out = append(out, *b)
		}
	}
	return out
}
```

- [ ] **Step 4: Implement `review.go`**

```go
// internal/api/review.go
package api

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/verkyyi/ccquota/internal/store"
)

func (s *Server) handleSummary(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	sum, err := s.Store.Summary(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	effort, err := s.Store.UsageByFiltered(f, store.ByEffort, 10)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	entry, err := s.Store.UsageByFiltered(f, store.ByEntrypoint, 10)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := map[string]any{
		"account_uuid": f.Account, "all_accounts": f.Account == store.AllAccounts,
		"since": f.Start, "until": f.End,
		"events": sum.Events, "tokens": sum.Tokens, "sessions": sum.Sessions, "cost_usd": sum.CostUSD,
		"unpriced_events": sum.Unpriced, "input_tokens": sum.InputTokens, "output_tokens": sum.OutputTokens,
		"cache_read_tokens": sum.CacheReadTokens, "cache_create_tokens": sum.CacheCreateTokens,
		"thinking_tokens": sum.ThinkingTokens, "sidechain_tokens": sum.SidechainTokens,
		"sidechain_events": sum.SidechainEvents,
		"effort": nonNil(effort), "entrypoint": nonNil(entry),
		"disclaimer": shareDisclaimer, "scope_note": scopeNote(f.Account),
	}
	if wantsCompare(r) {
		prev, err := s.Store.Summary(f.Prev())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out["prev"] = prev
	}
	writeJSON(w, http.StatusOK, out)
}

func nonNil(b []store.Bucket) []store.Bucket {
	if b == nil {
		return []store.Bucket{}
	}
	return b
}

func (s *Server) handleSessions(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	rows, err := s.Store.Sessions(f, q.Get("sort"), limit, offset)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if rows == nil {
		rows = []store.SessionRow{}
	}
	writeJSON(w, http.StatusOK, rows)
}

// handleSession serves /v1/sessions/{id}: the header from the rollup and the
// turns from the raw events, which may have been pruned.
func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if id == "" {
		s.handleSessions(w, r)
		return
	}
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	head, err := s.Store.Session(account, id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if head == nil {
		httpError(w, http.StatusNotFound, "unknown session")
		return
	}
	turns, err := s.Store.SessionTurns(account, id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if turns == nil {
		turns = []store.Turn{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session": head,
		"turns":   turns,
		"pruned":  len(turns) == 0 && head.Turns > 0,
	})
}

func (s *Server) handleLimitsHistory(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	n, _ := strconv.Atoi(r.URL.Query().Get("points"))
	if n <= 0 {
		n = 400
	}
	pts, err := s.Store.LimitsHistory(f.Account, f.Start, f.End)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	prev := f.Prev()
	prevPts, err := s.Store.LimitsHistory(f.Account, prev.Start, prev.End)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	labels := s.accountLabels()
	byAcct := map[string]*LimitSeries{}
	var order []string
	for _, p := range pts {
		ls, ok := byAcct[p.AccountUUID]
		if !ok {
			ls = &LimitSeries{AccountUUID: p.AccountUUID, Label: labels[p.AccountUUID]}
			byAcct[p.AccountUUID] = ls
			order = append(order, p.AccountUUID)
		}
		ls.Points = append(ls.Points, p)
	}
	prevByAcct := map[string][]store.LimitPoint{}
	for _, p := range prevPts {
		prevByAcct[p.AccountUUID] = append(prevByAcct[p.AccountUUID], p)
	}
	out := make([]LimitSeries, 0, len(order))
	for _, a := range order {
		ls := byAcct[a]
		ls.CriticalSeconds, ls.CriticalEpisodes = criticalTime(ls.Points)
		ls.PrevCriticalSeconds, _ = criticalTime(prevByAcct[a])
		ls.Points = downsample(ls.Points, f.Start, f.End, n)
		out = append(out, *ls)
	}
	writeJSON(w, http.StatusOK, map[string]any{"since": f.Start, "until": f.End, "accounts": out})
}

// accountLabels maps uuid -> the display label the rest of the API uses.
func (s *Server) accountLabels() map[string]string {
	out := map[string]string{}
	accts, err := s.Store.ListAccounts()
	if err != nil {
		return out
	}
	for _, a := range accts {
		out[a.AccountUUID] = a.Label()
	}
	return out
}
```

Register in `server.go` next to the other viewer routes:

```go
	mux.Handle("/v1/summary", s.viewerOnly(http.HandlerFunc(s.handleSummary)))
	mux.Handle("/v1/sessions", s.viewerOnly(http.HandlerFunc(s.handleSessions)))
	mux.Handle("/v1/sessions/", s.viewerOnly(http.HandlerFunc(s.handleSession)))
	mux.Handle("/v1/limits/history", s.viewerOnly(http.HandlerFunc(s.handleLimitsHistory)))
```

`/v1/limits/history` must be registered — `net/http`'s mux picks the longest matching pattern, so the existing `/v1/limits` exact route is unaffected.

- [ ] **Step 5: Run the API tests**

Run: `go test ./internal/api 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/api
git commit -m "feat(api): summary, sessions, session detail and limits history endpoints"
```

---

### Task 7: findings engine (pure rules)

**Files:**
- Create: `internal/findings/findings.go`
- Test: `internal/findings/findings_test.go`

**Interfaces:**
- Produces:
  ```go
  type Finding struct{ Severity, Kind, Title, Detail string; Scope map[string]string; Link string }
  type SessionStat struct{ SessionID, CWD, Model string; Tokens, Turns int64; Duration time.Duration }
  type ModelStat struct{ Model string; Tokens, Unpriced int64 }
  type AccountCritical struct{ Label string; Seconds, PrevSeconds int64; Episodes int }
  type ProjectStat struct{ CWD string; Turns int64; CacheHit float64; Tokens, PrevTokens int64 }
  type Inputs struct{ Sessions []SessionStat; Models []ModelStat; Critical []AccountCritical; SelectionSeconds int64; Projects, PrevProjects []ProjectStat; Tokens, PrevTokens int64 }
  type WindowStat struct{ Label string; FiveHourPct float64 }
  type EndpointSeen struct{ Label string; LastSeen *time.Time }
  type LiveStat struct{ SessionID, CWD string; Tokens int64 }
  type NowInputs struct{ Windows []WindowStat; Endpoints []EndpointSeen; Live []LiveStat; Now time.Time }
  func Review(in Inputs) []Finding
  func Now(in NowInputs) []Finding
  ```
  Severities: `critical`, `warning`, `info`. Kinds as in spec §7. Output sorted critical → warning → info, then by magnitude, capped at 8.

- [ ] **Step 1: Write the failing tests**

```go
// internal/findings/findings_test.go
package findings

import (
	"strings"
	"testing"
	"time"
)

func sessions(tokens ...int64) []SessionStat {
	var out []SessionStat
	for i, t := range tokens {
		out = append(out, SessionStat{SessionID: "s" + string(rune('a'+i)), CWD: "/p/x", Model: "claude-opus-5",
			Tokens: t, Turns: 3, Duration: 90 * time.Minute})
	}
	return out
}

func kinds(fs []Finding) string {
	var k []string
	for _, f := range fs {
		k = append(k, f.Kind)
	}
	return strings.Join(k, ",")
}

func TestRunawaySession(t *testing.T) {
	// median of 10,10,10,10 = 10 -> threshold max(200, 100M) = 100M
	in := Inputs{Sessions: append(sessions(10, 10, 10, 10), SessionStat{SessionID: "big", CWD: "/p/y", Model: "m",
		Tokens: 150_000_000, Turns: 400, Duration: 6 * time.Hour})}
	fs := Review(in)
	if kinds(fs) != "runaway_session" || fs[0].Severity != "critical" || fs[0].Scope["session"] != "big" {
		t.Fatalf("%+v", fs)
	}
	if !strings.Contains(fs[0].Title, "150.0M") || !strings.Contains(fs[0].Detail, "6h 0m") {
		t.Fatalf("wording: %+v", fs[0])
	}
	// mutation: the big session shrunk below the absolute floor -> nothing fires
	in.Sessions[4].Tokens = 99_000_000
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
	// relative rule: 25x median but under the floor still does not fire
	in.Sessions = append(sessions(1_000_000, 1_000_000, 1_000_000), SessionStat{SessionID: "x", Tokens: 25_000_000})
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("floor: %+v", fs)
	}
}

func TestUnpricedModel(t *testing.T) {
	in := Inputs{Models: []ModelStat{{Model: "claude-fable-5-1", Tokens: 3_300_000_000, Unpriced: 9104}, {Model: "claude-opus-5", Tokens: 1}}}
	fs := Review(in)
	if kinds(fs) != "unpriced_model" || fs[0].Severity != "warning" || fs[0].Scope["model"] != "claude-fable-5-1" {
		t.Fatalf("%+v", fs)
	}
	in.Models[0].Unpriced = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestTimeInCritical(t *testing.T) {
	in := Inputs{SelectionSeconds: 7 * 86400, Critical: []AccountCritical{{Label: "a@x", Seconds: 3600, PrevSeconds: 0, Episodes: 2}}}
	fs := Review(in)
	if kinds(fs) != "time_in_critical" || fs[0].Severity != "warning" || !strings.Contains(fs[0].Title, "1h 0m") {
		t.Fatalf("%+v", fs)
	}
	in.Critical[0].Seconds = 7 * 86400 / 5 // 20% of the selection
	if fs := Review(in); fs[0].Severity != "critical" {
		t.Fatalf("20%% of the period must be critical: %+v", fs)
	}
	in.Critical[0].Seconds = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestCacheHitDrop(t *testing.T) {
	in := Inputs{
		Projects:     []ProjectStat{{CWD: "/p/a", Turns: 500, CacheHit: 0.88}, {CWD: "/p/b", Turns: 50, CacheHit: 0.10}},
		PrevProjects: []ProjectStat{{CWD: "/p/a", Turns: 400, CacheHit: 0.97}, {CWD: "/p/b", Turns: 500, CacheHit: 0.95}},
	}
	fs := Review(in)
	// /p/b has too few turns in the current period; only /p/a fires
	if kinds(fs) != "cache_hit_drop" || fs[0].Scope["project"] != "/p/a" || fs[0].Severity != "info" {
		t.Fatalf("%+v", fs)
	}
	in.Projects[0].CacheHit = 0.93 // 4-point drop: under the 5-point threshold
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestSpendSpike(t *testing.T) {
	in := Inputs{Tokens: 3_000_000_000, PrevTokens: 1_000_000_000,
		Projects:     []ProjectStat{{CWD: "/p/a", Turns: 10, Tokens: 2_500_000_000, PrevTokens: 500_000_000}},
		PrevProjects: []ProjectStat{{CWD: "/p/a", Turns: 10, Tokens: 500_000_000}}}
	fs := Review(in)
	if kinds(fs) != "spend_spike,spend_spike" || fs[1].Scope["project"] != "/p/a" {
		t.Fatalf("%+v", fs)
	}
	in.Tokens = 1_400_000_000 // 1.4x: under 1.5x
	in.Projects[0].Tokens = 700_000_000
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
	in.Tokens, in.PrevTokens = 900_000_000, 100_000_000 // 9x but under the 1B floor
	in.Projects = nil
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("floor: %+v", fs)
	}
}

func TestOrderingAndCap(t *testing.T) {
	in := Inputs{SelectionSeconds: 86400,
		Models:   []ModelStat{{Model: "m", Unpriced: 1, Tokens: 1}},
		Critical: []AccountCritical{{Label: "a", Seconds: 50000, Episodes: 1}},
		Tokens:   5_000_000_000, PrevTokens: 1_000_000_000}
	fs := Review(in)
	if kinds(fs) != "time_in_critical,unpriced_model,spend_spike" {
		t.Fatalf("severity order: %s", kinds(fs))
	}
	var many []ModelStat
	for i := 0; i < 12; i++ {
		many = append(many, ModelStat{Model: "m" + string(rune('a'+i)), Unpriced: 1, Tokens: int64(i)})
	}
	if fs := Review(Inputs{Models: many}); len(fs) != 8 {
		t.Fatalf("cap at 8, got %d", len(fs))
	}
}

func TestNowFindings(t *testing.T) {
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	old := now.Add(-2 * time.Hour)
	in := NowInputs{Now: now,
		Windows:   []WindowStat{{Label: "a@x", FiveHourPct: 82}, {Label: "b@x", FiveHourPct: 95}, {Label: "c@x", FiveHourPct: 10}},
		Endpoints: []EndpointSeen{{Label: "macmini-zx", LastSeen: &old}, {Label: "fresh", LastSeen: &now}, {Label: "never"}},
		Live:      []LiveStat{{SessionID: "s1", CWD: "/p", Tokens: 250_000_000}, {SessionID: "s2", Tokens: 1000}}}
	fs := Now(in)
	if kinds(fs) != "window_high,window_high,stale_agent,stale_agent,live_runaway" {
		t.Fatalf("%s", kinds(fs))
	}
	if fs[0].Severity != "critical" || fs[1].Severity != "warning" || !strings.Contains(fs[0].Title, "b@x") {
		t.Fatalf("%+v", fs[:2])
	}
	in.Windows, in.Live = nil, nil
	in.Endpoints = []EndpointSeen{{Label: "fresh", LastSeen: &now}}
	if fs := Now(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/findings -v`
Expected: FAIL — package does not exist.

- [ ] **Step 3: Implement**

```go
// Package findings turns query results into a short list of things worth a
// look. Every rule is a pure function with a fixed threshold; the API layer
// gathers the inputs. No rule fires on absence of data.
package findings

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

type Finding struct {
	Severity string            `json:"severity"` // critical | warning | info
	Kind     string            `json:"kind"`
	Title    string            `json:"title"`
	Detail   string            `json:"detail"`
	Scope    map[string]string `json:"scope,omitempty"` // chips to apply (hash param names)
	Link     string            `json:"link,omitempty"`  // an in-app anchor, e.g. "#sessions"
	weight   float64
}

type SessionStat struct {
	SessionID, CWD, Model string
	Tokens, Turns         int64
	Duration              time.Duration
}
type ModelStat struct {
	Model            string
	Tokens, Unpriced int64
}
type AccountCritical struct {
	Label                string
	Seconds, PrevSeconds int64
	Episodes             int
}
type ProjectStat struct {
	CWD                string
	Turns              int64
	CacheHit           float64
	Tokens, PrevTokens int64
}
type Inputs struct {
	Sessions               []SessionStat
	Models                 []ModelStat
	Critical               []AccountCritical
	SelectionSeconds       int64
	Projects, PrevProjects []ProjectStat
	Tokens, PrevTokens     int64
}

const (
	runawayMultiple    = 20
	runawayFloor       = 100_000_000
	criticalShare      = 0.10
	cacheDropPoints    = 0.05
	cacheMinTurns      = 200
	spikeRatio         = 1.5
	spikeFloor         = 1_000_000_000
	maxFindings        = 8
	windowWarnPct      = 75.0
	windowCriticalPct  = 90.0
	staleAfter         = time.Hour
	liveRunawayTokens  = 200_000_000
)

var rank = map[string]int{"critical": 0, "warning": 1, "info": 2}

func finish(fs []Finding) []Finding {
	sort.SliceStable(fs, func(i, j int) bool {
		if rank[fs[i].Severity] != rank[fs[j].Severity] {
			return rank[fs[i].Severity] < rank[fs[j].Severity]
		}
		return fs[i].weight > fs[j].weight
	})
	if len(fs) > maxFindings {
		fs = fs[:maxFindings]
	}
	if fs == nil {
		fs = []Finding{}
	}
	return fs
}

// Review evaluates the period rules.
func Review(in Inputs) []Finding {
	var fs []Finding
	fs = append(fs, runaway(in.Sessions)...)
	fs = append(fs, unpriced(in.Models)...)
	fs = append(fs, critical(in.Critical, in.SelectionSeconds)...)
	fs = append(fs, cacheDrop(in.Projects, in.PrevProjects)...)
	fs = append(fs, spike(in)...)
	return finish(fs)
}

func runaway(ss []SessionStat) []Finding {
	if len(ss) == 0 {
		return nil
	}
	var toks []int64
	for _, s := range ss {
		if s.Turns >= 2 {
			toks = append(toks, s.Tokens)
		}
	}
	if len(toks) == 0 {
		return nil
	}
	sort.Slice(toks, func(i, j int) bool { return toks[i] < toks[j] })
	median := toks[len(toks)/2]
	threshold := median * runawayMultiple
	if threshold < runawayFloor {
		threshold = runawayFloor
	}
	var out []Finding
	for _, s := range ss {
		if s.Tokens < threshold {
			continue
		}
		mult := int64(0)
		if median > 0 {
			mult = s.Tokens / median
		}
		out = append(out, Finding{
			Severity: "critical", Kind: "runaway_session",
			Title:  fmt.Sprintf("session %s burned %s tokens — %d× the median session", short(s.SessionID), tokens(s.Tokens), mult),
			Detail: fmt.Sprintf("%s · %s · %s · %d turns", shortPath(s.CWD), s.Model, dur(s.Duration), s.Turns),
			Scope:  map[string]string{"session": s.SessionID},
			Link:   "#sessions",
			weight: float64(s.Tokens),
		})
	}
	return out
}

func unpriced(ms []ModelStat) []Finding {
	var out []Finding
	for _, m := range ms {
		if m.Unpriced <= 0 {
			continue
		}
		out = append(out, Finding{
			Severity: "warning", Kind: "unpriced_model",
			Title:  fmt.Sprintf("%s has no price: %s tokens over %d turns show as $0", m.Model, tokens(m.Tokens), m.Unpriced),
			Detail: "Spend totals under-count until the model is added to the pricing table.",
			Scope:  map[string]string{"model": m.Model},
			weight: float64(m.Tokens),
		})
	}
	return out
}

func critical(cs []AccountCritical, selectionSeconds int64) []Finding {
	var out []Finding
	for _, c := range cs {
		if c.Seconds <= 0 {
			continue
		}
		sev := "warning"
		if selectionSeconds > 0 && float64(c.Seconds) > criticalShare*float64(selectionSeconds) {
			sev = "critical"
		}
		out = append(out, Finding{
			Severity: sev, Kind: "time_in_critical",
			Title:  fmt.Sprintf("%s spent %s above 90%% of its 5-hour window", c.Label, dur(time.Duration(c.Seconds)*time.Second)),
			Detail: fmt.Sprintf("%d episode(s) · previous period %s", c.Episodes, dur(time.Duration(c.PrevSeconds)*time.Second)),
			Link:   "#wall-history",
			weight: float64(c.Seconds),
		})
	}
	return out
}

func cacheDrop(cur, prev []ProjectStat) []Finding {
	prevBy := map[string]ProjectStat{}
	for _, p := range prev {
		prevBy[p.CWD] = p
	}
	var out []Finding
	for _, p := range cur {
		q, ok := prevBy[p.CWD]
		if !ok || p.Turns < cacheMinTurns || q.Turns < cacheMinTurns {
			continue
		}
		drop := q.CacheHit - p.CacheHit
		if drop < cacheDropPoints {
			continue
		}
		out = append(out, Finding{
			Severity: "info", Kind: "cache_hit_drop",
			Title:  fmt.Sprintf("cache hit on %s fell %.0f%% → %.0f%%", shortPath(p.CWD), q.CacheHit*100, p.CacheHit*100),
			Detail: "Turns there re-read context instead of hitting cache; each turn costs more than it did.",
			Scope:  map[string]string{"project": p.CWD},
			weight: drop,
		})
	}
	return out
}

func spike(in Inputs) []Finding {
	var out []Finding
	if in.PrevTokens > 0 && in.Tokens >= spikeFloor && float64(in.Tokens) >= spikeRatio*float64(in.PrevTokens) {
		ratio := float64(in.Tokens) / float64(in.PrevTokens)
		out = append(out, Finding{
			Severity: "info", Kind: "spend_spike",
			Title:  fmt.Sprintf("tokens are %.1f× the previous period", ratio),
			Detail: fmt.Sprintf("%s vs %s", tokens(in.Tokens), tokens(in.PrevTokens)),
			weight: ratio,
		})
		var top *ProjectStat
		for i := range in.Projects {
			p := &in.Projects[i]
			if top == nil || p.Tokens > top.Tokens {
				top = p
			}
		}
		if top != nil && top.PrevTokens > 0 && float64(top.Tokens) >= spikeRatio*float64(top.PrevTokens) {
			r := float64(top.Tokens) / float64(top.PrevTokens)
			out = append(out, Finding{
				Severity: "info", Kind: "spend_spike",
				Title:  fmt.Sprintf("%s is %.1f× its previous period and the top contributor", shortPath(top.CWD), r),
				Detail: fmt.Sprintf("%s vs %s", tokens(top.Tokens), tokens(top.PrevTokens)),
				Scope:  map[string]string{"project": top.CWD},
				weight: r - 0.001, // just below the global one so it lists second
			})
		}
	}
	return out
}

// ---- Now ----

type WindowStat struct {
	Label       string
	FiveHourPct float64
}
type EndpointSeen struct {
	Label    string
	LastSeen *time.Time
}
type LiveStat struct {
	SessionID, CWD string
	Tokens         int64
}
type NowInputs struct {
	Windows   []WindowStat
	Endpoints []EndpointSeen
	Live      []LiveStat
	Now       time.Time
}

// Now evaluates the minute-scale rules.
func Now(in NowInputs) []Finding {
	var fs []Finding
	for _, w := range in.Windows {
		if w.FiveHourPct < windowWarnPct {
			continue
		}
		sev := "warning"
		if w.FiveHourPct >= windowCriticalPct {
			sev = "critical"
		}
		fs = append(fs, Finding{Severity: sev, Kind: "window_high",
			Title: fmt.Sprintf("%s is at %.0f%% of its 5-hour window", w.Label, w.FiveHourPct),
			Link:  "#wall", weight: w.FiveHourPct})
	}
	for _, e := range in.Endpoints {
		if e.LastSeen != nil && in.Now.Sub(*e.LastSeen) <= staleAfter {
			continue
		}
		title := fmt.Sprintf("%s has never reported", e.Label)
		w := float64(1 << 30)
		if e.LastSeen != nil {
			title = fmt.Sprintf("%s last reported %s ago", e.Label, dur(in.Now.Sub(*e.LastSeen)))
			w = in.Now.Sub(*e.LastSeen).Seconds()
		}
		fs = append(fs, Finding{Severity: "warning", Kind: "stale_agent", Title: title,
			Detail: "Its share of every total is under-counted until it returns.", Link: "#fleet", weight: w})
	}
	for _, l := range in.Live {
		if l.Tokens < liveRunawayTokens {
			continue
		}
		fs = append(fs, Finding{Severity: "warning", Kind: "live_runaway",
			Title:  fmt.Sprintf("live session %s has %s tokens in flight", short(l.SessionID), tokens(l.Tokens)),
			Detail: shortPath(l.CWD), Scope: map[string]string{"session": l.SessionID}, Link: "#live", weight: float64(l.Tokens)})
	}
	return finish(fs)
}

// ---- formatting shared by the templates ----

func tokens(n int64) string {
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.1fB", float64(n)/1e9)
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1e3)
	}
	return fmt.Sprintf("%d", n)
}

func dur(d time.Duration) string {
	d = d.Round(time.Minute)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	return fmt.Sprintf("%dh %dm", h, m)
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// shortPath keeps the last two segments; the last one is what tells sibling
// worktrees apart, so it is never the part that gets clipped.
func shortPath(p string) string {
	if p == "" {
		return "(unknown)"
	}
	parts := strings.FieldsFunc(strings.ReplaceAll(p, "\\", "/"), func(r rune) bool { return r == '/' })
	if len(parts) <= 2 {
		return p
	}
	return "…/" + strings.Join(parts[len(parts)-2:], "/")
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/findings -v`
Expected: PASS (7 tests). If `TestOrderingAndCap` fails on order, check that `weight` for `time_in_critical` (seconds) is set and that `finish` sorts by severity first.

- [ ] **Step 5: Commit**

```bash
git add internal/findings
git commit -m "feat(findings): deterministic review and now rules with fixed thresholds"
```

---

### Task 8: `/v1/findings`, live `os_user`, account scope on fleet lists, MCP tools

**Files:**
- Create: `internal/api/findings.go`
- Modify: `internal/api/live.go` (`LiveSession.OSUser`, filled in `Snapshot` via an endpoint→os_user map), `internal/api/server.go` (route), `internal/api/query.go` (`handleSwitches`, `handleEndpointAccounts`), `internal/store/query.go` (`AccountSwitches(account string, limit int)`, `EndpointAccounts(account string, limit int)`), `internal/mcp/mcp.go`
- Test: `internal/api/findings_test.go`, extend `internal/mcp/mcp_test.go`

**Interfaces:**
- Consumes: Task 7 types, `scope`, `LimitsAcross`/`LatestLimits` (existing, see `handleLimits` for how per-account limits are read), `ListEndpoints`, `liveStore().Snapshot()`.
- Produces: `GET /v1/findings?view=review|now` → `[]findings.Finding`; `LiveSession.OSUser string json:"os_user,omitempty"`; store signatures `AccountSwitches(account string, limit int)` and `EndpointAccounts(account string, limit int)` where `account == ""` or `AllAccounts` means all (switches match `from_account` or `to_account`; endpoint-accounts match `account_uuid`); MCP tools `usage_summary`, `list_sessions`, `get_session`, `get_findings`.

- [ ] **Step 1: Write the failing API test**

```go
// internal/api/findings_test.go
package api

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestFindingsReviewAndNow(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	var review []struct{ Kind, Severity string }
	h.getJSON(t, "/v1/findings?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z", &review)
	// s-small's one turn is unpriced (cost nil) -> unpriced_model must fire; nothing else has data
	if len(review) != 1 || review[0].Kind != "unpriced_model" {
		t.Fatalf("%+v", review)
	}
	// Now: the endpoint last reported at ingest (seconds ago) -> not stale; no windows, no live -> empty
	var now []struct{ Kind string }
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now) != 0 {
		t.Fatalf("%+v", now)
	}
	// make the endpoint stale
	old := time.Now().Add(-3 * time.Hour)
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET last_seen = ?`, old.UTC().Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now) != 1 || now[0].Kind != "stale_agent" {
		t.Fatalf("%+v", now)
	}
	_ = model.Batch{}
}
```

- [ ] **Step 2: Implement `findings.go` (API side)**

```go
// internal/api/findings.go
package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/store"
)

func (s *Server) handleFindings(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("view") == "now" {
		s.handleNowFindings(w, r)
		return
	}
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	in, err := s.gatherReview(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, findings.Review(in))
}

func (s *Server) gatherReview(f store.Filter) (findings.Inputs, error) {
	var in findings.Inputs
	in.SelectionSeconds = int64(f.End.Sub(f.Start) / time.Second)

	sessions, err := s.Store.Sessions(f, "tokens", 500, 0)
	if err != nil {
		return in, err
	}
	for _, sr := range sessions {
		in.Sessions = append(in.Sessions, findings.SessionStat{SessionID: sr.SessionID, CWD: sr.CWD, Model: sr.Model,
			Tokens: sr.Tokens, Turns: sr.Turns, Duration: sr.Ended.Sub(sr.Started)})
	}
	models, err := s.Store.UsageByFiltered(f, store.ByModel, 50)
	if err != nil {
		return in, err
	}
	for _, m := range models {
		in.Models = append(in.Models, findings.ModelStat{Model: m.Key, Tokens: m.Tokens, Unpriced: m.Unpriced})
	}
	pts, err := s.Store.LimitsHistory(f.Account, f.Start, f.End)
	if err != nil {
		return in, err
	}
	prev := f.Prev()
	prevPts, err := s.Store.LimitsHistory(f.Account, prev.Start, prev.End)
	if err != nil {
		return in, err
	}
	labels := s.accountLabels()
	byAcct := map[string][]store.LimitPoint{}
	var order []string
	for _, p := range pts {
		if _, ok := byAcct[p.AccountUUID]; !ok {
			order = append(order, p.AccountUUID)
		}
		byAcct[p.AccountUUID] = append(byAcct[p.AccountUUID], p)
	}
	prevBy := map[string][]store.LimitPoint{}
	for _, p := range prevPts {
		prevBy[p.AccountUUID] = append(prevBy[p.AccountUUID], p)
	}
	for _, a := range order {
		secs, eps := criticalTime(byAcct[a])
		prevSecs, _ := criticalTime(prevBy[a])
		in.Critical = append(in.Critical, findings.AccountCritical{Label: labels[a], Seconds: secs, PrevSeconds: prevSecs, Episodes: eps})
	}
	cur, err := s.Store.UsageByFiltered(f, store.ByProject, 50)
	if err != nil {
		return in, err
	}
	prevProj, err := s.Store.UsageByFiltered(prev, store.ByProject, 500)
	if err != nil {
		return in, err
	}
	prevTok := map[string]int64{}
	for _, p := range prevProj {
		prevTok[p.Key] = p.Tokens
		in.PrevProjects = append(in.PrevProjects, projectStat(p, 0))
	}
	for _, p := range cur {
		in.Projects = append(in.Projects, projectStat(p, prevTok[p.Key]))
	}
	sum, err := s.Store.Summary(f)
	if err != nil {
		return in, err
	}
	psum, err := s.Store.Summary(prev)
	if err != nil {
		return in, err
	}
	in.Tokens, in.PrevTokens = sum.Tokens, psum.Tokens
	return in, nil
}

func projectStat(b store.Bucket, prevTokens int64) findings.ProjectStat {
	var hit float64
	if d := b.CacheReadTokens + b.InputTokens + b.CacheCreateTokens; d > 0 {
		hit = float64(b.CacheReadTokens) / float64(d)
	}
	return findings.ProjectStat{CWD: b.Key, Turns: b.Events, CacheHit: hit, Tokens: b.Tokens, PrevTokens: prevTokens}
}

func (s *Server) handleNowFindings(w http.ResponseWriter, r *http.Request) {
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	in := findings.NowInputs{Now: time.Now().UTC()}
	accts, err := s.Store.ListAccounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, a := range accts {
		if account != store.AllAccounts && a.AccountUUID != account {
			continue
		}
		snap, err := s.Store.LatestLimits(a.AccountUUID)
		if err != nil || snap == nil {
			continue
		}
		in.Windows = append(in.Windows, findings.WindowStat{Label: a.Label(), FiveHourPct: snap.FiveHour.Utilization})
	}
	scopeAcct := account
	if scopeAcct == store.AllAccounts {
		scopeAcct = ""
	}
	eps, err := s.Store.ListEndpoints(scopeAcct)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		in.Endpoints = append(in.Endpoints, findings.EndpointSeen{Label: label, LastSeen: e.LastSeen})
	}
	for _, l := range s.liveStore().Snapshot().Sessions {
		if account != store.AllAccounts && l.Account != "" && l.Account != account {
			continue
		}
		in.Live = append(in.Live, findings.LiveStat{SessionID: l.SessionID, CWD: l.CWD, Tokens: l.InputTokens + l.OutputTokens})
	}
	writeJSON(w, http.StatusOK, findings.Now(in))
}
```

Check the exact field names on `store.Endpoint` (`ID`, `Label`, `Hostname`, `LastSeen *time.Time`) with `sed -n 85,116p internal/store/query.go` and `scanEndpoint` in `store.go`, and adapt. Register the route: `mux.Handle("/v1/findings", s.viewerOnly(http.HandlerFunc(s.handleFindings)))`.

- [ ] **Step 3: `os_user` on live sessions**

In `live.go`, add `OSUser string json:"os_user,omitempty"` to `LiveSession`. The `Live` struct has no store access; the server enriches: in `Snapshot()`'s caller path there is `Enrich(fn func(*Snapshot))` — register, where the hub wires `LiveStore` (in `cmd/ccquota/hub.go`), an enrich function that maps `EndpointID → os_user` from `ListEndpoints("")` (cache the map, refresh every 60 s). If `Enrich` is already used for the counter, chain the new function inside the same call.

- [ ] **Step 4: account scope on switches / endpoint-accounts**

`store.AccountSwitches(account string, limit int)`: when `account != "" && account != AllAccounts`, add `WHERE from_account = ? OR to_account = ?`. `store.EndpointAccounts(account string, limit int)`: add `WHERE account_uuid = ?` similarly. Update the two handlers to pass `r.URL.Query().Get("account")` (mapping `all` → `AllAccounts`), and update the MCP callers and any test callers (`grep -rn 'AccountSwitches(\|EndpointAccounts(' --include=*.go .`).

- [ ] **Step 5: MCP tools**

In `toolSpecs()` add four specs (same `accountProp`, `since`/`until` props as `usage_history`; extra props: chips as string props named `endpoint, user, project, model, branch, team, session`; `list_sessions` also `sort` and `limit`; `get_session` requires `session_id`; `get_findings` takes `view`):

- `usage_summary` — "Totals for a period under optional drill-down filters: tokens, notional cost, turns, sessions, token composition (cache read / create, input, output, thinking), subagent share, and the same for the previous period." Calls `Store.Summary(f)` and `Summary(f.Prev())`.
- `list_sessions` — "Sessions in a period, heaviest first by default …" Calls `Store.Sessions`.
- `get_session` — "One session's header and its turns." Calls `Store.Session` + `SessionTurns`.
- `get_findings` — "Machine-generated findings for a period (runaway sessions, unpriced models, time spent in the critical band, cache-hit drops, spend spikes), or `view: now` for live alerts." Calls `gatherReview` / the now gatherer — move the gather functions onto `*Server` (they already are) and call them from MCP via `s.api`.

Build the `store.Filter` in MCP from args with a helper `func (s *server) filter(args map[string]any) (store.Filter, error)` mirroring `scope()` (account via `s.account(args)`, times via `timeRange(args)`, chips via `str(args, name)`), then `AlignHours()`.

Add to `mcp_test.go` a test that `tools/list` contains the four names and that `usage_summary` on a seeded store returns `tokens > 0`.

- [ ] **Step 6: Run everything**

Run: `gofmt -l . && go vet ./... && go test -race ./... 2>&1 | tail -20`
Expected: no gofmt output, vet clean, all packages PASS.

- [ ] **Step 7: Commit**

```bash
git add -A internal cmd
git commit -m "feat(api,mcp): findings endpoint and tools, os_user on live sessions, account scope on fleet lists"
```

---

### Task 9: hub wiring — rollup log line, `--rebuild-rollup`, `Cache-Control` on UI assets

**Files:**
- Modify: `cmd/ccquota/hub.go`, `internal/api/server.go` (`serveUI`)

- [ ] **Step 1: hub.go**

After `store.Open`: `if st.BackfilledRollup > 0 { log.Printf("rollup: built %d hourly rows from usage_events", st.BackfilledRollup) }`. Add `rebuild := fs.Bool("rebuild-rollup", false, "rebuild the hourly rollup from raw events at startup, then continue")`; when set, call `st.RebuildRollup()` and log the count.

- [ ] **Step 2: serveUI**

Before `http.ServeContent`: `w.Header().Set("Cache-Control", "no-cache")`.

- [ ] **Step 3: Build and smoke**

Run: `cd ~/projects/ccquota && make build && ./bin/ccquota hub --db /tmp/ccq-smoke.db --no-auth --addr 127.0.0.1:8799 & sleep 2; curl -s 'http://127.0.0.1:8799/v1/summary?account=all' ; curl -sI http://127.0.0.1:8799/ | grep -i cache-control; kill %1`
Expected: a JSON summary (zeros) and `Cache-Control: no-cache`. (`--no-auth` is loopback-only; with no accounts `requireAccount` returns 404 "no subscriptions" — that is fine for the smoke, the JSON error shows the route is live.)

- [ ] **Step 4: Commit**

```bash
git add cmd/ccquota/hub.go internal/api/server.go
git commit -m "feat(hub): log rollup backfill, --rebuild-rollup, no-cache on dashboard assets"
```

---

### Task 10: frontend pure modules (`lib/`) with Node tests and a CI job

**Files:**
- Create: `web/package.json`, `web/dist/lib/state.js`, `web/dist/lib/brush.js`, `web/dist/lib/fold.js`, `web/dist/lib/format.js`, `web/dist/lib/seq.js`
- Test: `web/test/state.test.mjs`, `web/test/brush.test.mjs`, `web/test/fold.test.mjs`, `web/test/seq.test.mjs`
- Modify: `.github/workflows/ci.yml`, `Makefile` (`test` target also runs `node --test web/test/` when node exists)

**Interfaces (Produces):**

```js
// lib/state.js
export const DIMS = ['machine','login','project','model','branch','team','session'];
export const API_PARAM = { machine:'endpoint', login:'user', project:'project', model:'model', branch:'branch', team:'team', session:'session' };
export const DEFAULTS = { view:'now', session:null, sub:'all', span:'30d', from:null, to:null, chips:{}, g1:'project', g2:'model', sort:'tokens' };
export function parse(hash) → state            // never throws; unknown values fall back to DEFAULTS
export function format(state) → '#/…'          // omits defaults; chips sorted by DIMS order
export function withChip(state, dim, value) / withoutChip(state, dim) / clearChips(state) → new state
export function selection(state, now, resolve) → { from:ms, to:ms, live:bool }   // resolve = brush.defaultSelection-like fn injected to avoid a circular import
export function apiQuery(state, {from, to, omitDim, extra}) → string              // 'account=…&since=…&until=…&endpoint=…', chips mapped via API_PARAM, omitDim skipped

// lib/brush.js
export const SPANS = { '7d': {ms: 7*864e5, bucket: 36e5}, '30d': {ms: 30*864e5, bucket: 6*36e5}, '90d': {ms: 90*864e5, bucket: 864e5} };
export function extent(span, now) → { start, end, bucket, n }   // end = ceil(now, bucket) (UTC-aligned), start = end - n*bucket
export function snap(ms, bucket, mode='round') → ms               // 'floor' | 'ceil' | 'round'
export function defaultSelection(span, now) → { from, to:null }   // last 7d (from = end - 7d) or whole span
export function fit(sel, span, now) → sel | defaultSelection      // keeps sel when inside extent, else default
export function clamp(sel, ext) → sel                             // both edges inside [ext.start, ext.end], from < to (≥ one bucket)
export function resolve(sel, span, now) → { from, to, live }      // to:null ⇒ ext.end, live = to==null

// lib/fold.js
export function foldHourly(series, tzOffsetMinutes=fn) → { grid:number[7][24], events:number[7][24], total }   // series keys 'YYYY-MM-DDTHH:00' UTC
export function busiest(grid) → { dow, hour, tokens }
export function quietest(grid, hours=4) → { startHour, endHour, tokens }      // over the 7-day-summed 24h profile, circular
export function sentence(grid, locale='en') → string

// lib/format.js
export const fmtInt, fmtUSD, fmtFull, shortProject, relTime, ago, fmtPct(x, digits=1), fmtDur(ms), delta(cur, prev) → { pct:number|null, text:'+12%'|'—' }

// lib/seq.js
export function createLoader() → { run(fetchers, apply) → Promise<boolean>, get inFlight() }
```

- [ ] **Step 1: Write the failing tests**

```js
// web/test/state.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, format, withChip, withoutChip, apiQuery, DEFAULTS } from '../dist/lib/state.js';

test('parse defaults on empty and junk', () => {
  assert.deepEqual(parse(''), DEFAULTS);
  assert.deepEqual(parse('#/nowhere?span=1y&sub=&g1=bogus'), { ...DEFAULTS });
});

test('round-trips every field', () => {
  const s = { view: 'review', session: null, sub: 'abc', span: '7d', from: 1788300000000, to: 1788380000000,
    chips: { machine: 'ep1', project: '/Users/x/p q' }, g1: 'login', g2: 'branch', sort: 'cost' };
  const h = format(s);
  assert.match(h, /^#\/review\?/);
  assert.deepEqual(parse(h), s);
});

test('session route', () => {
  const s = parse('#/review/session/abc-123?sub=all');
  assert.equal(s.view, 'review');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/review/session/abc-123');
});

test('chips: one value per dimension, ordered, removable', () => {
  let s = withChip(DEFAULTS, 'model', 'opus');
  s = withChip(s, 'machine', 'ep1');
  s = withChip(s, 'model', 'haiku');
  assert.deepEqual(s.chips, { machine: 'ep1', model: 'haiku' });
  assert.equal(format(s), '#/now?machine=ep1&model=haiku');
  assert.deepEqual(withoutChip(s, 'machine').chips, { model: 'haiku' });
});

test('apiQuery maps chips and honours omitDim', () => {
  const s = { ...DEFAULTS, sub: 'acct', chips: { machine: 'ep1', login: 'u', project: '/p' } };
  const q = apiQuery(s, { from: 0, to: 3600000 });
  assert.equal(q, 'account=acct&since=1970-01-01T00:00:00.000Z&until=1970-01-01T01:00:00.000Z&endpoint=ep1&user=u&project=%2Fp');
  assert.ok(!apiQuery(s, { from: 0, to: 1, omitDim: 'machine' }).includes('endpoint='));
  assert.ok(apiQuery(s, { from: 0, to: 1, extra: { by: 'project', compare: 1 } }).endsWith('&by=project&compare=1'));
});
```

```js
// web/test/brush.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { extent, snap, defaultSelection, fit, clamp, resolve, SPANS } from '../dist/lib/brush.js';

const now = Date.UTC(2026, 8, 2, 10, 20); // 2026-09-02T10:20Z

test('extent is bucket-aligned and ends at ceil(now)', () => {
  const e = extent('30d', now);
  assert.equal(e.bucket, 6 * 36e5);
  assert.equal(e.end, Date.UTC(2026, 8, 2, 12));
  assert.equal(e.n, 120);
  assert.equal(e.start, e.end - 120 * e.bucket);
  assert.equal(extent('7d', now).n, 168);
  assert.equal(extent('90d', now).n, 90);
});

test('snap', () => {
  const b = 36e5;
  assert.equal(snap(Date.UTC(2026, 8, 2, 10, 20), b, 'floor'), Date.UTC(2026, 8, 2, 10));
  assert.equal(snap(Date.UTC(2026, 8, 2, 10, 20), b, 'ceil'), Date.UTC(2026, 8, 2, 11));
  assert.equal(snap(Date.UTC(2026, 8, 2, 10, 40), b), Date.UTC(2026, 8, 2, 11));
});

test('default selection is the last 7 days, or the whole span', () => {
  const e = extent('30d', now);
  assert.deepEqual(defaultSelection('30d', now), { from: e.end - 7 * 864e5, to: null });
  assert.deepEqual(defaultSelection('7d', now), { from: extent('7d', now).start, to: null });
});

test('fit keeps a selection inside the extent and resets one outside', () => {
  const e = extent('7d', now);
  const inside = { from: e.start + 36e5, to: e.start + 5 * 36e5 };
  assert.deepEqual(fit(inside, '7d', now), inside);
  const outside = { from: e.start - 864e5, to: e.start + 36e5 };
  assert.deepEqual(fit(outside, '7d', now), defaultSelection('7d', now));
});

test('clamp keeps at least one bucket and stays in range', () => {
  const e = extent('7d', now);
  assert.deepEqual(clamp({ from: e.start - 1, to: e.start }, e), { from: e.start, to: e.start + e.bucket });
  assert.deepEqual(clamp({ from: e.end - 1, to: e.end + 5 }, e), { from: e.end - e.bucket, to: e.end });
});

test('resolve: to=null is live and means the extent end', () => {
  const e = extent('30d', now);
  assert.deepEqual(resolve({ from: e.start, to: null }, '30d', now), { from: e.start, to: e.end, live: true });
  assert.deepEqual(resolve({ from: e.start, to: e.start + e.bucket }, '30d', now), { from: e.start, to: e.start + e.bucket, live: false });
});
```

```js
// web/test/fold.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { foldHourly, busiest, quietest, sentence } from '../dist/lib/fold.js';

const series = [
  { key: '2026-08-31T23:00', tokens: 100, events: 1 }, // Monday 23:00 UTC
  { key: '2026-09-01T00:00', tokens: 5, events: 1 },   // Tuesday 00:00 UTC
  { key: '2026-09-01T09:00', tokens: 900, events: 3 },
];

test('folds into local dow×hour with a fixed offset', () => {
  // +480 = UTC+8: Monday 23:00Z is Tuesday 07:00 local
  const { grid, total } = foldHourly(series, () => 480);
  assert.equal(total, 1005);
  assert.equal(grid[2][7], 100);   // Tue 07
  assert.equal(grid[2][8], 5);     // Tue 08
  assert.equal(grid[2][17], 900);  // Tue 17
  assert.equal(grid[1][23], 0);
});

test('busiest and quietest windows', () => {
  const { grid } = foldHourly(series, () => 0);
  assert.deepEqual(busiest(grid), { dow: 2, hour: 9, tokens: 900 });
  const q = quietest(grid, 4);
  assert.equal(q.tokens, 0);
  assert.ok(q.startHour >= 0 && q.startHour < 24);
  assert.match(sentence(grid), /busiest .*Tue 09:00/);
});
```

```js
// web/test/seq.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createLoader } from '../dist/lib/seq.js';

const later = (v, ms, signal) => new Promise((res, rej) => {
  const t = setTimeout(() => res(v), ms);
  signal?.addEventListener('abort', () => { clearTimeout(t); rej(new DOMException('aborted', 'AbortError')); });
});

test('a slower older load never overwrites a newer one', async () => {
  const L = createLoader();
  const applied = [];
  const a = L.run([(s) => later('old', 50, s)], (r) => applied.push(r[0].value));
  const b = L.run([(s) => later('new', 10, s)], (r) => applied.push(r[0].value));
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(ra, false);
  assert.equal(rb, true);
  assert.deepEqual(applied, ['new']);
  assert.equal(L.inFlight, false);
});

test('a failed request is reported per fetcher, not thrown', async () => {
  const L = createLoader();
  let got;
  await L.run([() => Promise.reject(new Error('boom')), () => Promise.resolve(1)], (r) => { got = r; });
  assert.equal(got[0].status, 'rejected');
  assert.equal(got[1].value, 1);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/projects/ccquota && printf '{"type":"module","private":true}\n' > web/package.json && node --test web/test/`
Expected: FAIL — cannot find modules.

- [ ] **Step 3: Implement `lib/state.js`**

```js
// web/dist/lib/state.js — URL ⇄ state. No DOM. The hash is the only copy of the state.
export const DIMS = ['machine', 'login', 'project', 'model', 'branch', 'team', 'session'];
export const API_PARAM = { machine: 'endpoint', login: 'user', project: 'project', model: 'model', branch: 'branch', team: 'team', session: 'session' };
export const SPAN_VALUES = ['7d', '30d', '90d'];
export const GROUPS = ['project', 'login', 'machine', 'model', 'branch', 'team'];
export const SORTS = ['tokens', 'cost', 'started', 'duration', 'turns'];
export const DEFAULTS = Object.freeze({ view: 'now', session: null, sub: 'all', span: '30d', from: null, to: null, chips: {}, g1: 'project', g2: 'model', sort: 'tokens' });

const pick = (v, allowed, dflt) => (allowed.includes(v) ? v : dflt);
const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; };

export function parse(hash) {
  const s = { ...DEFAULTS, chips: {} };
  const h = (hash || '').replace(/^#/, '');
  const [path, qs = ''] = h.split('?');
  const m = path.match(/^\/(now|review)(?:\/session\/([^/?]+))?\/?$/);
  if (m) { s.view = m[1]; if (m[2]) s.session = decodeURIComponent(m[2]); }
  const p = new URLSearchParams(qs);
  if (p.get('sub')) s.sub = p.get('sub');
  s.span = pick(p.get('span'), SPAN_VALUES, DEFAULTS.span);
  s.from = num(p.get('from'));
  s.to = num(p.get('to'));
  if (s.from && s.to && s.to <= s.from) { s.from = null; s.to = null; }
  if (!s.from) s.to = null;
  for (const d of DIMS) { const v = p.get(d); if (v) s.chips[d] = v; }
  s.g1 = pick(p.get('g1'), GROUPS, DEFAULTS.g1);
  s.g2 = pick(p.get('g2'), GROUPS, DEFAULTS.g2);
  s.sort = pick(p.get('sort'), SORTS, DEFAULTS.sort);
  return s;
}

export function format(s) {
  const p = new URLSearchParams();
  if (s.sub && s.sub !== DEFAULTS.sub) p.set('sub', s.sub);
  if (s.span !== DEFAULTS.span) p.set('span', s.span);
  if (s.from) p.set('from', String(s.from));
  if (s.from && s.to) p.set('to', String(s.to));
  for (const d of DIMS) if (s.chips[d]) p.set(d, s.chips[d]);
  if (s.g1 !== DEFAULTS.g1) p.set('g1', s.g1);
  if (s.g2 !== DEFAULTS.g2) p.set('g2', s.g2);
  if (s.sort !== DEFAULTS.sort) p.set('sort', s.sort);
  const path = '#/' + s.view + (s.session ? '/session/' + encodeURIComponent(s.session) : '');
  const qs = p.toString();
  return qs ? path + '?' + qs : path;
}

export const withChip = (s, dim, value) => ({ ...s, chips: { ...s.chips, [dim]: value } });
export function withoutChip(s, dim) { const chips = { ...s.chips }; delete chips[dim]; return { ...s, chips }; }
export const clearChips = (s) => ({ ...s, chips: {} });

// apiQuery renders the scope as the API's query string. omitDim implements the
// faceted-search rule: a card grouped by X leaves out its own X chip.
export function apiQuery(s, { from, to, omitDim, extra } = {}) {
  const p = new URLSearchParams();
  p.set('account', s.sub || 'all');
  p.set('since', new Date(from).toISOString());
  p.set('until', new Date(to).toISOString());
  for (const d of DIMS) if (s.chips[d] && d !== omitDim) p.set(API_PARAM[d], s.chips[d]);
  for (const [k, v] of Object.entries(extra || {})) p.set(k, String(v));
  return p.toString();
}
```

`URLSearchParams` encodes `/` as `%2F` and spaces as `+`; `parse` decodes both through the same class, so the round-trip test holds.

- [ ] **Step 4: Implement `lib/brush.js`**

```js
// web/dist/lib/brush.js — timeline extent and selection arithmetic. No DOM.
export const SPANS = {
  '7d':  { ms: 7 * 864e5,  bucket: 36e5 },
  '30d': { ms: 30 * 864e5, bucket: 6 * 36e5 },
  '90d': { ms: 90 * 864e5, bucket: 864e5 },
};
const SEVEN_DAYS = 7 * 864e5;

export function snap(ms, bucket, mode = 'round') {
  const q = ms / bucket;
  const k = mode === 'floor' ? Math.floor(q) : mode === 'ceil' ? Math.ceil(q) : Math.round(q);
  return k * bucket;
}

export function extent(span, now) {
  const { ms, bucket } = SPANS[span] || SPANS['30d'];
  const end = snap(now, bucket, 'ceil');
  const n = Math.round(ms / bucket);
  return { start: end - n * bucket, end, bucket, n };
}

export function defaultSelection(span, now) {
  const e = extent(span, now);
  if ((SPANS[span] || SPANS['30d']).ms <= SEVEN_DAYS) return { from: e.start, to: null };
  return { from: e.end - SEVEN_DAYS, to: null };
}

export function clamp(sel, e) {
  let from = Math.max(e.start, Math.min(sel.from, e.end - e.bucket));
  let to = sel.to == null ? null : Math.min(e.end, Math.max(sel.to, from + e.bucket));
  if (to != null && to - from < e.bucket) to = from + e.bucket;
  if (to != null && to > e.end) { to = e.end; from = Math.min(from, to - e.bucket); }
  return { from, to };
}

export function fit(sel, span, now) {
  if (!sel || !sel.from) return defaultSelection(span, now);
  const e = extent(span, now);
  const to = sel.to == null ? e.end : sel.to;
  if (sel.from < e.start || to > e.end || to <= sel.from) return defaultSelection(span, now);
  return sel;
}

export function resolve(sel, span, now) {
  const e = extent(span, now);
  const s = fit(sel, span, now);
  return { from: s.from, to: s.to == null ? e.end : s.to, live: s.to == null };
}
```

- [ ] **Step 5: Implement `lib/fold.js`**

```js
// web/dist/lib/fold.js — hourly series → local weekday × hour grid. No DOM.
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const zeros = () => Array.from({ length: 7 }, () => new Array(24).fill(0));

// tzOffset(ms) → minutes east of UTC at that instant. The default asks the
// runtime, so DST is handled per hour rather than assumed constant.
const localOffset = (ms) => -new Date(ms).getTimezoneOffset();

export function foldHourly(series, tzOffset = localOffset) {
  const grid = zeros(), events = zeros();
  let total = 0;
  for (const s of series || []) {
    const utc = Date.parse(s.key.length === 16 ? s.key + ':00Z' : s.key);
    if (!Number.isFinite(utc)) continue;
    const local = new Date(utc + tzOffset(utc) * 60000);
    const dow = local.getUTCDay(), hour = local.getUTCHours();
    grid[dow][hour] += s.tokens || 0;
    events[dow][hour] += s.events || 0;
    total += s.tokens || 0;
  }
  return { grid, events, total };
}

export function busiest(grid) {
  let best = { dow: 0, hour: 0, tokens: -1 };
  grid.forEach((row, dow) => row.forEach((t, hour) => { if (t > best.tokens) best = { dow, hour, tokens: t }; }));
  return best;
}

// quietest finds the lowest-token window of `hours` consecutive hours on the
// 24-hour profile summed over the week, wrapping past midnight.
export function quietest(grid, hours = 4) {
  const profile = new Array(24).fill(0);
  for (const row of grid) row.forEach((t, h) => { profile[h] += t; });
  let best = { startHour: 0, endHour: hours % 24, tokens: Infinity };
  for (let s = 0; s < 24; s++) {
    let sum = 0;
    for (let k = 0; k < hours; k++) sum += profile[(s + k) % 24];
    if (sum < best.tokens) best = { startHour: s, endHour: (s + hours) % 24, tokens: sum };
  }
  return best;
}

const hh = (h) => String(h).padStart(2, '0') + ':00';

export function sentence(grid) {
  const b = busiest(grid);
  if (b.tokens <= 0) return 'No usage in this period.';
  const q = quietest(grid, 4);
  return `Busiest hour: ${DAYS[b.dow]} ${hh(b.hour)} local. Quietest 4-hour window: ${hh(q.startHour)}–${hh(q.endHour)}.`;
}
```

- [ ] **Step 6: Implement `lib/format.js` and `lib/seq.js`**

`format.js`: move `fmtInt`, `fmtUSD`, `fmtFull`, `shortProject`, `relTime`, `ago` verbatim from the old `index.html` (they are pure), and add:

```js
export const fmtPct = (x, digits = 1) => (Number(x) * 100).toFixed(digits) + '%';
export function fmtDur(ms) {
  const m = Math.round(ms / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}
// delta compares two additive values. null pct means "no previous data".
export function delta(cur, prev) {
  if (!prev || !Number.isFinite(prev)) return { pct: null, text: '—' };
  const pct = ((cur - prev) / prev) * 100;
  const sign = pct > 0 ? '+' : '';
  return { pct, text: `${sign}${Math.abs(pct) >= 10 ? Math.round(pct) : pct.toFixed(1)}%` };
}
```

```js
// web/dist/lib/seq.js — one loader, one sequence number. A response is applied
// only if no newer load started meanwhile; superseded fetches are aborted.
export function createLoader() {
  let seq = 0, ctrl = null, running = 0;
  return {
    async run(fetchers, apply) {
      const mine = ++seq;
      if (ctrl) ctrl.abort();
      ctrl = new AbortController();
      const signal = ctrl.signal;
      running++;
      try {
        const results = await Promise.allSettled(fetchers.map((f) => f(signal)));
        if (mine !== seq) return false;
        apply(results);
        return true;
      } finally {
        running--;
      }
    },
    get inFlight() { return running > 0; },
  };
}
```

- [ ] **Step 7: Run the Node tests**

Run: `node --test web/test/`
Expected: all pass (4 files). Fix `apiQuery` expected string if `URLSearchParams` encodes differently than assumed (adjust the test to what the platform actually emits, then re-check the Go side accepts it — it does, `net/url` decodes both `+` and `%2F`).

- [ ] **Step 8: CI and Makefile**

Append to `.github/workflows/ci.yml` jobs:

```yaml
  web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: node --test web/test/
```

Makefile `test:` target becomes:

```make
test:
	go test ./...
	@command -v node >/dev/null && node --test web/test/ || echo "node not found: skipping web tests"
```

- [ ] **Step 9: Commit**

```bash
git add web/package.json web/dist/lib web/test .github/workflows/ci.yml Makefile
git commit -m "feat(web): pure state/brush/fold/format/seq modules with node tests and a CI job"
```

---

### Task 11: the shell — `index.html`, `styles.css`, `app.js`, `scope.js`, `lib/dom.js`, `charts.js`, `now.js`

**Files:**
- Rewrite: `web/dist/index.html`
- Create: `web/dist/styles.css`, `web/dist/app.js`, `web/dist/scope.js`, `web/dist/lib/dom.js`, `web/dist/charts.js`, `web/dist/now.js`
- Keep: `web/dist/user.html`, `web/dist/share.html` untouched

**Interfaces:**
- Consumes: Task 10 modules; the existing API (`/v1/accounts`, `/v1/limits`, `/v1/endpoints`, `/v1/live/stream`, `/v1/endpoint-accounts`, `/v1/account-switches`, `/v1/findings?view=now`).
- Produces:
  - `app.js`: `export const app = { state, now(), setState(next, {push}) , api(path, signal) }` where `setState` writes the hash (`pushState` for view/brush/chip changes, `replaceState` otherwise) and the `hashchange` handler re-renders; `api()` is `fetch` + JSON + error normalisation, accepts an `AbortSignal`.
  - `lib/dom.js`: `el`, `escapeHTML`, `showTip(evt, html)`, `hideTip()` (moved verbatim).
  - `charts.js`: `rankedBars(rows, {onClick, selectedKey})`, `bucketTable(buckets, keyLabel, extraCols)`, `withTable(card, chartEl, tableEl)` (the per-card ⊞ toggle, remembered in `localStorage['ccquota-table:' + cardId]`), `kpiTile({id, label, value, delta, tone})`, `timeline(series, {bucket, extent, selection, stackNames, onBrush})`, `stackedArea(series, stackNames)`, `heatmap(grid, events)`, `lines(accounts, {start, end})`, `composition(parts)`, `turnBars(turns)`.
  - `scope.js`: `renderScope(root, state, accounts, {onView, onSub, onSpan, onChipRemove, onClear})`, `setBusy(bool)`.
  - `now.js`: `export function renderNow(root, state, ctx)` → returns `{ fetchers, apply(results) }` for the loader, plus owns the SSE subscription (`connectLive`) and re-renders live rows on every snapshot, filtered by chips.

- [ ] **Step 1: `index.html`**

```html
<!doctype html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>ccquota</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='4' fill='%232a78d6'/%3E%3Crect x='3' y='7' width='10' height='3' rx='1.5' fill='%23fff'/%3E%3C/svg%3E">
<link rel="stylesheet" href="styles.css">
</head>
<body>
<header class="scope" id="scope">
  <div class="row1">
    <h1>ccquota</h1>
    <nav class="views" role="tablist">
      <button role="tab" id="tab-now" aria-selected="true">Now</button>
      <button role="tab" id="tab-review" aria-selected="false">Review</button>
    </nav>
    <span class="spacer"></span>
    <select id="sub" aria-label="Subscription"></select>
    <div class="seg" id="span" role="group" aria-label="Timeline span">
      <button data-span="7d">7d</button><button data-span="30d">30d</button><button data-span="90d">90d</button>
    </div>
    <button id="theme" title="Toggle light / dark">◐</button>
  </div>
  <div class="row2" id="chips" hidden></div>
  <div class="progress" id="progress" hidden></div>
</header>
<div class="wrap">
  <div id="banners"></div>
  <main id="now" aria-busy="false"></main>
  <main id="review" aria-busy="false" hidden></main>
  <footer id="footer"></footer>
</div>
<aside id="detail" class="detail" hidden aria-modal="true" role="dialog"></aside>
<div class="tip" id="tip" role="status"></div>
<script type="module" src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: `styles.css`**

Move every rule from the old `<style>` block verbatim (tokens, hero, live, cards, bars, gauges, tables, tooltip, legend), then add:

```css
/* scope bar */
.scope { position: sticky; top: 0; z-index: 20; background: var(--surface); border-bottom: 1px solid var(--border); }
.scope .row1 { display: flex; align-items: center; gap: 10px; padding: 10px 20px; flex-wrap: wrap; }
.scope h1 { font-size: 17px; }
.scope .views button { border: 0; background: transparent; padding: 6px 12px; border-radius: 8px; color: var(--ink-2); font: inherit; cursor: pointer; }
.scope .views button[aria-selected="true"] { background: var(--s1); color: #fff; }
.scope .seg { display: inline-flex; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
.scope .seg button { border: 0; border-right: 1px solid var(--border); background: var(--surface); padding: 5px 10px; font: inherit; color: var(--ink-2); cursor: pointer; }
.scope .seg button:last-child { border-right: 0; }
.scope .seg button[aria-pressed="true"] { background: var(--s1); color: #fff; }
.scope .row2 { display: flex; gap: 6px; align-items: center; padding: 0 20px 8px; overflow-x: auto; white-space: nowrap; }
.chip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 8px 2px 10px; border-radius: 999px; background: var(--s1); color: #fff; font-size: 12.5px; }
.chip button { border: 0; background: transparent; color: inherit; cursor: pointer; font-size: 14px; line-height: 1; padding: 0; }
.chip.clear { background: var(--ink-3); }
.progress { height: 2px; background: linear-gradient(90deg, var(--s1), var(--s3)); animation: prog 1s linear infinite; background-size: 200% 100%; }
@keyframes prog { from { background-position: 0 0 } to { background-position: 200% 0 } }
main[aria-busy="true"] .card { opacity: .6; transition: opacity .2s; }
/* kpi */
.kpis { display: grid; grid-template-columns: repeat(7, 1fr); gap: 10px; }
.kpi { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 12px 14px; }
.kpi .v { font-size: 22px; font-weight: 600; letter-spacing: -.01em; }
.kpi .d { font-size: 12px; margin-left: 6px; color: var(--ink-3); } .kpi .d.up { color: var(--critical); } .kpi .d.down { color: var(--good); }
.kpi .l { font-size: 12px; color: var(--ink-3); }
/* timeline + brush */
.timeline { position: relative; user-select: none; touch-action: none; }
.timeline .brush { position: absolute; top: 0; bottom: 26px; background: color-mix(in srgb, var(--s1) 12%, transparent); border-left: 2px solid var(--s1); border-right: 2px solid var(--s1); cursor: grab; }
.timeline .brush .h { position: absolute; top: 0; bottom: 0; width: 10px; cursor: ew-resize; } .timeline .brush .h.l { left: -6px } .timeline .brush .h.r { right: -6px }
.timeline .caption { font-size: 12.5px; color: var(--ink-3); margin-top: 6px; }
/* heatmap */
.heat { display: grid; grid-template-columns: 34px repeat(24, 1fr); gap: 2px; align-items: center; font-size: 11px; color: var(--ink-3); }
.heat i { display: block; aspect-ratio: 1; border-radius: 2px; background: var(--grid); }
/* findings */
.findings .f { display: flex; gap: 10px; padding: 8px 0; border-top: 1px dashed var(--border); align-items: flex-start; }
.findings .f:first-child { border-top: 0; }
.findings .dot { width: 9px; height: 9px; border-radius: 50%; margin-top: 6px; flex: none; }
.dot.critical { background: var(--critical) } .dot.warning { background: var(--warning) } .dot.info { background: var(--s1) }
/* card table toggle */
.card { position: relative; } .card .tbl { position: absolute; right: 12px; top: 12px; border: 1px solid var(--border); background: var(--surface); border-radius: 6px; font-size: 12px; padding: 2px 6px; cursor: pointer; color: var(--ink-2); }
/* sessions */
.sessions tr { cursor: pointer; } .sessions td a { color: inherit; text-decoration: underline dotted; }
/* detail overlay */
.detail { position: fixed; inset: 0 0 0 auto; width: min(760px, 100vw); background: var(--surface); border-left: 1px solid var(--border); box-shadow: var(--shadow); z-index: 30; overflow: auto; padding: 20px; }
.detail .close { position: absolute; right: 16px; top: 12px; border: 0; background: transparent; font-size: 22px; cursor: pointer; color: var(--ink-2); }
/* fleet */
details.fleet > summary { cursor: pointer; font-weight: 600; padding: 10px 0; }
/* mobile */
@media (max-width: 720px) {
  .scope .row1 { padding: 8px 12px; gap: 6px; } .scope h1 { display: none; }
  .kpis { grid-template-columns: repeat(2, 1fr); }
  .grid2 { grid-template-columns: 1fr; }
  .sessions table { display: none; } .sessions .cards { display: grid; gap: 8px; }
}
@media (min-width: 721px) { .sessions .cards { display: none; } }
```

- [ ] **Step 3: `app.js`**

```js
// web/dist/app.js — boot, router, loader wiring.
import { parse, format } from './lib/state.js';
import { createLoader } from './lib/seq.js';
import { renderScope, setBusy } from './scope.js';
import { renderNow } from './now.js';
import { renderReview } from './review.js';
import { renderDetail, closeDetail } from './session.js';
import { $, el } from './lib/dom.js';

export const app = {
  state: parse(location.hash),
  accounts: [],
  now: () => Date.now(),
  async api(path, signal) {
    const res = await fetch(path, { headers: { Accept: 'application/json' }, signal });
    if (!res.ok) {
      let msg = `HTTP ${res.status}`;
      try { msg = (await res.json()).error || msg; } catch {}
      throw new Error(msg);
    }
    return res.json();
  },
  setState(next, { push = true } = {}) {
    const h = format(next);
    if (h === location.hash) return;
    if (push) history.pushState(null, '', h); else history.replaceState(null, '', h);
    route();
  },
};

const loaders = { now: createLoader(), review: createLoader() };
let lastRendered = '';

function route() {
  app.state = parse(location.hash);
  const s = app.state;
  if (!s.sub || (s.sub !== 'all' && !app.accounts.some((a) => a.account_uuid === s.sub))) {
    s.sub = app.accounts.length > 1 ? 'all' : (app.accounts[0]?.account_uuid || 'all');
  }
  renderScope($('#scope'), s, app.accounts, {
    onView: (v) => app.setState({ ...s, view: v, session: null }),
    onSub: (sub) => app.setState({ ...s, sub }),
    onSpan: (span) => app.setState({ ...s, span, from: null, to: null }),
    onChipRemove: (dim) => { const chips = { ...s.chips }; delete chips[dim]; app.setState({ ...s, chips }); },
    onClear: () => app.setState({ ...s, chips: {} }),
  });
  $('#now').hidden = s.view !== 'now';
  $('#review').hidden = s.view !== 'review';
  if (s.session) renderDetail($('#detail'), s, app); else closeDetail($('#detail'));
  const key = format({ ...s, session: null });
  if (key !== lastRendered) { lastRendered = key; load(); }
}

async function load() {
  const s = app.state;
  const view = s.view;
  const root = $('#' + view);
  const r = view === 'now' ? renderNow(root, s, app) : renderReview(root, s, app);
  root.setAttribute('aria-busy', 'true'); setBusy(true);
  const ok = await loaders[view].run(r.fetchers, r.apply);
  if (ok) { root.setAttribute('aria-busy', 'false'); setBusy(loaders.now.inFlight || loaders.review.inFlight); }
}

async function boot() {
  try { app.accounts = await app.api('/v1/accounts'); }
  catch (err) { $('#banners').replaceChildren(el('div', { class: 'banner err' }, 'Cannot reach the hub: ' + err.message)); return; }
  addEventListener('hashchange', route);
  route();
  // Now refreshes its stored cards every minute; Review only when the brush
  // touches the right edge, every five minutes.
  setInterval(() => { if (app.state.view === 'now') load(); }, 60_000);
  setInterval(() => { if (app.state.view === 'review' && app.state.to == null) load(); }, 300_000);
}
boot();
```

Theme toggle: copy the old handler verbatim into `scope.js` (bound once in `renderScope`).

- [ ] **Step 4: `scope.js`**

Renders the header from state: tab `aria-selected`, `#sub` options (`All N subscriptions` first when >1; hidden when 1), span buttons `aria-pressed`, chips row (`<span class="chip">machine: <b>label</b> <button aria-label="remove">×</button></span>` for each chip in `DIMS` order, plus a `clear` chip; row hidden when no chips). Chip labels: `machine` shows the endpoint label (from `/v1/endpoints`, cached on `app.endpoints`), `project` shows `shortProject`, `session` the first 8 chars; others raw. `setBusy(b)` toggles `#progress.hidden = !b`. Listeners are attached once (guard with a `data-bound` attribute) and read callbacks from a module-level `handlers` object updated on every render.

- [ ] **Step 5: `charts.js`**

Port `rankedBars`, `bucketTable`, `timeSeries` (rename `bars`), `gauge`, `tile`, `tween` from the old page unchanged except:
- `rankedBars(rows, {onClick, selectedKey})`: each row gets `role="button"`, `tabindex=0`, `click`/`Enter` → `onClick(row)`; the row whose `key === selectedKey` gets class `sel`.
- `withTable(card, chartEl, tableEl, cardId)`: appends both, hides one, adds the ⊞ button, restores from `localStorage`.
- New `kpiTile({label, value, delta, tone})` → `.kpi` with `.v`, `.d.up|down`, `.l`; `tone` = `'spend'` (up is red) or `'neutral'`.
- New `timeline(series, opts)`: SVG bars (stacked by `opts.stackNames`, palette order, "other" in `--ink-3`), x from `opts.extent`, an absolutely positioned `.brush` div with two `.h` handles. Pointer events: down on body → move; down on handle → resize; on move compute ms from x via `extent`, `snap` to `opts.bucket`, `clamp`, update the div immediately, call `opts.onBrush(sel, {final:false})`; on up call `onBrush(sel, {final:true})`. Double-click → `onBrush({from: extent.start, to: null}, {final:true})`. Arrow keys on the focused brush move by one bucket, Shift+arrow resizes the right edge. Caption element `.caption` updated by the caller.
- New `stackedArea(series, stackNames)`: SVG paths, one per stack name, cumulative; legend below.
- New `heatmap(grid, events)`: `.heat` grid: first column `Sun…Sat`, 24 cells per row with `background: color-mix(in srgb, var(--s1) P%, var(--grid))` where `P = 8 + 92 * tokens / max`; `title` and tooltip with tokens and turns.
- New `lines(accounts, {start, end})`: SVG polyline per account for `five_hour_pct` (y 0–100), red segments where ≥ 90 (split the polyline), a fainter dashed line for `seven_day_pct`, gridlines at 50/90, legend with account labels.
- New `composition(parts)`: one horizontal stacked bar of `[{key, tokens, color}]` with a legend showing percentages.
- New `turnBars(turns)`: one bar per turn (height = tokens), coloured by model in palette order, sidechain bars with a hatched pattern (`<pattern>`), tooltip per bar.

- [ ] **Step 6: `now.js`**

Port from the old page: `hero` (`applyCounter`, `pacSVG`, `dotStream`, odometer), `renderLive`, `connectLive`, `wallCard`, `gauge`, `endpointRosterCard`, `endpointAccountsCard`, `switchesCard`, the banners (`lossy`, spanning, limits stale). Changes:
- Layout: `#alerts` (findings list) → hero → wall card → live card → `<details class="fleet"><summary>Fleet</summary>…three tables…</details>` (open state in `localStorage['ccquota-fleet']`).
- `fetchers`: `/v1/findings?view=now&account=…`, `/v1/limits?account=…`, `/v1/endpoints?account=…`, `/v1/endpoint-accounts?account=…&limit=200`, `/v1/account-switches?account=…&limit=20`. `apply(results)` renders each card from its own result; a rejected result renders that card with `Query failed: <message>` and leaves the others.
- Live rows honour chips: filter `snap.sessions` by `endpoint_id` (machine), `os_user` (login), `cwd` (project), `model`, `session_id` (session). Row click → `app.setState(withChip(state, 'session', s.session_id))`; project name click → `project` chip.
- The two stored tiles are removed from the live card.
- The `null` bug: `main.replaceChildren(...cards.filter(Boolean))`.

- [ ] **Step 7: Verify in a browser**

Run the hub locally on a copy of the mini DB (see Task 14 for the copy) and open `http://127.0.0.1:8799/#/now`. Check: tabs switch, subscription select reloads, chips appear when a live row is clicked and are removable, `Fleet` collapses, the progress bar shows during loads, no `null` text (`document.body.innerText.includes('null')` is false in the console), theme toggle works. Review tab may be empty at this point.

- [ ] **Step 8: Commit**

```bash
git add web/dist
git commit -m "feat(web): module shell with sticky scope bar, chips, sequenced loads and the Now view"
```

---

### Task 12: the Review view

**Files:**
- Create: `web/dist/review.js`

**Interfaces:**
- Consumes: `app` (state, api, setState, now), `lib/state.js` (`apiQuery`, `withChip`), `lib/brush.js` (`extent`, `resolve`, `fit`, `clamp`, `snap`), `lib/fold.js`, `lib/format.js`, `charts.js`.
- Produces: `export function renderReview(root, state, app) → { fetchers, apply }`.

Spec §5 is the contract. Card by card, with the request each one issues (all under `apiQuery(state, {from, to, …})` where `{from, to}` comes from `resolve(sel, span, now)` unless stated):

| # | card id | request(s) | render |
|---|---|---|---|
| 1 | `timeline` | `/v1/history?…&since=<extent.start>&until=<extent.end>&granularity=<hour\|6h\|day by span>&stack=model` | `charts.timeline`; caption `selected <from> → <to> (<len>) · compared with the <len> before`; brush `onBrush(sel,{final})`: `final:false` updates the caption only; `final:true` → `app.setState({...state, from: sel.from, to: sel.to})` (debounced 250 ms) |
| 2 | `kpis` | `/v1/summary?…&compare=1` | seven `kpiTile`s per spec §5.2; spend tile shows ⚠ + title when `unpriced_events > 0`; ratios use `tone:'neutral'` |
| 3 | `findings` | `/v1/findings?…` | list; each item: severity dot, title, detail, and when `scope` present a link "apply →" that adds those chips (`withChip` per key) and, when `link` is `#sessions`/`#wall-history`, scrolls to that card; empty state "Nothing unusual in this period." |
| 4 | `breakdown-1`, `breakdown-2` | `/v1/usage?…&by=<API dim for g1/g2>&limit=50&compare=1` with `omitDim` = the card's own dimension | segmented group-by (`GROUPS`, `team` only when any endpoint has a team) → `app.setState({...state, g1}, {push:false})`; `rankedBars` 12 rows + "show all N" (`sel` row = the state chip for that dim); row click → `withChip(state, dim, row.key)`; right text `tokens · $ · Δ`; table view lists prev columns too |
| 5 | `efficiency` | reuses card 2's summary + card 4's by-model when `g2==='model'` else its own `/v1/usage?…&by=model&limit=8` | `composition([{cache read}, {cache create}, {output}, {input}, {thinking}])`; three inline lists effort / entrypoint / subagent turns; small `rankedBars` of `$ per 1M output` by model (`cost_usd / output_tokens * 1e6`, skip models with 0 output or unpriced) |
| 6 | `model-mix` | reuses card 1's response, filtered to buckets inside the selection | `stackedArea(series, stack_models)` + legend |
| 7 | `when` | `/v1/history?…&granularity=hour` (selection range) | `foldHourly` → `heatmap`; `sentence(grid)` under it; if selection < 48 h render `bars` of the hourly series instead |
| 8 | `wall-history` | `/v1/limits/history?…&points=400` | `lines(accounts, {start, end})`; under each: `N critical episodes · <dur> in critical (prev <dur>)`; empty state "Limit snapshots exist from 2026-09-01." when no points |
| 9 | `sessions` | `/v1/sessions?…&sort=<state.sort>&limit=50` | table (headers clickable → `app.setState({...state, sort}, {push:false})`), row click → `app.setState({...state, session: row.session_id})`, project / login cells → chips; mobile `.cards`; "load more" fetches `offset=<rows>` and appends |

The `fetchers` array is built in that order so `apply(results)` can index it; each card renders independently from its own `results[i]` and shows `Query failed: <message>` on rejection. Card 1 always uses the **extent** range, never the selection.

- [ ] **Step 1: Write `review.js`** following the table. Skeleton:

```js
import { apiQuery, withChip, GROUPS, API_PARAM } from './lib/state.js';
import { extent, resolve, SPANS } from './lib/brush.js';
import { foldHourly, sentence } from './lib/fold.js';
import { fmtInt, fmtUSD, fmtFull, fmtPct, fmtDur, delta, shortProject } from './lib/format.js';
import { el, escapeHTML, showTip, hideTip } from './lib/dom.js';
import * as C from './charts.js';

const GRAN = { '7d': 'hour', '30d': '6h', '90d': 'day' };
const DIM_TO_API = { project: 'project', login: 'user', machine: 'endpoint', model: 'model', branch: 'branch', team: 'team' };
let brushTimer = 0;

export function renderReview(root, state, app) {
  const now = app.now();
  const ext = extent(state.span, now);
  const sel = resolve({ from: state.from, to: state.to }, state.span, now);
  const q = (opts) => apiQuery(state, { from: sel.from, to: sel.to, ...opts });
  const get = (path) => (signal) => app.api(path, signal);
  const fetchers = [
    get(`/v1/history?${apiQuery(state, { from: ext.start, to: ext.end, extra: { granularity: GRAN[state.span], stack: 'model' } })}`),
    get(`/v1/summary?${q({ extra: { compare: 1 } })}`),
    get(`/v1/findings?${q()}`),
    get(`/v1/usage?${q({ omitDim: state.g1, extra: { by: DIM_TO_API[state.g1], limit: 50, compare: 1 } })}`),
    get(`/v1/usage?${q({ omitDim: state.g2, extra: { by: DIM_TO_API[state.g2], limit: 50, compare: 1 } })}`),
    get(`/v1/usage?${q({ extra: { by: 'model', limit: 8 } })}`),
    get(`/v1/history?${q({ extra: { granularity: 'hour' } })}`),
    get(`/v1/limits/history?${q({ extra: { points: 400 } })}`),
    get(`/v1/sessions?${q({ extra: { sort: state.sort, limit: 50 } })}`),
  ];
  if (!root.firstChild) root.replaceChildren(...['timeline','kpis','findings','breakdowns','effmix','whenwall','sessions']
    .map((id) => el('section', { id: 'r-' + id })));
  return { fetchers, apply: (r) => applyAll(root, state, app, { ext, sel, now }, r) };
}
```

`applyAll` renders each section from its result (`r[i].status === 'fulfilled' ? r[i].value : error card`). Every card is a `div.card` with an `h2`, a `p.hint`, the chart, and `C.withTable` where a table view exists.

- [ ] **Step 2: Verify in a browser** (hub on the mini DB copy, `#/review`):
  1. Drag the brush: caption updates live; cards reload after release; URL gains `from`/`to`.
  2. Change span 30d → 90d: selection kept (it fits); 90d → 7d: reset to the whole week.
  3. Click a project row: chip appears, all cards reload, the project breakdown still lists every project with the chosen one highlighted.
  4. Switch breakdown 2 to `branch`: URL has `g2=branch`, back button undoes it.
  5. Sort sessions by `duration`; click a session → the detail overlay (Task 13) opens; Esc closes and the URL drops `/session/`.
  6. Network panel: every request ≤ 300 ms at 90d.

- [ ] **Step 3: Commit**

```bash
git add web/dist/review.js
git commit -m "feat(web): Review view — timeline brush, KPIs, findings, breakdowns, efficiency, model mix, heatmap, wall history, sessions"
```

---

### Task 13: session detail overlay

**Files:**
- Create: `web/dist/session.js`

**Interfaces:**
- Produces: `export function renderDetail(root, state, app)` (fetches `/v1/sessions/<id>?account=<sub>`, renders header + `C.turnBars` + turn table; `pruned` ⇒ "turns older than the retention window are gone"), `export function closeDetail(root)`. Esc and the × button call `app.setState({...state, session: null})`. Focus moves into the panel on open and back to the sessions table on close.

- [ ] **Step 1: Write it.** Header fields per spec §6: project (full path in `title`), login@machine, subscription label (from `app.accounts`), primary model, started (local), duration (`fmtDur`), turns, tokens, cost (`⚠ unpriced` when `unpriced_events > 0`), cache hit (`fmtPct`), subagent share. Turn table columns: time, model, effort, input, output, cache read, cache create, thinking, $, sub (✓ for sidechain).

- [ ] **Step 2: Verify**: open `#/review/session/<a real id from the sessions table>?sub=all` directly in a new tab → the overlay renders over Review with the same scope; close → Review stays.

- [ ] **Step 3: Commit**

```bash
git add web/dist/session.js
git commit -m "feat(web): session detail overlay with per-turn bars"
```

---

### Task 14: local preview on a copy of the mini's database, and the manual checklist

**Files:** none (verification only). Screenshots go to the session scratchpad, never the repo.

- [ ] **Step 1: Copy the mini DB** (read-only snapshot; the hub on the mini keeps running):

```bash
ssh macmini 'sqlite3 ~/.ccquota/ccquota.db ".backup /tmp/ccq-snapshot.db"' && scp macmini:/tmp/ccq-snapshot.db /tmp/ccq-preview.db
```

- [ ] **Step 2: Build and run locally**

```bash
cd ~/projects/ccquota && make build && ./bin/ccquota hub --db /tmp/ccq-preview.db --no-auth --addr 127.0.0.1:8799 2>&1 | tee /tmp/ccq-preview.log &
sleep 3; grep -i rollup /tmp/ccq-preview.log   # expect: "rollup: built N hourly rows …" — record N in the plan (§13 of the spec)
```

- [ ] **Step 3: Measure** every Review request at `span=90d` with the browser's network panel or:

```bash
for q in "summary?account=all&since=90d&compare=1" "sessions?account=all&since=90d" "history?account=all&since=90d&granularity=day&stack=model" "findings?account=all&since=90d" "usage?account=all&since=90d&by=project&compare=1"; do printf '%-70s ' "$q"; curl -s -o /dev/null -w '%{time_total}s\n' "http://127.0.0.1:8799/v1/$q"; done
```

Expected: each < 0.3 s. Record the numbers here.

- [ ] **Step 4: Run the manual checklist** from spec §10 (six items) against `http://127.0.0.1:8799/`, including the race repro: in the console run

```js
const s = document.querySelector('#sub'); s.value = s.options[1].value; s.dispatchEvent(new Event('change'));
setTimeout(() => { s.value = 'all'; s.dispatchEvent(new Event('change')); }, 300);
```

then after 8 s confirm `location.hash` has no `sub=` (all) **and** the KPI/breakdown cards show all-subscription figures (the account breakdown lists three subscriptions).

- [ ] **Step 5: Full gate**

```bash
gofmt -l . ; go vet ./... && go test -race ./... && node --test web/test/
```

Expected: all green. Push the branch: `git push -u origin dashboard-redesign` and confirm CI (`gh run list -L 1`) is green.

- [ ] **Step 6: Hand the preview URL to the user** with the measured numbers and the screenshots. Deployment to the mini (spec §11) waits for their go.

## Self-review notes

- Spec §3.4 (race) → Task 10 `seq.js` + Task 11 `app.js`; §3.3 (chips, self-exclusion) → Task 10 `apiQuery.omitDim` + Task 12; §5.1–5.10 → Task 12; §6 → Task 13; §7 → Tasks 7–8; §8.1–8.5 → Tasks 2–6, 9; §9 → Tasks 10–13; §10 → tests in every task + Task 14; §11 deploy is out of this plan (needs the user's go).
- Names used across tasks: `store.Filter` (1) ← `scope()` (5) ← `review.go` (6) / `findings.go` (8); `UsageByFiltered`, `HourlyByModel`, `Summary`, `Sessions`, `Session`, `SessionTurns`, `LimitsHistory` (3) ← 6, 8; `criticalTime`, `downsample` (6) ← 8; `foldHours`, `topModels` (5) ← `handleHistory` (5); `createLoader` (10) ← `app.js` (11); `apiQuery` / `withChip` (10) ← 11, 12, 13; `extent` / `resolve` / `fit` / `clamp` / `snap` (10) ← 12.
