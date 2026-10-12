# ccquota Badges & Boards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the two unblocked surfaces from the badges & boards spec — a local `ccquota badge` command that renders an SVG with no network, and the hub's three additions (a `team` dimension, `/u/<person>`, badge routes).

**Architecture:** A new self-contained `internal/badge` package renders SVG and shields JSON from a plain struct; `ccquota badge` reads the local hub's SQLite database and writes the file. The hub gains `team` as an ordinary `store.Dimension` resolved by join (operator-assigned, never endpoint-reported), a per-OS-login summary query behind `/u/<login>`, and badge routes that share the same renderer.

**Tech Stack:** Go 1.25, `modernc.org/sqlite` (pure Go, CGO_ENABLED=0), hand-written HTML/CSS/JS under `web/dist` embedded via `go:embed`. No new dependencies — `go.mod` must not change.

**Spec:** `docs/superpowers/specs/2026-09-01-ccquota-board-design.md`

## Scope

This plan implements **spec §12 steps 1 and 2 only**.

**Step 3 (`internal/submit` + `ccquota badges`, the public service) is deliberately NOT in this plan.** The spec's own §12 blocks it on two questions the user has not answered: §11.1 (who hosts and pays) and §11.2 (Anthropic's terms on publishing usage figures). Building a submission protocol before those are settled risks building the wrong protocol for a service that may not exist. When those are answered, write a second plan.

## Global Constraints

Copied verbatim from the spec; every task's requirements implicitly include these.

- **The badge is rendered for a sandboxed context.** An SVG loaded through `<img>` has "no scripts, no external fonts, no external CSS, no network. Everything inline." (§8)
- **Fonts: a system stack.** "A webfont will not load here at all." (§8)
- **Themes are an explicit `?theme=`/`--theme` value**, never `prefers-color-scheme` — it "is inconsistently supported [inside an SVG-as-image] and camo caches one copy for everyone." (§8)
- **A badge carries a period label, never a timestamp** "that will be wrong on a profile for a week." (§8)
- **An endpoint cannot declare its own team** — teams are "assigned by the operator in hub config … for the same reason a submission cannot declare its own handle." (§6)
- **No rank numbers and no podium** on the internal board. (§6)
- **The hub is air-gapped by construction** — it "makes no outbound calls beyond Anthropic's own endpoints." (§6) Nothing in this plan adds an outbound call.
- **`ccquota badge` produces a valid SVG with no network access whatsoever.** (§10)
- **Never present in any public payload:** project paths, machine names, OS logins, session ids, git branches, account emails, account uuids, utilization. (§5.1) — no route added here is public, but the badge renderer must stay free of them so it is reusable in step 3.
- **`CGO_ENABLED=0` must keep cross-compiling to all five platforms** (`make dist`).

## File Structure

| File | Responsibility |
|---|---|
| `internal/badge/badge.go` (create) | `Data` struct, `Render` (SVG bytes), `Shields` (endpoint JSON), `humanTokens`. Self-contained: imports only stdlib. |
| `internal/badge/badge_test.go` (create) | No-external-reference guard, stable-render golden, humanize table. |
| `cmd/ccquota/badge.go` (create) | The `ccquota badge` subcommand: flags, DB read, file write. |
| `cmd/ccquota/badge_test.go` (create) | Period parsing; end-to-end write against a temp DB. |
| `cmd/ccquota/main.go` (modify) | Dispatch `badge` and `team`; usage text. |
| `internal/store/schema.sql` (modify) | `endpoints.team` column. |
| `internal/store/store.go` (modify) | `migrate` entry; `Endpoint.Team`; `endpointColumns`/`scanEndpoint` lockstep; `SetEndpointTeam`. |
| `internal/store/query.go` (modify) | `ByTeam` dimension + join expression; `labelTeams`; `tokenSumExpr` const; `UserSummary`; `UsageByUser`. |
| `internal/store/team_test.go` (create) | Team assignment, join grouping, ingest-cannot-set-team regression. |
| `internal/store/user_test.go` (create) | `UserSummary` and `UsageByUser`. |
| `cmd/ccquota/team.go` (create) | `ccquota team --list` / `--endpoint <id> --set <name>`. |
| `internal/api/user.go` (create) | `/v1/user` data handler and `/u/` page handler. |
| `internal/api/badge.go` (create) | `/badge/u/<login>.svg`, `/badge/team/<name>.svg`, shields JSON variants. |
| `internal/api/server.go` (modify) | Mount the new routes; `PublicBadges bool` field. |
| `internal/api/badge_test.go` (create) | Route auth matrix, content-type, cache-control, unknown-handle 404. |
| `cmd/ccquota/hub.go` (modify) | `--public-badges` flag. |
| `web/dist/user.html` (create) | The `/u/<login>` page. |
| `web/dist/index.html` (modify) | Team card (landing position when teams exist), login links to `/u/`. |
| `web/embed_test.go` (modify) | `user.html` embedded; team card precedes user card; no rank numerals. |
| `README.md` (modify) | Document `ccquota badge`, `ccquota team`, `--public-badges`. |

---

### Task 1: `internal/badge` — the renderer

**Files:**
- Create: `internal/badge/badge.go`
- Test: `internal/badge/badge_test.go`

**Interfaces:**
- Consumes: nothing (stdlib only).
- Produces:
  - `type Data struct { Tokens int64; Turns int64; Period string; Theme string }`
  - `func (d Data) LabelText() string`
  - `func (d Data) MessageText() string`
  - `func Render(d Data) []byte`
  - `type Shields struct { SchemaVersion int; Label, Message, Color string }`
  - `func ToShields(d Data) Shields`
  - `func HumanTokens(n int64) string`

- [ ] **Step 1: Write the failing test**

Create `internal/badge/badge_test.go`:

```go
package badge

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestHumanTokens(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{999, "999"},
		{1000, "1K"},
		{1500, "1.5K"},
		{999_999, "1M"},
		{54_000_000_000, "54B"},
		{69_845_943_231, "69.8B"},
		{1_500_000_000_000, "1.5T"},
	}
	for _, c := range cases {
		if got := HumanTokens(c.in); got != c.want {
			t.Errorf("HumanTokens(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The badge is loaded through <img>, which is a sandboxed context: no scripts,
// no external fonts, no external CSS, no network. A single external reference
// does not error — it silently renders a badge with the wrong type in it.
func TestRender_HasNoExternalReference(t *testing.T) {
	svg := string(Render(Data{Tokens: 69_845_943_231, Turns: 267_607, Period: "all", Theme: "dark"}))
	for _, forbidden := range []string{
		"http://", "https://", "@import", "<image", "xlink:href", "url(", "<script", "<foreignObject",
	} {
		if strings.Contains(svg, forbidden) {
			t.Errorf("rendered badge contains %q; an <img>-loaded SVG cannot fetch anything", forbidden)
		}
	}
}

// A timestamp on a badge is wrong within the hour and stays on a profile for a
// week. The period is a label instead.
func TestRender_CarriesPeriodNotTimestamp(t *testing.T) {
	svg := string(Render(Data{Tokens: 100, Period: "30d", Theme: "light"}))
	if !strings.Contains(svg, "30d") {
		t.Error("badge does not carry its period label")
	}
	if regexp.MustCompile(`\d{4}-\d{2}-\d{2}`).MatchString(svg) {
		t.Error("badge carries a date; camo caches it and it will be wrong within the hour")
	}
}

func TestRender_ThemesDiffer(t *testing.T) {
	dark := string(Render(Data{Tokens: 1, Theme: "dark"}))
	light := string(Render(Data{Tokens: 1, Theme: "light"}))
	if dark == light {
		t.Error("dark and light render identically; ?theme= does nothing")
	}
}

func TestRender_IsStableForTheSameInput(t *testing.T) {
	d := Data{Tokens: 42_000, Turns: 7, Period: "all", Theme: "dark"}
	if string(Render(d)) != string(Render(d)) {
		t.Error("render is not deterministic; camo would cache one of two badges at random")
	}
}

func TestRender_EscapesText(t *testing.T) {
	svg := string(Render(Data{Tokens: 1, Period: `a<b&"c`, Theme: "dark"}))
	if strings.Contains(svg, `a<b&"c`) {
		t.Error("period is interpolated raw; that produces invalid XML")
	}
	if !strings.Contains(svg, "a&lt;b&amp;&quot;c") {
		t.Error("period is not XML-escaped")
	}
}

func TestToShields_MatchesEndpointSchema(t *testing.T) {
	b, err := json.Marshal(ToShields(Data{Tokens: 69_845_943_231, Period: "all", Theme: "dark"}))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	// shields.io's documented endpoint schema: schemaVersion MUST be 1, and
	// label/message/color are the fields it reads.
	if got["schemaVersion"] != float64(1) {
		t.Errorf("schemaVersion = %v, want 1; shields rejects anything else", got["schemaVersion"])
	}
	for _, k := range []string{"label", "message", "color"} {
		if s, ok := got[k].(string); !ok || s == "" {
			t.Errorf("shields JSON field %q is missing or empty", k)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./internal/badge/...`
Expected: FAIL — `no Go files in .../internal/badge` (the package does not exist yet).

- [ ] **Step 3: Write the implementation**

Create `internal/badge/badge.go`:

```go
// Package badge renders a usage figure as an SVG and as shields.io endpoint
// JSON.
//
// The renderer is deliberately self-contained — stdlib only, no store, no
// http — because the same bytes are produced in three places: the local
// `ccquota badge` command, the hub's badge routes, and (later) the public
// badges service. A renderer that reached into a database could not be the
// one used by a command that must work with no network at all.
//
// THE CONSTRAINT THAT SHAPES THIS FILE: an SVG loaded through <img> — which is
// what a README, a profile and a Pages site all do — is a sandboxed context.
// No scripts, no external fonts, no external CSS, no network. Everything is
// inline, and a test asserts it stays that way, because an external reference
// does not error: it silently renders the wrong thing.
package badge

import (
	"fmt"
	"strconv"
	"strings"
)

// Data is everything a badge can say.
//
// Note what is absent: no project path, no machine name, no OS login, no
// account email, no utilization. The badge is the one artifact that ends up
// somewhere permanent and public, so the type simply cannot carry them.
type Data struct {
	Tokens int64
	Turns  int64
	// Period labels the window: "all", or "30d"/"7d". Never a timestamp —
	// camo caches the badge, so any absolute time it showed would be wrong.
	Period string
	// Theme is "dark" or "light", chosen explicitly by the caller.
	Theme string
}

// LabelText is the left half of the badge.
func (d Data) LabelText() string {
	if d.Period == "" || d.Period == "all" {
		return "ccquota"
	}
	return "ccquota " + d.Period
}

// MessageText is the right half: the figure itself.
func (d Data) MessageText() string { return HumanTokens(d.Tokens) + " tokens" }

// palette is one theme's colors. Both are defined here rather than one being
// derived from the other, so neither can drift into unreadable contrast.
type palette struct {
	labelBG, msgBG, labelFG, msgFG string
}

func paletteFor(theme string) palette {
	if theme == "light" {
		return palette{labelBG: "#4a4f5a", msgBG: "#a65a0a", labelFG: "#ffffff", msgFG: "#ffffff"}
	}
	// Dark is the default: an unset theme must still render, and a README
	// author who never passes ?theme= gets the one that reads on both grounds.
	return palette{labelBG: "#2b3038", msgBG: "#e29a4b", labelFG: "#e6e8ec", msgFG: "#1a1206"}
}

const (
	svgHeight = 20
	fontSize  = 11
	padX      = 6
	// charW is an advance estimate, not a measurement. There is no font metric
	// available in a sandboxed SVG and no webfont may be loaded, so the width
	// is computed from a conservative per-character advance for the system
	// stack below. Slightly wide is harmless; too narrow clips the text.
	charW = 7
	// fontStack is a system stack on purpose. A webfont will not load here at
	// all, so these are faces that already exist on the reader's machine.
	fontStack = "Verdana,DejaVu Sans,Geneva,sans-serif"
)

func textWidth(s string) int { return len([]rune(s))*charW + 2*padX }

// Render returns the badge as SVG bytes.
func Render(d Data) []byte {
	p := paletteFor(d.Theme)
	label, msg := d.LabelText(), d.MessageText()
	lw, mw := textWidth(label), textWidth(msg)
	total := lw + mw

	var b strings.Builder
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" `+
		`viewBox="0 0 %d %d" role="img" aria-label="%s: %s">`,
		total, svgHeight, total, svgHeight, esc(label), esc(msg))
	fmt.Fprintf(&b, `<title>%s: %s</title>`, esc(label), esc(msg))
	fmt.Fprintf(&b, `<rect width="%d" height="%d" rx="3" fill="%s"/>`, total, svgHeight, p.labelBG)
	fmt.Fprintf(&b, `<path fill="%s" d="M%d 0h%dv%dH%dz"/>`, p.msgBG, lw, mw, svgHeight, lw)
	// Re-round the right corners the path above squared off.
	fmt.Fprintf(&b, `<rect x="%d" width="%d" height="%d" rx="3" fill="%s"/>`,
		lw, mw, svgHeight, p.msgBG)
	fmt.Fprintf(&b, `<rect x="%d" width="6" height="%d" fill="%s"/>`, lw, svgHeight, p.msgBG)
	fmt.Fprintf(&b, `<g font-family="%s" font-size="%d">`, fontStack, fontSize)
	fmt.Fprintf(&b, `<text x="%d" y="14" fill="%s">%s</text>`, padX, p.labelFG, esc(label))
	fmt.Fprintf(&b, `<text x="%d" y="14" fill="%s">%s</text>`, lw+padX, p.msgFG, esc(msg))
	b.WriteString(`</g></svg>`)
	return []byte(b.String())
}

// esc XML-escapes badge text. The period is caller-supplied, so an unescaped
// interpolation is how a badge becomes invalid XML and renders as nothing.
func esc(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&apos;")
	return r.Replace(s)
}

// Shields is shields.io's documented endpoint schema.
type Shields struct {
	SchemaVersion int    `json:"schemaVersion"`
	Label         string `json:"label"`
	Message       string `json:"message"`
	Color         string `json:"color"`
}

// ToShields converts to the endpoint schema shields.io fetches from a URL you
// supply — the serverless publishing path that needs no service of ours.
func ToShields(d Data) Shields {
	return Shields{
		SchemaVersion: 1,
		Label:         d.LabelText(),
		Message:       d.MessageText(),
		Color:         strings.TrimPrefix(paletteFor(d.Theme).msgBG, "#"),
	}
}

// HumanTokens renders a token count at badge width.
//
// Exact counts are for the dashboard. A badge has room for three significant
// figures, and "69.8B" is the number a reader actually takes away.
func HumanTokens(n int64) string {
	if n < 0 {
		n = 0
	}
	units := []struct {
		limit int64
		suf   string
	}{
		{1_000_000_000_000, "T"},
		{1_000_000_000, "B"},
		{1_000_000, "M"},
		{1_000, "K"},
	}
	for _, u := range units {
		if n >= u.limit {
			v := float64(n) / float64(u.limit)
			// One decimal, but never a trailing ".0" — "54B" not "54.0B".
			s := strconv.FormatFloat(v, 'f', 1, 64)
			s = strings.TrimSuffix(s, ".0")
			return s + u.suf
		}
	}
	return strconv.FormatInt(n, 10)
}
```

Note on `999_999 → "1M"`: 999999/1000 = 999.999 which formats to "1000.0" → "1000K", not "1M". Handle it by rounding up into the next unit first:

```go
	for _, u := range units {
		if n >= u.limit {
			v := float64(n) / float64(u.limit)
			s := strconv.FormatFloat(v, 'f', 1, 64)
			// 999_999/1_000 rounds to "1000.0" — promote it rather than
			// printing a four-digit mantissa.
			if strings.HasPrefix(s, "1000") {
				continue
			}
			s = strings.TrimSuffix(s, ".0")
			return s + u.suf
		}
	}
```

Order the units largest-first (as above) and add the promotion check; verify against the table in Step 1 and adjust until every case passes.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./internal/badge/... -v`
Expected: PASS, all seven tests.

- [ ] **Step 5: Vet and commit**

```bash
cd ~/projects/ccquota
gofmt -l internal/badge && go vet ./internal/badge/...
git add internal/badge/
git commit -m "feat(badge): render a usage badge as SVG and shields JSON

An <img>-loaded SVG is a sandboxed context: no scripts, no external
fonts, no network. A test asserts no external reference survives,
because one does not error -- it silently renders the wrong thing."
```

---

### Task 2: `ccquota badge` — the local command

**Files:**
- Create: `cmd/ccquota/badge.go`
- Modify: `cmd/ccquota/main.go`
- Test: `cmd/ccquota/badge_test.go`

**Interfaces:**
- Consumes: `badge.Data`, `badge.Render`, `badge.ToShields` (Task 1); `store.Open`, `store.LifetimeTotals`, `store.UsageBy`, `store.AllAccounts`, `store.ByAccount` (existing); `resolveExistingDB` (existing, `cmd/ccquota/db.go`).
- Produces: `func runBadge(args []string) error`, `func periodRange(period string, now time.Time) (start time.Time, all bool, err error)`.

- [ ] **Step 1: Write the failing test**

Create `cmd/ccquota/badge_test.go`:

```go
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPeriodRange(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)

	if _, all, err := periodRange("all", now); err != nil || !all {
		t.Errorf(`periodRange("all") = all:%v err:%v, want all:true nil`, all, err)
	}
	if _, all, err := periodRange("", now); err != nil || !all {
		t.Errorf(`periodRange("") should default to all-time, got all:%v err:%v`, all, err)
	}
	start, all, err := periodRange("30d", now)
	if err != nil || all {
		t.Fatalf(`periodRange("30d") = all:%v err:%v`, all, err)
	}
	if want := now.AddDate(0, 0, -30); !start.Equal(want) {
		t.Errorf("start = %v, want %v", start, want)
	}
	// A period Go's ParseDuration would accept but that means nothing here
	// must be refused rather than silently treated as all-time -- a badge
	// showing a lifetime total under a "7d" label is a lie.
	for _, bad := range []string{"7", "1w", "24h", "-3d", "abc"} {
		if _, _, err := periodRange(bad, now); err == nil {
			t.Errorf("periodRange(%q) was accepted; it must be refused", bad)
		}
	}
}

func TestRunBadge_WritesSVGWithoutNetwork(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db)

	out := filepath.Join(dir, "ccquota.svg")
	if err := runBadge([]string{"--db", db, "--out", out, "--theme", "dark", "--period", "all"}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	svg := string(b)
	if !strings.HasPrefix(svg, "<svg") {
		t.Fatalf("output is not an SVG: %.40q", svg)
	}
	if !strings.Contains(svg, "tokens") {
		t.Error("badge does not carry a token figure")
	}
	for _, forbidden := range []string{"http://", "https://"} {
		if strings.Contains(svg, forbidden) {
			t.Errorf("locally rendered badge contains %q", forbidden)
		}
	}
}

func TestRunBadge_WritesShieldsJSON(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db)

	out := filepath.Join(dir, "ccquota.json")
	if err := runBadge([]string{"--db", db, "--json", "--out", out}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("output is not JSON: %v", err)
	}
	if got["schemaVersion"] != float64(1) {
		t.Errorf("schemaVersion = %v, want 1", got["schemaVersion"])
	}
}

// The command reads and never writes, so it must refuse to bring a database
// into being -- a badge rendered from an empty accidental database reports
// zero and looks like a working badge.
func TestRunBadge_RefusesMissingDatabase(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope.db")
	err := runBadge([]string{"--db", missing, "--out", filepath.Join(t.TempDir(), "x.svg")})
	if err == nil {
		t.Fatal("runBadge created or accepted a missing database; it must refuse")
	}
	if _, statErr := os.Stat(missing); statErr == nil {
		t.Error("runBadge created the database file")
	}
}
```

Add the seed helper to the same file:

```go
func seedBadgeDB(t *testing.T, path string) {
	t.Helper()
	st, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	id := model.Identity{AccountUUID: "acct-1", Email: "a@example.com", Hostname: "h1"}
	if err := st.UpsertAccount(id, "max", "tier"); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("ep-1", "ep-1", "hash-1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.TouchEndpoint("ep-1", id, "test", true); err != nil {
		t.Fatal(err)
	}
	cost := 1.5
	_, _, err = st.InsertEvents([]model.UsageEvent{{
		AccountUUID: "acct-1", EndpointID: "ep-1", MessageUUID: "m1",
		TS: time.Now().UTC().Add(-time.Hour), Model: "claude-opus-5",
		InputTokens: 1000, OutputTokens: 2000, CostUSD: &cost,
		CWD: "/w", OSUser: "alice",
	}})
	if err != nil {
		t.Fatal(err)
	}
}
```

with imports `"github.com/verkyyi/ccquota/internal/model"` and `"github.com/verkyyi/ccquota/internal/store"`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./cmd/ccquota/ -run 'Badge|PeriodRange'`
Expected: FAIL — `undefined: runBadge`, `undefined: periodRange`.

- [ ] **Step 3: Write the implementation**

Create `cmd/ccquota/badge.go`:

```go
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"time"

	"github.com/verkyyi/ccquota/internal/badge"
	"github.com/verkyyi/ccquota/internal/store"
)

// dayPeriod matches the only relative window a badge may carry.
//
// Go's time.ParseDuration has no day unit and would accept "24h" while
// rejecting "30d", which is backwards for a badge: the label a reader
// understands is days. Anything else is refused rather than quietly falling
// back to all-time, because a lifetime figure under a "7d" label is a lie.
var dayPeriod = regexp.MustCompile(`^([1-9][0-9]*)d$`)

func periodRange(period string, now time.Time) (start time.Time, all bool, err error) {
	if period == "" || period == "all" {
		return time.Time{}, true, nil
	}
	m := dayPeriod.FindStringSubmatch(period)
	if m == nil {
		return time.Time{}, false, fmt.Errorf(
			"unknown period %q: use \"all\" or a number of days like \"30d\"", period)
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return time.Time{}, false, fmt.Errorf("unknown period %q", period)
	}
	return now.AddDate(0, 0, -n), false, nil
}

func runBadge(args []string) error {
	fs := flag.NewFlagSet("badge", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	out := fs.String("out", "", "write to this file (default: stdout)")
	theme := fs.String("theme", "dark", "\"dark\" or \"light\"; chosen explicitly because a badge\n"+
		"loaded through <img> cannot read the reader's color scheme")
	period := fs.String("period", "all", "\"all\", or a window like \"30d\"")
	asJSON := fs.Bool("json", false, "emit shields.io endpoint JSON instead of an SVG")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota badge --out ccquota.svg --theme dark --period all
  ccquota badge --json --out ccquota.json      # shields.io endpoint schema

Renders this hub's totals as a badge. Entirely local: no server, no account,
no submission, and the rendered SVG contains no external reference of any kind
(an <img>-loaded SVG cannot fetch scripts, fonts, CSS or images).

Publish the result however you like -- commit the SVG to a profile repo and
reference it by raw.githubusercontent.com, or write the JSON to a gist and
point img.shields.io at it.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *theme != "dark" && *theme != "light" {
		return fmt.Errorf("unknown theme %q: use \"dark\" or \"light\"", *theme)
	}

	dbFile, err := resolveExistingDB(*dbPath)
	if err != nil {
		return err
	}
	st, err := store.Open(dbFile)
	if err != nil {
		return err
	}
	defer st.Close()

	d, err := badgeData(st, *period, *theme)
	if err != nil {
		return err
	}

	var payload []byte
	if *asJSON {
		payload, err = json.MarshalIndent(badge.ToShields(d), "", "  ")
		if err != nil {
			return fmt.Errorf("encode shields JSON: %w", err)
		}
		payload = append(payload, '\n')
	} else {
		payload = badge.Render(d)
	}

	if *out == "" {
		_, err = os.Stdout.Write(payload)
		return err
	}
	if err := os.WriteFile(*out, payload, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", *out, err)
	}
	fmt.Fprintf(os.Stderr, "wrote %s (%s, %s)\n", *out, d.LabelText(), d.MessageText())
	return nil
}

// badgeData reads the figure the badge shows.
//
// All-time uses LifetimeTotals, which is the same expression every other
// total on this hub uses. A windowed period sums the per-account buckets and
// discards their keys -- the badge must never carry an account identifier.
func badgeData(st *store.Store, period, theme string) (badge.Data, error) {
	d := badge.Data{Period: period, Theme: theme}
	if d.Period == "" {
		d.Period = "all"
	}

	start, all, err := periodRange(period, time.Now().UTC())
	if err != nil {
		return d, err
	}
	if all {
		turns, tokens, err := st.LifetimeTotals()
		if err != nil {
			return d, err
		}
		d.Turns, d.Tokens = turns, tokens
		return d, nil
	}

	buckets, err := st.UsageBy(store.AllAccounts, store.ByAccount, start, time.Now().UTC(), 1000)
	if err != nil {
		return d, err
	}
	for _, b := range buckets {
		d.Turns += b.Events
		d.Tokens += b.Tokens
	}
	return d, nil
}
```

- [ ] **Step 4: Wire it into the CLI**

In `cmd/ccquota/main.go`, add to the `switch os.Args[1]` block, after the `case "share":` line:

```go
	case "badge":
		err = runBadge(os.Args[2:])
```

and in `usage()`, after the `ccquota share` line:

```
  ccquota badge  [flags]    Render this hub's totals as an SVG badge (local,
                            no network) or as shields.io endpoint JSON
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./cmd/ccquota/ -run 'Badge|PeriodRange' -v && go build ./...`
Expected: PASS on all four tests; build succeeds.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/ccquota
gofmt -l cmd/ccquota internal/badge && go vet ./...
git add cmd/ccquota/badge.go cmd/ccquota/badge_test.go cmd/ccquota/main.go
git commit -m "feat(cli): ccquota badge renders the local totals, no service needed

Publishing is pluggable -- commit the SVG, or point shields at the JSON.
A period that is not \"all\" or \"<N>d\" is refused rather than falling
back to all-time: a lifetime figure under a \"7d\" label is a lie."
```

---

### Task 3: `team` as a store dimension

**Files:**
- Modify: `internal/store/schema.sql`, `internal/store/store.go`, `internal/store/query.go`
- Test: `internal/store/team_test.go`

**Interfaces:**
- Consumes: existing `Store`, `Dimension`, `Bucket`, `UsageBy`.
- Produces: `store.ByTeam Dimension = "team"`, `func (s *Store) SetEndpointTeam(endpointID, team string) error`, `Endpoint.Team string`.

- [ ] **Step 1: Write the failing test**

Create `internal/store/team_test.go`:

```go
package store

import (
	"testing"
	"time"
)

func TestSetEndpointTeam(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")

	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if len(eps) != 1 || eps[0].Team != "platform" {
		t.Fatalf("team not stored: %+v", eps)
	}

	// Naming a machine that is not enrolled is an operator typo, and silently
	// succeeding leaves them believing a team was assigned.
	if err := s.SetEndpointTeam("ep-nope", "platform"); err == nil {
		t.Error("SetEndpointTeam accepted an unknown endpoint")
	}
}

func TestUsageBy_Team(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")
	seedAccount(t, s, "acct-1", "ep-2")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	// ep-2 is deliberately left unassigned.

	if _, _, err := s.InsertEvents([]model.UsageEvent{
		ev("acct-1", "ep-1", "m1", 100),
		ev("acct-1", "ep-2", "m2", 30),
	}); err != nil {
		t.Fatal(err)
	}

	start := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
	buckets, err := s.UsageBy(AllAccounts, ByTeam, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	labels := map[string]string{}
	for _, b := range buckets {
		got[b.Key] = b.Tokens
		labels[b.Key] = b.Label
	}
	if got["platform"] != 100 {
		t.Errorf("platform tokens = %d, want 100", got["platform"])
	}
	// An endpoint with no team must still appear. Dropping it would make the
	// team totals silently smaller than the fleet total.
	if got[""] != 30 {
		t.Errorf("unassigned tokens = %d, want 30", got[""])
	}
	if labels[""] != "unassigned" {
		t.Errorf("unassigned bucket label = %q, want \"unassigned\"", labels[""])
	}
}

// Team is resolved by join, never stored on the event row. Re-assigning a
// machine must move its whole history, not just turns ingested afterwards.
func TestUsageBy_TeamFollowsReassignment(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-1", "ep-1", "m1", 100)}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetEndpointTeam("ep-1", "infra"); err != nil {
		t.Fatal(err)
	}

	start := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
	buckets, err := s.UsageBy(AllAccounts, ByTeam, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range buckets {
		if b.Key == "platform" {
			t.Fatal("history stayed on the old team; team is being frozen at ingest")
		}
		if b.Key == "infra" && b.Tokens != 100 {
			t.Errorf("infra tokens = %d, want the full 100", b.Tokens)
		}
	}
}

// An endpoint that could name its own team could move its spend onto another
// team's budget. Only the operator assigns teams, so the ingest path must not
// touch the column.
func TestTouchEndpoint_CannotSetOrClearTeam(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-1"), "v-test", true); err != nil {
		t.Fatal(err)
	}
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if eps[0].Team != "platform" {
		t.Fatalf("an ingest push changed the team to %q", eps[0].Team)
	}
}
```

Add `"github.com/verkyyi/ccquota/internal/model"` to the imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./internal/store/ -run Team`
Expected: FAIL — `undefined: ByTeam`, `undefined: SetEndpointTeam`, `e.Team undefined`.

- [ ] **Step 3: Add the column**

In `internal/store/schema.sql`, inside `CREATE TABLE IF NOT EXISTS endpoints (...)`, after the `os_user` block and before `enrolled_at`:

```sql
  -- The team this endpoint's spend is allocated to.
  --
  -- Assigned by the operator, never reported by the endpoint. An endpoint that
  -- could name its own team could move its spend onto another team's budget,
  -- for the same reason a public submission may not name its own handle.
  team          TEXT NOT NULL DEFAULT '',
```

In `internal/store/store.go`, add to the `adds` slice in `migrate`:

```go
		{"endpoints", "team", "TEXT NOT NULL DEFAULT ''"},
```

- [ ] **Step 4: Extend the Endpoint type, in lockstep**

In `internal/store/store.go`, add to `type Endpoint struct`, after `OSUser`:

```go
	// Team is the operator's allocation of this endpoint's spend. Empty means
	// unassigned, which the UI renders as "unassigned" rather than hiding.
	Team string `json:"team"`
```

Add `team` to `endpointColumns` (it is documented as being kept in lockstep with `scanEndpoint`, and they drifted apart once already):

```go
const endpointColumns = `
	SELECT endpoint_id, account_uuid, label, hostname, os, arch, machine_id,
	       cc_version, agent_version, os_user, team, enrolled_at, last_seen,
	       dropped_pre_account, earliest_dropped, dropped_beyond_backfill,
	       backfill_limit, limits_unavailable`
```

and to `scanEndpoint`'s `row.Scan` call, in the same position:

```go
	err := row.Scan(&e.ID, &account, &e.Label, &e.Hostname, &e.OS, &e.Arch,
		&e.MachineID, &e.CCVersion, &e.AgentVersion, &e.OSUser, &e.Team, &enrolled, &lastSeen,
		&e.DroppedPreAccount, &earliest, &e.DroppedBeyondBackfill,
		&e.BackfillLimit, &e.LimitsUnavailable)
```

Add `SetEndpointTeam` at the end of `internal/store/store.go`:

```go
// SetEndpointTeam allocates an endpoint's spend to a team.
//
// Operator-side on purpose: this is the only writer of endpoints.team, and the
// ingest path (TouchEndpoint) deliberately does not name the column. Passing an
// empty team un-assigns it.
func (s *Store) SetEndpointTeam(endpointID, team string) error {
	if endpointID == "" {
		return fmt.Errorf("endpoint id is required")
	}
	res, err := s.db.Exec(`UPDATE endpoints SET team = ? WHERE endpoint_id = ?`, team, endpointID)
	if err != nil {
		return fmt.Errorf("set endpoint team: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no endpoint %q on this hub (run `ccquota team --list` to see them)", endpointID)
	}
	return nil
}
```

- [ ] **Step 5: Add the dimension**

In `internal/store/query.go`, add to the `const` block of dimensions, after `ByUser`:

```go
	// ByTeam allocates spend to an operator-assigned team.
	//
	// It is the one dimension not stored on the event row. Team is a property
	// of the endpoint, resolved by join at query time, so re-assigning a
	// machine moves its WHOLE history -- freezing a team at ingest would mean
	// a re-assignment silently changed nothing that had already happened.
	ByTeam Dimension = "team"
```

In `func (d Dimension) column()`, add before `default:`:

```go
	case ByTeam:
		return `COALESCE((SELECT e.team FROM endpoints e
		                  WHERE e.endpoint_id = usage_events.endpoint_id), '')`, nil
```

In `UsageBy`, add to the labelling switch at the end:

```go
	case ByTeam:
		labelTeams(out)
```

and add the labeller beside `labelEndpoints`:

```go
// labelTeams names the empty team.
//
// An unassigned endpoint keeps its bucket rather than being filtered out: a
// team breakdown whose rows do not add up to the fleet total is worse than one
// with an "unassigned" row in it.
func labelTeams(bs []Bucket) {
	for i := range bs {
		if bs[i].Key == "" {
			bs[i].Label = "unassigned"
			continue
		}
		bs[i].Label = bs[i].Key
	}
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./internal/store/... -v -run Team`
Expected: PASS on all four tests.

- [ ] **Step 7: Run the whole suite (the endpointColumns change touches everything)**

Run: `cd ~/projects/ccquota && go test ./...`
Expected: PASS, 13 packages. A failure here means `endpointColumns` and `scanEndpoint` drifted — recount the columns.

- [ ] **Step 8: Commit**

```bash
cd ~/projects/ccquota
gofmt -l internal/store && go vet ./...
git add internal/store/
git commit -m "feat(store): team as a dimension, resolved by join not stored per event

Operator-assigned only: an endpoint that could name its own team could
move its spend onto another team's budget. Resolving by join means a
re-assignment moves the whole history, not just future turns."
```

---

### Task 4: `ccquota team` — assignment from the CLI

**Files:**
- Create: `cmd/ccquota/team.go`
- Modify: `cmd/ccquota/main.go`
- Test: `cmd/ccquota/team_test.go`

**Interfaces:**
- Consumes: `store.SetEndpointTeam`, `store.ListEndpoints` (Task 3); `resolveExistingDB`.
- Produces: `func runTeam(args []string) error`.

- [ ] **Step 1: Write the failing test**

Create `cmd/ccquota/team_test.go`:

```go
package main

import (
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/store"
)

func TestRunTeam_AssignsAndRefusesUnknown(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db) // enrolls ep-1

	if err := runTeam([]string{"--db", db, "--endpoint", "ep-1", "--set", "platform"}); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	eps, err := st.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if eps[0].Team != "platform" {
		t.Fatalf("team = %q, want platform", eps[0].Team)
	}

	if err := runTeam([]string{"--db", db, "--endpoint", "ghost", "--set", "platform"}); err == nil {
		t.Error("assigning a team to an unknown endpoint was accepted")
	}
}

func TestRunTeam_RequiresSomethingToDo(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db)
	if err := runTeam([]string{"--db", db}); err == nil {
		t.Error("runTeam with no flags did nothing and reported success")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./cmd/ccquota/ -run Team`
Expected: FAIL — `undefined: runTeam`.

- [ ] **Step 3: Write the implementation**

Create `cmd/ccquota/team.go`:

```go
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/verkyyi/ccquota/internal/store"
)

func runTeam(args []string) error {
	fs := flag.NewFlagSet("team", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	endpoint := fs.String("endpoint", "", "the `endpoint id` to assign")
	set := fs.String("set", "", "the team `name`; pass an empty string to un-assign")
	list := fs.Bool("list", false, "list every endpoint and its team")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota team --list                              who is on which team
  ccquota team --endpoint <id> --set <team>        allocate a machine's spend
  ccquota team --endpoint <id> --set ""            un-assign it

Teams are assigned here, on the hub, and never reported by an endpoint: a
machine that could name its own team could move its spend onto another team's
budget. Team is resolved when a query runs, so re-assigning a machine moves its
whole history, not just what it does next.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}

	dbFile, err := resolveExistingDB(*dbPath)
	if err != nil {
		return err
	}
	st, err := store.Open(dbFile)
	if err != nil {
		return err
	}
	defer st.Close()

	switch {
	case *endpoint != "":
		if err := st.SetEndpointTeam(*endpoint, *set); err != nil {
			return err
		}
		if *set == "" {
			fmt.Printf("%s is now unassigned\n", *endpoint)
		} else {
			fmt.Printf("%s is now on %q\n", *endpoint, *set)
		}
		return nil

	case *list:
		eps, err := st.ListEndpoints("")
		if err != nil {
			return err
		}
		if len(eps) == 0 {
			fmt.Println("no endpoints are enrolled on this hub")
			return nil
		}
		fmt.Printf("%-24s  %-20s  %s\n", "ENDPOINT", "TEAM", "MACHINE")
		for _, e := range eps {
			team := e.Team
			if team == "" {
				team = "(unassigned)"
			}
			name := e.Label
			if name == "" {
				name = e.Hostname
			}
			fmt.Printf("%-24s  %-20s  %s\n", e.ID, team, name)
		}
		return nil

	default:
		fs.Usage()
		return fmt.Errorf("nothing to do: pass --list, or --endpoint with --set")
	}
}
```

- [ ] **Step 4: Wire it into the CLI**

In `cmd/ccquota/main.go`, after `case "badge":`:

```go
	case "team":
		err = runTeam(os.Args[2:])
```

and in `usage()`, after the badge line:

```
  ccquota team   [flags]    Allocate an endpoint's spend to a team
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./cmd/ccquota/ -v -run Team && go build ./...`
Expected: PASS on both tests.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/ccquota
gofmt -l cmd/ccquota && go vet ./...
git add cmd/ccquota/team.go cmd/ccquota/team_test.go cmd/ccquota/main.go
git commit -m "feat(cli): ccquota team assigns an endpoint's spend to a team"
```

---

### Task 5: per-user queries in the store

**Files:**
- Modify: `internal/store/query.go`
- Test: `internal/store/user_test.go`

**Interfaces:**
- Consumes: existing `Store`, `Bucket`, `Dimension`.
- Produces:
  - `const tokenSumExpr string`
  - `type UserSummary struct { OSUser string; Teams []string; Turns, Tokens int64; CostUSD float64; Projects, Machines int }`
  - `func (s *Store) UserSummary(osUser string, start, end time.Time) (*UserSummary, error)`
  - `func (s *Store) UsageByUser(osUser string, d Dimension, start, end time.Time, limit int) ([]Bucket, error)`

- [ ] **Step 1: Write the failing test**

Create `internal/store/user_test.go`:

```go
package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func userEv(account, endpoint, uuid, osUser, cwd string, out int64) model.UsageEvent {
	c := 2.0
	return model.UsageEvent{
		AccountUUID: account, EndpointID: endpoint, MessageUUID: uuid,
		SessionID: "s-" + uuid, TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
		Model: "claude-opus-5", OutputTokens: out, CostUSD: &c,
		CWD: cwd, OSUser: osUser, GitBranch: "main",
	}
}

func seedUsers(t *testing.T, s *Store) (start, end time.Time) {
	t.Helper()
	seedAccount(t, s, "acct-1", "ep-1")
	seedAccount(t, s, "acct-1", "ep-2")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep-1", "m1", "alice", "/repo/a", 100),
		userEv("acct-1", "ep-2", "m2", "alice", "/repo/b", 50),
		userEv("acct-1", "ep-1", "m3", "bob", "/repo/a", 7),
	}); err != nil {
		t.Fatal(err)
	}
	return time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
}

func TestUserSummary(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	got, err := s.UserSummary("alice", start, end)
	if err != nil {
		t.Fatal(err)
	}
	if got.Turns != 2 {
		t.Errorf("turns = %d, want 2", got.Turns)
	}
	if got.Tokens != 150 {
		t.Errorf("tokens = %d, want 150", got.Tokens)
	}
	if got.Projects != 2 {
		t.Errorf("projects = %d, want 2", got.Projects)
	}
	if got.Machines != 2 {
		t.Errorf("machines = %d, want 2", got.Machines)
	}
	// alice works on one assigned machine and one unassigned one. Reporting a
	// single team would attribute half her spend to a team that never got it.
	if len(got.Teams) != 1 || got.Teams[0] != "platform" {
		t.Errorf("teams = %v, want [platform]", got.Teams)
	}
}

// An unknown login is not an error -- it is a page that says "no usage".
func TestUserSummary_UnknownLoginIsEmptyNotAnError(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)
	got, err := s.UserSummary("nobody", start, end)
	if err != nil {
		t.Fatal(err)
	}
	if got.Turns != 0 || got.Tokens != 0 {
		t.Errorf("unknown login reported usage: %+v", got)
	}
}

func TestUsageByUser_ScopesToOneLogin(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	buckets, err := s.UsageByUser("alice", ByProject, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	total := int64(0)
	for _, b := range buckets {
		total += b.Tokens
		if b.Key == "/repo/a" && b.Tokens != 100 {
			t.Errorf("/repo/a = %d tokens, want 100 (bob's 7 must not be included)", b.Tokens)
		}
	}
	if total != 150 {
		t.Errorf("total across alice's projects = %d, want 150", total)
	}
}

// The two totals on the page come from different queries. If their token
// expressions ever diverge by a cache column, the page contradicts itself.
func TestUserSummary_AgreesWithUsageByUser(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	sum, err := s.UserSummary("alice", start, end)
	if err != nil {
		t.Fatal(err)
	}
	buckets, err := s.UsageByUser("alice", ByProject, start, end, 1000)
	if err != nil {
		t.Fatal(err)
	}
	var viaBuckets int64
	for _, b := range buckets {
		viaBuckets += b.Tokens
	}
	if sum.Tokens != viaBuckets {
		t.Errorf("summary says %d tokens, the breakdown sums to %d", sum.Tokens, viaBuckets)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./internal/store/ -run User`
Expected: FAIL — `undefined: UserSummary`, `undefined: UsageByUser`.

- [ ] **Step 3: Extract the token expression**

In `internal/store/query.go`, above the `Bucket` type, add:

```go
// tokenSumExpr is THE definition of "tokens" on this hub.
//
// It exists as one constant because two totals on one page that disagree by a
// cache-creation column would be worse than either -- LifetimeTotals already
// carries a comment saying so. Every query that sums tokens uses this.
const tokenSumExpr = `SUM(input_tokens + output_tokens + cache_create_5m_tokens
                          + cache_create_1h_tokens + cache_read_tokens)`
```

Replace the inline sum in `UsageBy`'s query with `%s` fed by `tokenSumExpr`, keeping the argument order — the `fmt.Sprintf` becomes:

```go
	q := fmt.Sprintf(`
		SELECT %s AS k,
		       COUNT(*),
		       %s,
		       COALESCE(SUM(cost_usd), 0),
		       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1
		            THEN input_tokens + output_tokens + cache_create_5m_tokens
		                 + cache_create_1h_tokens + cache_read_tokens
		            ELSE 0 END), 0)
		FROM usage_events
		WHERE %s ts >= ? AND ts < ?
		GROUP BY k
		ORDER BY 3 DESC
		LIMIT ?`, col, tokenSumExpr, accountClause(account))
```

Do the same in `History` (its `%s` list grows by one) and in `LifetimeTotals`. Run `go test ./internal/store/...` after this refactor alone — it must still pass before anything new is added.

- [ ] **Step 4: Add the per-user queries**

Append to `internal/store/query.go`:

```go
// UserSummary is one OS login's spend across the whole hub.
//
// Scoped by os_user rather than by endpoint: the same person on two machines
// is one person, and that is the question /u/<login> answers.
type UserSummary struct {
	OSUser string `json:"os_user"`
	// Teams is a LIST because a login can work on machines allocated to
	// different teams. Collapsing it to one would attribute the rest of their
	// spend to a team that never received it.
	Teams    []string `json:"teams"`
	Turns    int64    `json:"turns"`
	Tokens   int64    `json:"tokens"`
	CostUSD  float64  `json:"cost_usd"`
	Projects int      `json:"projects"`
	Machines int      `json:"machines"`
}

// UserSummary totals one OS login over a period.
//
// An unknown login returns a zeroed summary and no error: "this person has no
// usage in this range" is an ordinary answer, and a 500 would be a lie about
// what went wrong.
func (s *Store) UserSummary(osUser string, start, end time.Time) (*UserSummary, error) {
	if osUser == "" {
		return nil, fmt.Errorf("os user is required")
	}
	out := &UserSummary{OSUser: osUser}

	q := fmt.Sprintf(`
		SELECT COUNT(*), COALESCE(%s, 0), COALESCE(SUM(cost_usd), 0),
		       COUNT(DISTINCT cwd), COUNT(DISTINCT endpoint_id)
		FROM usage_events
		WHERE os_user = ? AND ts >= ? AND ts < ?`, tokenSumExpr)
	if err := s.db.QueryRow(q, osUser, fmtTime(start), fmtTime(end)).
		Scan(&out.Turns, &out.Tokens, &out.CostUSD, &out.Projects, &out.Machines); err != nil {
		return nil, fmt.Errorf("user summary: %w", err)
	}

	rows, err := s.db.Query(`
		SELECT DISTINCT e.team
		FROM usage_events u
		JOIN endpoints e ON e.endpoint_id = u.endpoint_id
		WHERE u.os_user = ? AND u.ts >= ? AND u.ts < ? AND e.team <> ''
		ORDER BY e.team`, osUser, fmtTime(start), fmtTime(end))
	if err != nil {
		return nil, fmt.Errorf("user teams: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var team string
		if err := rows.Scan(&team); err != nil {
			return nil, err
		}
		out.Teams = append(out.Teams, team)
	}
	return out, rows.Err()
}

// UsageByUser aggregates one OS login's spend along a dimension.
//
// Spans every subscription on purpose: a person's own page is about them, not
// about which plan paid. Tokens and notional cost are additive, so this is a
// legitimate total -- unlike utilization, which is never summed.
func (s *Store) UsageByUser(osUser string, d Dimension, start, end time.Time, limit int) ([]Bucket, error) {
	if osUser == "" {
		return nil, fmt.Errorf("os user is required")
	}
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}

	q := fmt.Sprintf(`
		SELECT %s AS k, COUNT(*), %s, COALESCE(SUM(cost_usd), 0),
		       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), 0
		FROM usage_events
		WHERE os_user = ? AND ts >= ? AND ts < ?
		GROUP BY k ORDER BY 3 DESC LIMIT ?`, col, tokenSumExpr)

	rows, err := s.db.Query(q, osUser, fmtTime(start), fmtTime(end), limit)
	if err != nil {
		return nil, fmt.Errorf("usage by user %s: %w", d, err)
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./internal/store/... -v -run User`
Expected: PASS on all four tests.

- [ ] **Step 6: Run the whole suite and commit**

```bash
cd ~/projects/ccquota
go test ./... && gofmt -l internal/store && go vet ./...
git add internal/store/query.go internal/store/user_test.go
git commit -m "feat(store): per-login summary and breakdown for /u/<person>

The token expression is now one constant. Two totals on one page that
disagreed by a cache column would be worse than either."
```

---

### Task 6: hub routes — `/u/<login>` and badges

**Files:**
- Create: `internal/api/user.go`, `internal/api/badge.go`, `internal/api/badge_test.go`
- Modify: `internal/api/server.go`, `cmd/ccquota/hub.go`

**Interfaces:**
- Consumes: `badge.Data`/`Render`/`ToShields` (Task 1); `store.UserSummary`/`UsageByUser`/`ByTeam`/`UsageBy` (Tasks 3, 5); existing `writeJSON`, `httpError`, `viewerOnly`, `timeRange`.
- Produces: `Server.PublicBadges bool`; handlers `handleUserData`, `serveUserPage`, `handleUserBadge`, `handleTeamBadge`.

**Design note — this is the one place §11.5 bites.** A README image cannot send a viewer token, and GitHub's camo strips cookies. So a badge route that is useful in a README must be unauthenticated. §11.5 ("does the internal board need auth for *viewing*?") is unanswered, so this ships **fail-closed**: badge routes sit behind `viewerOnly` unless the operator passes `--public-badges`. Nothing becomes readable without a token by upgrading.

- [ ] **Step 1: Write the failing test**

Create `internal/api/badge_test.go`:

```go
package api

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func badgeServer(t *testing.T, public bool) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	id := model.Identity{AccountUUID: "acct-1", Email: "a@example.com", Hostname: "h1"}
	if err := st.UpsertAccount(id, "max", "tier"); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("ep-1", "ep-1", "h1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.TouchEndpoint("ep-1", id, "test", true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	c := 1.0
	if _, _, err := st.InsertEvents([]model.UsageEvent{{
		AccountUUID: "acct-1", EndpointID: "ep-1", MessageUUID: "m1",
		TS: time.Now().UTC().Add(-time.Hour), Model: "claude-opus-5",
		OutputTokens: 4242, CostUSD: &c, CWD: "/repo/a", OSUser: "alice",
	}}); err != nil {
		t.Fatal(err)
	}
	return &Server{Store: st, ViewerToken: "viewer-secret", PublicBadges: public}
}

func TestBadgeRoute_RendersSVG(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/badge/u/alice.svg", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "image/svg+xml") {
		t.Errorf("Content-Type = %q; a README will not render anything else", ct)
	}
	// camo caches; the badge must tolerate it explicitly rather than by default.
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "max-age=300") {
		t.Errorf("Cache-Control = %q, want public, max-age=300", cc)
	}
	body := rec.Body.String()
	if !strings.HasPrefix(body, "<svg") {
		t.Fatalf("body is not an SVG: %.40q", body)
	}
	// The badge must not carry the identifiers the public payload excludes.
	for _, forbidden := range []string{"/repo/a", "h1", "a@example.com", "acct-1"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("badge leaks %q", forbidden)
		}
	}
}

func TestBadgeRoute_UnknownHandleIs404WithAGenericBadge(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/badge/u/ghost.svg", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	// Never a zeroed badge: "0 tokens" reads as "this person did nothing",
	// which is a different and false claim from "no such person".
	if strings.Contains(rec.Body.String(), "0 tokens") {
		t.Error("unknown handle rendered a zeroed badge")
	}
	if !strings.HasPrefix(rec.Body.String(), "<svg") {
		t.Error("unknown handle did not render a generic SVG")
	}
}

// Fail closed. --public-badges is opt-in, so an operator who upgrades does not
// silently start serving per-person cost data to anyone who can reach the hub.
func TestBadgeRoute_RequiresViewerTokenUnlessPublic(t *testing.T) {
	s := badgeServer(t, false)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/badge/u/alice.svg", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 when --public-badges is off", rec.Code)
	}

	rec = httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/badge/u/alice.svg", nil)
	req.Header.Set("Authorization", "Bearer viewer-secret")
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d with a viewer token, want 200", rec.Code)
	}
}

func TestTeamBadgeRoute(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/badge/team/platform.svg", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "tokens") {
		t.Error("team badge carries no figure")
	}
}

func TestUserData_RequiresViewerToken(t *testing.T) {
	s := badgeServer(t, true) // public badges do NOT make the data route public
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/v1/user?user=alice", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401; /v1/user carries project paths", rec.Code)
	}
}

func TestUserData_ReturnsSummary(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/user?user=alice&since=30d", nil)
	req.Header.Set("Authorization", "Bearer viewer-secret")
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	for _, want := range []string{`"os_user":"alice"`, `"tokens":4242`, `"teams":["platform"]`} {
		if !strings.Contains(rec.Body.String(), want) {
			t.Errorf("response is missing %s\ngot: %s", want, rec.Body.String())
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./internal/api/ -run 'Badge|UserData'`
Expected: FAIL — `unknown field PublicBadges in struct literal`.

- [ ] **Step 3: Write the badge handlers**

Create `internal/api/badge.go`:

```go
package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/badge"
	"github.com/verkyyi/ccquota/internal/store"
)

// Badge routes exist so an internal repo README can carry a figure served by
// the company's own hub.
//
// That forces one property: a README image cannot send a viewer token, and
// GitHub's camo proxy strips cookies. So a badge that actually works in a
// README has to be readable without a credential. Whether an internal hub
// should expose ANY unauthenticated route is an open question, so this is
// opt-in (`ccquota hub --public-badges`) and off by default -- an operator who
// upgrades does not silently start publishing.
const badgeMaxAge = "public, max-age=300"

// badgeTheme reads the explicit ?theme=. There is deliberately no
// prefers-color-scheme fallback: inside an SVG loaded as an image it is
// inconsistently supported, and camo caches one copy for every reader.
func badgeTheme(r *http.Request) string {
	if r.URL.Query().Get("theme") == "light" {
		return "light"
	}
	return "dark"
}

// allTimeFloor is earlier than any Claude Code transcript can be.
//
// The per-user queries take a start bound, and "all time" still needs one. A
// zero time.Time formats as year 1 and SQLite compares it as a string, which
// works by accident; this is the same behaviour on purpose.
var allTimeFloor = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)

// badgePeriod reads ?period=. Anything unrecognised becomes all-time, which is
// the only window that cannot be mislabelled.
func badgePeriod(r *http.Request) (period string, start time.Time) {
	switch r.URL.Query().Get("period") {
	case "30d":
		return "30d", time.Now().UTC().AddDate(0, 0, -30)
	case "7d":
		return "7d", time.Now().UTC().AddDate(0, 0, -7)
	default:
		return "all", allTimeFloor
	}
}

// writeBadge emits an SVG or shields JSON, depending on the extension.
func writeBadge(w http.ResponseWriter, status int, d badge.Data, asJSON bool) {
	w.Header().Set("Cache-Control", badgeMaxAge)
	if asJSON {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(badge.ToShields(d))
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(badge.Render(d))
}

// notFoundBadge is what an unknown handle gets.
//
// Never a zeroed badge: "0 tokens" reads as "this person did nothing", which is
// a different claim -- and a false one -- from "there is no such person here".
func notFoundBadge(w http.ResponseWriter, theme string, asJSON bool) {
	d := badge.Data{Period: "unknown", Theme: theme}
	w.Header().Set("Cache-Control", badgeMaxAge)
	if asJSON {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(badge.Shields{
			SchemaVersion: 1, Label: "ccquota", Message: "no such handle", Color: "9c3050",
		})
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	w.WriteHeader(http.StatusNotFound)
	_, _ = w.Write(badge.Render(badge.Data{Period: d.Period, Theme: theme}))
}

// splitBadgePath turns "/badge/u/alice.svg" into ("alice", false).
func splitBadgePath(path, prefix string) (name string, asJSON bool, ok bool) {
	rest := strings.TrimPrefix(path, prefix)
	if rest == "" || rest == path || strings.Contains(rest, "/") {
		return "", false, false
	}
	switch {
	case strings.HasSuffix(rest, ".svg"):
		return strings.TrimSuffix(rest, ".svg"), false, true
	case strings.HasSuffix(rest, ".json"):
		return strings.TrimSuffix(rest, ".json"), true, true
	default:
		return "", false, false
	}
}

func (s *Server) handleUserBadge(w http.ResponseWriter, r *http.Request) {
	login, asJSON, ok := splitBadgePath(r.URL.Path, "/badge/u/")
	if !ok {
		http.NotFound(w, r)
		return
	}
	theme := badgeTheme(r)
	period, start := badgePeriod(r)

	sum, err := s.Store.UserSummary(login, start, time.Now().UTC())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if sum.Turns == 0 {
		notFoundBadge(w, theme, asJSON)
		return
	}
	writeBadge(w, http.StatusOK, badge.Data{
		Tokens: sum.Tokens, Turns: sum.Turns, Period: period, Theme: theme,
	}, asJSON)
}

func (s *Server) handleTeamBadge(w http.ResponseWriter, r *http.Request) {
	team, asJSON, ok := splitBadgePath(r.URL.Path, "/badge/team/")
	if !ok {
		http.NotFound(w, r)
		return
	}
	theme := badgeTheme(r)
	period, start := badgePeriod(r)

	buckets, err := s.Store.UsageBy(store.AllAccounts, store.ByTeam, start, time.Now().UTC(), 1000)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, b := range buckets {
		if b.Key == team {
			writeBadge(w, http.StatusOK, badge.Data{
				Tokens: b.Tokens, Turns: b.Events, Period: period, Theme: theme,
			}, asJSON)
			return
		}
	}
	notFoundBadge(w, theme, asJSON)
}
```

- [ ] **Step 4: Write the user page handler**

Create `internal/api/user.go`:

```go
package api

import (
	"net/http"
	"strings"

	"github.com/verkyyi/ccquota/internal/store"
)

// UserView is one person's page.
//
// INTERNAL ONLY. It carries project paths and machine names on purpose --
// inside a company, behind the viewer token, that is the whole value. It is
// also exactly why it must never be reachable with a badge-level credential:
// the public payload is a type defined from scratch, not this one redacted.
type UserView struct {
	*store.UserSummary
	TopProjects []store.Bucket `json:"top_projects"`
	// Named apart from the embedded UserSummary.Machines, which is a COUNT.
	// Two fields promoted to the same JSON key does not error -- the outer one
	// wins and the count silently disappears from the response.
	MachinesBreakdown []store.Bucket `json:"machines_breakdown"`
	Disclaimer        string         `json:"disclaimer"`
}

func (s *Server) handleUserData(w http.ResponseWriter, r *http.Request) {
	login := r.URL.Query().Get("user")
	if login == "" {
		httpError(w, http.StatusBadRequest, "a user is required: /v1/user?user=<os login>")
		return
	}
	start, end := timeRange(r.URL.Query().Get("since"), r.URL.Query().Get("until"))

	sum, err := s.Store.UserSummary(login, start, end)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	projects, err := s.Store.UsageByUser(login, store.ByProject, start, end, 12)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	machines, err := s.Store.UsageByUser(login, store.ByEndpoint, start, end, 20)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if projects == nil {
		projects = []store.Bucket{}
	}
	if machines == nil {
		machines = []store.Bucket{}
	}
	if sum.Teams == nil {
		sum.Teams = []string{}
	}
	writeJSON(w, http.StatusOK, UserView{
		UserSummary: sum, TopProjects: projects, MachinesBreakdown: machines,
		Disclaimer: shareDisclaimer,
	})
}

// serveUserPage serves /u/<login>. The page fetches its own data from
// /v1/user, so the login never has to be templated into HTML.
func (s *Server) serveUserPage(w http.ResponseWriter, r *http.Request) {
	if s.UI == nil {
		httpError(w, http.StatusNotFound, "this binary was built without the UI")
		return
	}
	if strings.TrimPrefix(r.URL.Path, "/u/") == "" {
		httpError(w, http.StatusNotFound, "no login in the path: /u/<os login>")
		return
	}
	f, err := s.UI.Open("user.html")
	if err != nil {
		httpError(w, http.StatusNotFound, "no user page in this build")
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	rs, ok := f.(interface {
		Read([]byte) (int, error)
		Seek(int64, int) (int64, error)
	})
	if !ok {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	http.ServeContent(w, r, "user.html", st.ModTime(), rs)
}
```

- [ ] **Step 5: Mount the routes**

In `internal/api/server.go`, add to the `Server` struct after `ViewerToken`:

```go
	// PublicBadges serves /badge/... without a viewer token, so an internal
	// README can actually render one (a README image sends no credential, and
	// camo strips cookies). Off by default: an operator who upgrades must not
	// silently start serving without auth.
	PublicBadges bool
```

In `Handler()`, before the final `mux.Handle("/", ...)`:

```go
	mux.Handle("/v1/user", s.viewerOnly(http.HandlerFunc(s.handleUserData)))
	mux.Handle("/u/", s.viewerOnly(http.HandlerFunc(s.serveUserPage)))

	// Badges are the one surface that may be unauthenticated, and only on
	// purpose. Everything else on this hub stays behind the viewer token.
	badges := http.NewServeMux()
	badges.HandleFunc("/badge/u/", s.handleUserBadge)
	badges.HandleFunc("/badge/team/", s.handleTeamBadge)
	if s.PublicBadges {
		mux.Handle("/badge/", badges)
	} else {
		mux.Handle("/badge/", s.viewerOnly(badges))
	}
```

- [ ] **Step 6: Add the hub flag**

In `cmd/ccquota/hub.go`, beside the other flags (after `noAuth`):

```go
	publicBadges := fs.Bool("public-badges", false,
		"serve /badge/... without a viewer token.\n"+
			"Needed for a README image, which sends no credential and is\n"+
			"proxied through a cache that strips cookies. Off by default")
```

and set it where the `api.Server` is constructed:

```go
		PublicBadges: *publicBadges,
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./internal/api/... -v -run 'Badge|UserData' && go build ./...`
Expected: PASS on all seven tests.

- [ ] **Step 8: Commit**

```bash
cd ~/projects/ccquota
go test ./... && gofmt -l internal/api cmd/ccquota && go vet ./...
git add internal/api/badge.go internal/api/user.go internal/api/badge_test.go internal/api/server.go cmd/ccquota/hub.go
git commit -m "feat(hub): /u/<login>, badge routes, and a fail-closed public switch

A README image sends no credential and camo strips cookies, so a badge
that works in a README must be unauthenticated. Whether an internal hub
should expose any such route is still open, so --public-badges is opt-in."
```

---

### Task 7: the dashboard — team card and per-person links

**Files:**
- Create: `web/dist/user.html`
- Modify: `web/dist/index.html`, `web/embed_test.go`

**Interfaces:**
- Consumes: `/v1/usage?by=team` (Task 3), `/v1/user?user=<login>` (Task 6).
- Produces: nothing Go-side.

- [ ] **Step 1: Write the failing test**

In `web/embed_test.go`, append:

```go
// The landing view groups by TEAM when teams are configured.
//
// This is not cosmetic. Read as a per-person performance ranking, an internal
// board makes people avoid the tool or pad their usage, and either destroys
// the cost data it exists to provide. Putting the team card first, and never
// numbering rows, is the design against that -- so it is asserted rather than
// left to the next person editing the file.
func TestDashboard_TeamCardLeadsAndNothingIsRanked(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "index.html")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)

	team := strings.Index(src, "teamCard(")
	user := strings.Index(src, "userCard(")
	if team < 0 {
		t.Fatal("the dashboard has no team card")
	}
	if user < 0 {
		t.Fatal("the dashboard has no user card")
	}
	if team > user {
		t.Error("the user card is rendered before the team card; the landing view is a per-person ranking")
	}
	for _, forbidden := range []string{"podium", "${i + 1}.", "${idx + 1}."} {
		if strings.Contains(src, forbidden) {
			t.Errorf("the dashboard renders a rank marker (%q)", forbidden)
		}
	}
}

func TestAssets_UserPageIsEmbedded(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "user.html")
	if err != nil {
		t.Fatalf("user.html unreadable: %v", err)
	}
	if len(b) < 1024 {
		t.Fatalf("user.html is %d bytes; that is a placeholder", len(b))
	}
	for _, want := range []string{"/v1/user", "os_user"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("user page is missing %q", want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/projects/ccquota && go test ./web/ -run 'TeamCard|UserPage'`
Expected: FAIL — `user.html unreadable`, `the dashboard has no team card`.

- [ ] **Step 3: Add the team card to the dashboard**

In `web/dist/index.html`, add `by=team` to the parallel fetch in the load function (around line 638), keeping the destructuring in the same order:

```js
    const [limits, endpoints, byEndpoint, byUser, byProject, bySession, history,
           byAccount, switches, endpointAccounts, byTeam] =
      await Promise.all([
        api(`/v1/limits?account=${a}`),
        api(`/v1/endpoints?account=${a}`),
        api(`/v1/usage?account=${a}&by=endpoint&since=${r}&limit=20`),
        api(`/v1/usage?account=${a}&by=user&since=${r}&limit=20`),
        api(`/v1/usage?account=${a}&by=project&since=${r}&limit=12`),
        api(`/v1/usage?account=${a}&by=session&since=${r}&limit=12`),
        api(`/v1/history?account=${a}&since=${r}&granularity=${gran}`),
        spanning() ? api(`/v1/usage?account=all&by=account&since=${r}&limit=20`) : null,
        api(`/v1/account-switches?limit=20`),
        api(`/v1/endpoint-accounts?limit=200`),
        api(`/v1/usage?account=${a}&by=team&since=${r}&limit=20`),
      ]);
    state.data = { limits, endpoints, byEndpoint, byUser, byProject, bySession, history,
                   byAccount, switches, endpointAccounts, byTeam };
```

Add the card function beside `userCard`:

```js
/* ----------------------------- who the spend is allocated to */

// The LANDING breakdown when teams are configured.
//
// Deliberately first, and deliberately unnumbered. Read as a per-person
// performance ranking an internal board fails by Goodhart -- people avoid the
// tool or pad their usage -- and either outcome destroys the cost data it
// exists to provide. Cost allocation is the question; who "won" is not.
function teamCard(byTeam) {
  const all = (byTeam && byTeam.buckets) || [];
  // Every endpoint unassigned means nobody has configured teams yet; a card
  // showing one "unassigned" row would be noise on every hub that never will.
  const configured = all.some((b) => b.key !== "");
  if (!configured) return null;

  const card = el("div", { class: "card" },
    el("h2", {}, "Where the spend is allocated"),
    el("p", { class: "hint" },
      `By team · ${state.range}. Teams are assigned on the hub ` +
      `(\`ccquota team --endpoint <id> --set <team>\`), never reported by a machine.`));

  if (state.tables) { card.appendChild(bucketTable(all, "Team")); return card; }

  card.appendChild(rankedBars(all.map((b, i) => ({
    key: b.label || b.key || "unassigned",
    value: b.tokens,
    right: `${fmtInt(b.tokens)} · ${fmtUSD(b.cost_usd)}`,
    color: seriesColor(i),
    tip: `<b>${escapeHTML(b.label || b.key || "unassigned")}</b><br>` +
         `${fmtFull(b.tokens)} tokens<br>${fmtFull(b.events)} turns · ${fmtUSD(b.cost_usd)} notional`,
  }))));
  return card;
}
```

In `render()`, put it at the head of the breakdowns — before `userCard`:

```js
  $("#main").replaceChildren(
    wallCard(d.limits),
    d.byAccount ? accountCard(d.byAccount) : null,
    el("div", { class: "grid2" }, endpointCard(d), historyCard(d.history)),
    teamCard(d.byTeam),
    userCard(d.byUser),
    projectCard(d.byProject, d.bySession),
    endpointRosterCard(d.endpoints),
    endpointAccountsCard(d.endpointAccounts),
    switchesCard(d.switches),
  );
```

In `userCard`, make each login link to its own page. Replace the `card.appendChild(el("h2"...))` header line's sibling hint with one that says so, and add after the bars:

```js
  card.appendChild(el("p", { class: "hint" },
    ...named.map((b) => el("a", {
      href: `/u/${encodeURIComponent(b.key)}`,
      style: "margin-right:.75rem",
    }, b.key))));
```

- [ ] **Step 4: Write the user page**

Create `web/dist/user.html`. Open `web/dist/share.html` and copy its `<style>` block verbatim into the placeholder marked below, so the two standalone pages stay visually identical — everything else is written here:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ccquota</title>
<!-- PASTE web/dist/share.html's <style>...</style> block here, unchanged. -->
<style>
  .badges { margin-top: 2rem; }
  .badges code { display: block; margin: .35rem 0; word-break: break-all; }
  .teams span { display: inline-block; margin-right: .5rem; }
</style>
</head>
<body>
<main id="app"><p class="hint">Loading…</p></main>
<script>
"use strict";

/* The login comes from the path, never templated into the HTML: the page is a
   static asset served to every user, and only its fetch is per-person. */
const LOGIN = decodeURIComponent(location.pathname.replace(/^\/u\//, "").replace(/\/$/, ""));
const RANGE = new URLSearchParams(location.search).get("since") || "30d";

async function api(path) {
  const res = await fetch(path, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

function el(tag, attrs, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v !== null && v !== undefined) n.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined) continue;
    n.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return n;
}

const fmtInt = (n) => new Intl.NumberFormat().format(n);
const fmtUSD = (n) => "$" + Number(n || 0).toFixed(2);

function stat(label, value) {
  return el("div", { class: "stat" }, el("div", { class: "k" }, label), el("div", { class: "v" }, value));
}

function list(title, hint, buckets, keyOf) {
  if (!buckets || !buckets.length) return null;
  return el("section", {},
    el("h2", {}, title),
    el("p", { class: "hint" }, hint),
    el("ul", {}, buckets.map((b) =>
      el("li", {}, `${keyOf(b)} — ${fmtInt(b.tokens)} tokens · ${fmtUSD(b.cost_usd)}`))));
}

function render(d) {
  const app = document.getElementById("app");

  if (!d.turns) {
    /* Never an empty board: "no rows" and "no usage" look identical and mean
       different things. Say which one this is. */
    app.replaceChildren(
      el("h1", {}, LOGIN),
      el("p", {}, `No usage recorded for this login in the last ${RANGE}.`),
      el("p", { class: "hint" },
        "That is not the same as spending nothing — an agent may never have " +
        "reported under this login. Check `ccquota team --list` for the endpoints on this hub."));
    return;
  }

  app.replaceChildren(
    el("h1", {}, d.os_user),
    d.teams && d.teams.length
      ? el("p", { class: "teams hint" }, "Team: ", d.teams.map((t) => el("span", {}, t)))
      : el("p", { class: "hint" }, "No team assigned."),

    el("div", { class: "stats" },
      stat("Tokens", fmtInt(d.tokens)),
      stat("Turns", fmtInt(d.turns)),
      stat("Notional cost", fmtUSD(d.cost_usd)),
      stat("Machines", fmtInt(d.machines)),
      stat("Projects", fmtInt(d.projects))),

    list("Projects", `Where the work happened · ${RANGE}.`, d.top_projects,
      (b) => b.key || "(no working directory)"),
    list("Machines", `Which endpoints this login ran on · ${RANGE}.`, d.machines_breakdown,
      (b) => b.label || b.key),

    el("section", { class: "badges" },
      el("h2", {}, "Badge"),
      el("p", { class: "hint" },
        "Serve these from this hub in an internal README. They need " +
        "`ccquota hub --public-badges`, because a README image sends no credential."),
      el("code", {}, `${location.origin}/badge/u/${encodeURIComponent(d.os_user)}.svg?theme=dark`),
      el("code", {}, `${location.origin}/badge/u/${encodeURIComponent(d.os_user)}.json?theme=dark`)),

    el("footer", {}, el("p", { class: "hint" }, d.disclaimer || "")));
}

(async () => {
  try {
    if (!LOGIN) throw new Error("no login in the path; open /u/<os login>");
    const d = await api(`/v1/user?user=${encodeURIComponent(LOGIN)}&since=${encodeURIComponent(RANGE)}`);
    render(d);
  } catch (err) {
    document.getElementById("app").replaceChildren(
      el("h1", {}, "Could not load this page"),
      el("p", {}, String(err.message)));
  }
})();
</script>
</body>
</html>
```

The page reads `d.machines_breakdown` and `d.machines` — the breakdown and the count. Task 6 defines both; they are separate JSON keys because a field promoted from the embedded `UserSummary` and an outer field with the same tag do not error, they silently drop one.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/projects/ccquota && go test ./web/ -v && go build ./...`
Expected: PASS on both new tests.

- [ ] **Step 6: Look at it**

```bash
cd ~/projects/ccquota && make build && ./bin/ccquota hub --addr 127.0.0.1:8788 --token dev-token
```

Open `http://127.0.0.1:8788/?token=dev-token`, confirm the team card is absent on a hub with no teams configured, assign one (`./bin/ccquota team --endpoint <id> --set platform`), reload, and confirm it appears above the login card. Then open `/u/<login>`.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/ccquota
git add web/
git commit -m "feat(ui): team card leads the breakdowns, and a page per login

Unnumbered on purpose. Read as a performance ranking an internal board
fails by Goodhart -- people avoid the tool or pad -- and either outcome
destroys the cost data it exists to provide."
```

---

### Task 8: documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the two commands to the README's command list**

Match the existing entries' style:

```
  ccquota badge  [flags]    Render this hub's totals as an SVG badge (local,
                            no network) or as shields.io endpoint JSON
  ccquota team   [flags]    Allocate an endpoint's spend to a team
```

- [ ] **Step 2: Add the Badges section**

Append this section to `README.md`, before any licence/footer section:

````markdown
## Badges

Render your totals locally. No server, no account, nothing submitted anywhere:

```bash
ccquota badge --out ccquota.svg --theme dark --period all
ccquota badge --json --out ccquota.json      # shields.io endpoint schema
```

**Publishing is up to you, and every route is serverless.** Measured, because
the content-type decides whether a URL can be an image at all:

| URL | Content-Type | Usable as a README image |
|---|---|---|
| `raw.githubusercontent.com/<you>/<you>/main/ccquota.svg` | `image/svg+xml` | yes |
| `gist.githubusercontent.com/.../raw` | `text/plain` | no — fine as shields *data*, not as the image |
| `img.shields.io/endpoint?url=<your json>` | `image/svg+xml` | yes, from a URL you supply |

So: commit the SVG to your profile repo and link it, or write the JSON to a
gist and point shields at it.

**Light and dark take two URLs**, not one adaptive badge. `prefers-color-scheme`
inside an SVG loaded as an image is inconsistently supported, and GitHub's camo
proxy caches one copy for every reader — so the theme is an explicit flag and
READMEs use the `<picture>` pattern:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".../ccquota-dark.svg">
  <img alt="ccquota" src=".../ccquota-light.svg">
</picture>
```

**A badge is not live.** camo caches it, so it carries a period label
(`all`, `30d`) and never a timestamp — a timestamp would sit on your profile
being wrong for a week.

### Serving badges from your own hub

`ccquota hub --public-badges` serves `/badge/u/<login>.svg` and
`/badge/team/<team>.svg` without a viewer token, which is what makes them
usable in an internal README — a README image sends no credential, and camo
strips cookies.

It is **off by default**, and it exposes the badge routes only. `/v1/user`,
the dashboard, the query API and MCP all stay behind the viewer token; per-person
cost data is not published by turning this on.

## Teams

Allocate a machine's spend to a team:

```bash
ccquota team --list
ccquota team --endpoint <endpoint-id> --set platform
ccquota team --endpoint <endpoint-id> --set ""     # un-assign
```

Teams are assigned **here, on the hub**, and never reported by an endpoint: a
machine that could name its own team could move its spend onto another team's
budget. Team is resolved when a query runs rather than stored on each turn, so
re-assigning a machine moves its **whole history**, not just what it does next.

The dashboard leads with the team breakdown once any team is configured, and it
is deliberately unnumbered. Read as a per-person performance ranking, an
internal usage board fails by Goodhart — people avoid the tool or pad their
usage — and either outcome destroys the cost data it exists to provide.
````

- [ ] **Step 3: Verify every documented command runs**

```bash
cd ~/projects/ccquota && make build
./bin/ccquota badge -h && ./bin/ccquota team -h && ./bin/ccquota hub -h | grep public-badges
```
Expected: each prints its usage; the grep finds the flag.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/ccquota
git add README.md
git commit -m "docs: badges, teams, and what --public-badges does not expose"
```

---

### Task 9: full verification

- [ ] **Step 1: The whole suite**

Run: `cd ~/projects/ccquota && go test ./...`
Expected: PASS, 14 packages (13 existing + `internal/badge`).

- [ ] **Step 2: Lint**

Run: `cd ~/projects/ccquota && make lint`
Expected: no output, exit 0.

- [ ] **Step 3: Cross-compile — the constraint that keeps "download one binary" true**

Run: `cd ~/projects/ccquota && make dist`
Expected: five binaries in `dist/`. `internal/badge` is stdlib-only so this cannot regress, but the check is cheap and a `go.mod` change would show up here.

- [ ] **Step 4: Confirm no new dependency**

Run: `cd ~/projects/ccquota && git diff --stat origin/main -- go.mod go.sum`
Expected: empty. A new dependency in a badge renderer means the renderer stopped being self-contained.

- [ ] **Step 5: Prove the local badge really touches no network**

```bash
cd ~/projects/ccquota && make build
./bin/ccquota badge --out /tmp/ccquota.svg --theme dark --period all
grep -c 'http' /tmp/ccquota.svg   # expected: 0
```

If a sandbox that can deny network is available, run the command under it; the expected result is an unchanged, successful render.
