package web

import (
	"fmt"
	"io/fs"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/model"
)

// The dashboard is embedded, so a missing web/dist is not a cosmetic problem:
// go:embed fails the BUILD. An unanchored `dist/` in .gitignore once kept the
// whole directory out of every commit, and a fresh clone could not compile.
//
// As of the Task 11 module-shell redesign, index.html is a thin shell (no
// inline <style>/<script>) that loads styles.css and the ES modules that hold
// the actual dashboard, so the placeholder-size and content-anchor checks
// this test used to make against index.html alone now apply to that whole
// module set instead.
func TestAssets_DashboardIsEmbedded(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no dashboard embedded: web/dist/index.html is missing from this checkout")
	}
	b, err := fs.ReadFile(assets, "index.html")
	if err != nil {
		t.Fatalf("index.html unreadable: %v", err)
	}
	// A couple of anchors, so an empty or truncated shell cannot pass.
	//
	// The title anchor is deliberately NOT the product name. It was
	// "<title>ccquota</title>", and renaming the product to TokenLedger broke
	// this test — an anchor whose job is "the shell is not truncated" should not
	// also be an assertion about branding, or every rename is a red build.
	// `<title>` alone still proves the head survived.
	//
	// The section ids are anchored for the same reason and with the same
	// constraint: they are STRUCTURAL, not headings. `id="consumption"` is
	// where the page mounts that section, and rewording its <h2> must not turn
	// this test red -- which is exactly what anchoring on "Consumption" would
	// do. Together they prove the single-surface shell survived: one <main>
	// with the sections every renderer mounts into.
	for _, want := range []string{
		"<title>", `href="styles.css"`, `src="app.js"`,
		`id="page"`, `id="spend"`, `id="status"`, `id="consumption"`, `id="analysis"`,
		// The three-tier shell: alerts above the tiers, operations folded.
		`id="alerts"`, `id="ops"`, `id="ops-analysis"`,
		// The progress band and its section. The band starts hidden and app.js
		// unhides it only where a shipper has pushed repo facts, so the mount
		// point has to exist in the shell whether or not this hub uses it.
		`id="repo-band"`, `id="repo"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html shell is missing %q", want)
		}
	}
	// The shell's own strings (the band labels, the operations summary, the two
	// toolbar buttons) live in this file, so they cannot be translated at render
	// time like a card's can -- lib/dom.js's localizeShell rewrites them at boot
	// from these attributes. Drop the attribute and that string stays English
	// forever, in the middle of a page that translated around it.
	for _, want := range []string{
		`id="lang"`, `data-i18n="band.ledger"`, `data-i18n="band.usage"`, `data-i18n="band.progress"`, `data-i18n="ops.title"`, `data-i18n-title="app.theme"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html is missing the i18n hook %q", want)
		}
	}
	// The retired view tabs must not come back by accident. This assertion is
	// UNCHANGED by #54, and that is the point worth recording here.
	//
	// #54 gave this page a top nav, which reads like the thing this check was
	// written to prevent and is not. What the tabs did was split the page into
	// regions that fetched and refreshed on their own rhythms, and the reason
	// they were retired stands: "what is burning right now" and "what did this
	// period cost" are one question at two time scales, so a reader who picked
	// one was told to choose between halves of an answer. #54 adds anchors over
	// the bands this one surface already has. It moves the viewport; it issues
	// no request and mounts nothing. One <main>, one load(), four bands.
	//
	// So the guard stays, and it is now load-bearing in a way it was not
	// before: with a nav bar in the header, a `<button id="tab-now">` is one
	// plausible edit away, and it would silently restore the split behind
	// navigation that looks identical to the anchors beside it.
	for _, gone := range []string{`id="tab-now"`, `id="tab-review"`} {
		if strings.Contains(string(b), gone) {
			t.Errorf("index.html still has %q -- the Now/Review split is retired; #54's nav scrolls, it does not switch views", gone)
		}
	}
	// The nav itself, and the four bands it targets (web/dist/lib/nav.js's
	// SECTIONS). #54's own requirement was that the nav's segments match the
	// page's visible groups, so the first tier grew the band label it never
	// had: a nav offering four destinations over three labels disagrees with
	// the page under it. These ids are the anchor targets, which makes them
	// structural in exactly the sense the note above describes.
	for _, want := range []string{
		`id="secnav"`, `id="ledger-band"`, `id="usage-band"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html shell is missing %q -- the section nav has nothing to anchor to", want)
		}
	}
	// The dead `<footer id="footer">` #54 removed. No module ever wrote it, so
	// it rendered as nothing on every page view; re-adding an empty one is
	// re-adding a placeholder that outlives whoever remembers why.
	if strings.Contains(string(b), `id="footer"`) {
		t.Error(`index.html has id="footer" again -- it was dead markup no module wrote; the sticky bar is the "back to top"`)
	}
	// The operations tier is a <details>, and the money is NOT inside it.
	//
	// Both halves matter. A fold built from a hidden div plus a button would
	// lose the keyboard and find-in-page behaviour <details> gives free; and
	// the whole point of the tier is that the ledger opens unfolded, so a
	// future edit that moves #spend or #consumption inside the fold has undone
	// the thing this structure exists for.
	shell := string(b)
	opsAt := strings.Index(shell, `<details id="ops"`)
	if opsAt < 0 {
		t.Error("the operations tier is not a <details> -- a div+button fold loses keyboard and find-in-page for free behaviour")
	} else {
		for _, ledger := range []string{`id="spend"`, `id="consumption"`, `id="alerts"`} {
			if at := strings.Index(shell, ledger); at > opsAt {
				t.Errorf("%s is inside the folded operations tier; the ledger must open unfolded", ledger)
			}
		}
	}
	// Every module the shell depends on must actually be embedded, and none
	// of them may be a truncated placeholder.
	minBytes := map[string]int64{
		"styles.css": 4096, "app.js": 1024, "scope.js": 1024,
		"charts.js": 4096, "now.js": 4096,
		"lib/dom.js": 512, "lib/state.js": 512,
		// scope.js imports this one, so a miss here is not a degraded nav —
		// it is a module-resolution error that stops the whole page booting.
		"lib/nav.js": 512,
		// A dictionary that fails to embed does not fail loudly: lib/i18n.js's
		// t() falls back to the key, so the page renders `spend.title` where a
		// card heading belongs. Embedding is the only place that can catch it.
		"lib/i18n.js": 1024, "lib/i18n/en.js": 8192, "lib/i18n/zh-CN.js": 8192,
	}
	for name, min := range minBytes {
		st, err := fs.Stat(assets, name)
		if err != nil {
			t.Errorf("%s is not embedded: %v", name, err)
			continue
		}
		if st.Size() < min {
			t.Errorf("%s is %d bytes; that is a placeholder, not the real module", name, st.Size())
		}
	}
	// The "am I about to hit the wall" gauge and its account-spanning shape
	// used to be right there in index.html; both now live in now.js's
	// wallCard.
	nowJS, err := fs.ReadFile(assets, "now.js")
	if err != nil {
		t.Fatalf("now.js unreadable: %v", err)
	}
	for _, want := range []string{"/v1/limits", "per_account"} {
		if !strings.Contains(string(nowJS), want) {
			t.Errorf("now.js is missing %q", want)
		}
	}
}

// Nothing in the dashboard numbers a row (no "1.", no podium).
//
// This is not cosmetic. Read as a per-person performance ranking, an internal
// board makes people avoid the tool or pad their usage, and either destroys
// the cost data it exists to provide.
//
// Before Task 11, this test also asserted markup order: the one index.html
// that rendered both a team and a user breakdown card, unconditionally, had
// to put teamCard(d.byTeam) before userCard(d.byUser). The module-shell
// redesign moved that breakdown into the Review view (lib/state.js's GROUPS
// — the dimensions a "breakdown" card can show, team among them), where g1/g2
// pick which dimension each of the two breakdown cards shows via a segmented
// control the viewer operates: there is no longer a fixed "teamCard" /
// "userCard" pair in a hardcoded order for a byte offset to compare, so that
// half of the check was retired (task-11-report.md has the detail; an
// equivalent for Review's breakdown cards, if wanted, is a new test keyed to
// lib/state.js's DEFAULTS, not to source order in one file). What remains —
// and is a strictly wider net than the single file the original check swept
// — is this: no rank marker in any embedded module.
func TestDashboard_NothingIsRanked(t *testing.T) {
	assets := Assets()
	forbidden := []string{"podium", "${i + 1}.", "${idx + 1}."}
	err := fs.WalkDir(assets, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".js") {
			return err
		}
		b, err := fs.ReadFile(assets, path)
		if err != nil {
			return err
		}
		src := string(b)
		for _, f := range forbidden {
			if strings.Contains(src, f) {
				t.Errorf("%s renders a rank marker (%q)", path, f)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
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

// The door map's page (#61) is embedded, and it gets its facts from the hub
// rather than from its own markup.
//
// The second half is the assertion worth having. The whole reason /access
// exists is that the repository had no single true statement about its
// entrances -- the README described some doors, index.html's `<details
// id="ops">` fold looked like one and is not, and nothing listed the CLI at
// all. A page that hard-codes the table re-creates exactly that: markup that
// was true on the day it was written and drifts from internal/api/server.go's
// router the first time someone mounts a route. So the page is asserted to
// FETCH, and the door names are asserted to be absent from it -- they live in
// access.go's doors(), beside Handler(), or they live nowhere.
func TestAssets_AccessPageIsEmbeddedAndFetchesItsFacts(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "access.html")
	if err != nil {
		t.Fatalf("access.html unreadable: %v", err)
	}
	src := string(b)
	if len(b) < 1024 {
		t.Fatalf("access.html is %d bytes; that is a placeholder", len(b))
	}
	if !strings.Contains(src, `fetch("/v1/access"`) {
		t.Error("the access page does not fetch /v1/access; its facts would be frozen markup")
	}
	// Route strings the page must NOT carry. Each is a door whose description
	// belongs to the router: find one here and the table has started drifting.
	for _, leaked := range []string{"/v1/ingest", "ccquota enroll", "/badge/u/", "POST /mcp"} {
		if strings.Contains(src, leaked) {
			t.Errorf("access.html hard-codes %q -- door descriptions come from /v1/access, not from the page", leaked)
		}
	}
}

// A source this build knows must be nameable by the page that offers it, and a
// billed one must be a named term of real spend.
//
// Both failures are silent, which is why they get a test rather than a review
// habit. lib/providers.js's SOURCE_LABEL falls through to the bare identifier,
// so an unlabelled source just reads "voice" in the picker beside "Claude
// Code"; lib/spend.js names the terms of the headline figure from its own
// list, so a source missing from it is money absent from the breakdown under a
// total that still includes it. That is how `voice` — added to model.Sources
// while this page was being rebuilt — would have shipped.
//
// The Go side is the anchor on purpose: model.Sources is where a source is
// born, and the point is that adding one there turns THIS red. No label text
// is asserted; that is the page's business.
func TestDashboard_EverySourceIsNamedAndEveryChargeIsATerm(t *testing.T) {
	assets := Assets()
	read := func(name string) string {
		b, err := fs.ReadFile(assets, name)
		if err != nil {
			t.Fatalf("%s unreadable: %v", name, err)
		}
		return string(b)
	}
	providers, spend := read("lib/providers.js"), read("lib/spend.js")
	for _, src := range model.Sources {
		if !strings.Contains(providers, src+": '") {
			t.Errorf("lib/providers.js SOURCE_LABEL has no entry for %q; the source picker would show the bare identifier", src)
		}
		if model.CostKind(src) != model.CostBilled {
			continue
		}
		// api.RealSpend carries one field per billed source, so spendTerms must
		// name each of them or the terms it prints do not add up to the total
		// printed above them.
		if !strings.Contains(spend, "'"+src+"'") {
			t.Errorf("lib/spend.js does not name %q, a billed source; its money would vanish from the breakdown", src)
		}
	}
}

// The page reports money that was actually charged, and nothing else.
//
// The API-equivalent figure ("notional") still exists in the API and still
// prices subscription work for plan --spend's value-for-money ratio. It is kept
// off this page on purpose, and that decision needs a guard rather than a
// comment: it was already made once and undone by accretion, because every
// individual re-addition looks harmless. Measured on this deployment when it was
// removed: 30 days of real spend was $39.56 against $73,270 of API-equivalent
// cost for the same window — 1,852x larger. Whatever label sits next to a figure
// that size, it is the number a reader carries away.
//
// So: no page module may fold a notional total, and none may print the word as a
// figure's unit. A module that needs the KIND of a source still asks kindOf —
// this checks the FOLD, which only exists to produce a notional amount.
func TestDashboard_ThePageReportsOnlyRealMoney(t *testing.T) {
	assets := Assets()
	// lib/cost.js DEFINES the fold (and its own tests guard the never-blend-kinds
	// discipline), so it is the one file allowed to name it.
	const definition = "lib/cost.js"
	err := fs.WalkDir(assets, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".js") || path == definition {
			return err
		}
		b, err := fs.ReadFile(assets, path)
		if err != nil {
			return err
		}
		if strings.Contains(string(b), "notionalCost") {
			t.Errorf("%s folds a notional total; this page reports only money that was charged "+
				"(the figure is still in the API as cost_notional)", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// The live tiles described subscription work, so a per-hour DOLLAR rate there
	// was an estimate of money nobody is billed. Tokens per minute answers the
	// same question in the unit actually being consumed.
	nowJS, err := fs.ReadFile(assets, "now.js")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(nowJS), "lv-uph") {
		t.Error("now.js still renders the $/hour tile — that rate was notional")
	}
}

// The boot fetches must not be serialised behind one another.
//
// app.js needs two things before the first render: the account list (route()
// resolves the subscription against it) and the display FX rate (a card drawn at
// no rate beside one drawn at a rate shows the same money two ways). Neither
// depends on the other, so both go out at once.
//
// They were sequential once, and the cost was invisible in every local test:
// the hop is ~4ms against a hub on loopback and ~600ms against the deployed one,
// so a viewer whose locale needs a rate waited most of a second on a blank page
// while the account fetch had not even started. A latency regression that only
// appears over a real network is exactly the kind that ships, which is why this
// is a guard rather than a comment.
func TestDashboard_BootFetchesAreConcurrent(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "app.js")
	if err != nil {
		t.Fatalf("app.js unreadable: %v", err)
	}
	src := string(b)
	// Awaiting the rate before the account request is ISSUED is the regression:
	// it puts a whole round trip in front of everything the page draws.
	if strings.Contains(src, "await app.api(`/v1/fx") || strings.Contains(src, "await app.api('/v1/fx") {
		t.Error("app.js awaits the FX rate inline; issue it alongside /v1/accounts and await both after, " +
			"or every viewer needing a rate pays an extra round trip before the page starts loading")
	}
	// Both requests must be in flight before either is awaited.
	fxAt := strings.Index(src, "/v1/fx")
	accAt := strings.Index(src, "app.api('/v1/accounts')")
	if fxAt < 0 || accAt < 0 {
		t.Fatal("app.js no longer issues both boot fetches; this guard needs updating with them")
	}
	firstAwait := strings.Index(src[min(fxAt, accAt):], "await ")
	if firstAwait < 0 {
		return
	}
	if between := src[min(fxAt, accAt) : min(fxAt, accAt)+firstAwait]; !strings.Contains(between, "/v1/accounts") || !strings.Contains(between, "/v1/fx") {
		t.Error("one boot fetch is awaited before the other is issued; they must both be in flight first")
	}
}

// A card's own title must outrank the headings inside it.
//
// `.card > h2` styles only the direct child, so an h2 one level deeper falls
// through to the browser default — 1.5em bold — and renders LARGER than the
// card title above it. That inversion shipped: the Efficiency card's "Effort",
// "Entrypoint" and "Turns: main vs. subagent" were the biggest text in a card
// whose own title was 13px. A descendant rule has to exist for the nested case.
func TestDashboard_NestedCardHeadingsAreStyled(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "styles.css")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), ".card * h2") {
		t.Error("styles.css has no rule for headings nested inside a card; " +
			"they will fall back to the browser default and outrank the card's own title")
	}
}

// The dashboard and the alert rules must mean the same thing by "stale
// endpoint".
//
// They did not: now.js dimmed a roster row after 600s while findings.StaleAfter
// waited an hour, so one machine could be greyed out in the Fleet table and
// entirely unremarkable in the Alerts card a few hundred pixels above it. #59
// aligned them on the Go constant. web/dist has no build step — it is
// hand-written ES modules embedded as they are — so the page cannot import the
// constant and carries the literal instead. This is the thing that keeps the
// literal honest: change StaleAfter and this test names the line to change.
func TestDashboard_StaleEndpointThresholdMatchesFindings(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "now.js")
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("const STALE_ENDPOINT_SEC = %d;", int(findings.StaleAfter/time.Second))
	if !strings.Contains(string(b), want) {
		t.Errorf("now.js does not declare %q -- the roster's idea of a stale endpoint has drifted "+
			"from findings.StaleAfter (%s), which is what raises the stale_agent alert on the same page",
			want, findings.StaleAfter)
	}
	// The old threshold, by value, in the roster's own comparison. Left as a
	// separate check so a re-introduced 600 is reported as the specific
	// regression it is rather than as a missing constant.
	if strings.Contains(string(b), "secs > 600") {
		t.Error("now.js compares an endpoint's last-seen against a bare 600 again -- " +
			"that is the second definition of 'stale' #59 removed")
	}
}

// The live card has to state the window behind the word "active".
//
// The count comes from the server with the threshold that produced it
// (Snapshot.ActiveWindowSec), and the card renders that number rather than a
// copy of it. A card that asserts "3 active sessions" over an unstated rule is
// asking to be believed without saying what was measured; #59's whole point is
// that the page says which three minutes it means.
func TestDashboard_LiveCardStatesItsWindow(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "now.js")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"active_window_sec", "live.window", "ever_reported"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("now.js no longer reads %q -- the live card is back to asserting "+
				"'active' without stating the window, or a cold hub without saying so", want)
		}
	}
}

// The live strip's window sentence needs a style rule of its own.
//
// `.live` is not a `.card`, so neither `.card > .hint` nor the nested
// `.card * .hint` rule from issue #51 reaches a `.hint` inside it: the sentence
// would render at body size with a default paragraph margin, larger than the
// 13px card title above it. Same inversion #51 fixed one container over.
func TestDashboard_LiveStripHintIsStyled(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "styles.css")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), ".live > .hint") {
		t.Error("styles.css has no rule for a .hint inside the live strip; the sentence " +
			"stating the active window will outrank the card's own title")
	}
}
