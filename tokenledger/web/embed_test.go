package web

import (
	"fmt"
	"io/fs"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
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
		`id="page"`, `id="spend"`, `id="ledgerchip"`, `id="status"`, `id="consumption"`, `id="analysis"`,
		// The quota band's mount point, and the page's scope strip (#95). The
		// strip is the reason the first is possible: that card used to HOST the
		// only scope controls the operations view had, so it could not be moved
		// anywhere until they had a home of their own.
		`id="quota"`, `id="scopebar"`,
		// The three-tier shell: alerts above the tiers, operations folded.
		// #alerts survived #123, which moved the alerts themselves into the bar
		// (#alertbell, checked with #pulse below): it is where a /v1/findings
		// query that FAILED is reported, because a bell's summary is a count and
		// there is no honest count for "nothing is known".
		// #spend survived #128 on exactly that argument, one band down: the
		// figure is #ledgerchip in the bar now, and this slot is where a
		// /v1/summary that failed is reported, because an absent chip would
		// report a deployment that spent nothing.
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
		`id="lang"`, `data-i18n="band.quota"`, `data-i18n="band.ledger"`, `data-i18n="band.usage"`, `data-i18n="band.progress"`, `data-i18n="ops.title"`, `data-i18n-title="app.theme"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html is missing the i18n hook %q", want)
		}
	}
	// The retired view tabs must not come back by accident. The assertion is
	// unchanged; what it MEANS has been rewritten twice, and #98 is the second
	// time, so the reasoning is worth keeping current rather than letting the
	// check outlive its explanation.
	//
	// #54 gave this page a top nav and said of it: this is not the tabs, it
	// only moves the viewport, it issues no request and mounts nothing.
	// #98 makes the nav mount one band and unmount the others, and gates the
	// page's loaders on what is mounted -- so "it mounts nothing" is now false,
	// and a reader could reasonably ask what is left of the distinction.
	//
	// This: what the Now/Review tabs did was split the page into regions that
	// FETCHED AND REFRESHED ON THEIR OWN RHYTHMS. "What is burning right now"
	// and "what did this period cost" are one question at two time scales, and
	// a reader who picked one was told to choose between halves of an answer.
	// A view is one hash, one scope, one load(), one 60-second refresh: `view`
	// is in lib/state.js's PRESENTATION_KEYS, so switching costs no request and
	// redraws from rows already in hand, and every band that IS mounted answers
	// as of the same moment. Fewer questions asked, never two answers that
	// disagree.
	//
	// So the guard stays, and it is more load-bearing than ever: with a nav bar
	// in the header that now genuinely swaps content, a `<button id="tab-now">`
	// is one plausible edit away, and it would restore the split behind
	// navigation that looks identical to the view entries beside it.
	for _, gone := range []string{`id="tab-now"`, `id="tab-review"`} {
		if strings.Contains(string(b), gone) {
			t.Errorf("index.html still has %q -- the Now/Review split is retired; a view shares one hash, one load and one refresh, which is what the tabs did not", gone)
		}
	}
	// The nav, and the band labels. #54's requirement was that the nav's
	// segments match the page's visible groups, so the first tier grew the band
	// label it never had: a nav offering four destinations over three labels
	// disagrees with the page under it. That requirement survives #98 with the
	// terms swapped -- the entries no longer point AT these labels, they decide
	// whether the labels are on the page at all -- and the ids stay structural
	// in exactly the sense the note above describes.
	for _, want := range []string{
		`id="secnav"`, `id="quota-band"`, `id="ledger-band"`, `id="usage-band"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html shell is missing %q -- the view nav has no band to mount", want)
		}
	}
	// Every band node says which view mounts it, and #pulse / #alerts say
	// nothing, which is what puts them on every view.
	//
	// This is the mapping app.js's mountView reads, and it is the whole of it:
	// a section that loses its `data-band` silently becomes a section that
	// never unmounts, which is #98 undone for that one card with no other
	// symptom. The four names are lib/nav.js's SECTIONS `view` column -- one
	// word shared by the URL, this markup and review.js's fetch plan -- so a
	// typo here is a band that no view can ever show.
	for _, want := range []string{
		`id="quota-band" data-band="quota"`,
		`id="quota" data-band="quota"`,
		`id="ledger-band" data-band="ledger"`,
		`id="spend" data-band="ledger"`,
		`id="consumption" data-band="ledger"`,
		`id="usage-band" data-band="usage"`,
		`id="analysis" data-band="usage"`,
		`id="repo-band" data-band="progress"`,
		`id="repo" data-band="progress"`,
		`id="ops" class="ops" data-band="ops"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html is missing %q -- app.js mounts bands by data-band, so an untagged node is on every view", want)
		}
	}
	// ...and the two that must NOT carry one. An alert nobody can reach is an
	// alert nobody sees: a reader on the usage view is no less entitled to be
	// told the collector died, and the token badge is the page's one ambient
	// "is the fleet still moving" signal. Both were deliberately kept outside
	// the operations fold for that reason; putting them in a band would fold
	// them away again under another name.
	// #scopebar joins them as of #95, and it is the one that had to be ARGUED
	// into the list rather than inheriting a rule. Subscription, source, span and
	// chips scope every band, so the widget cannot belong to one -- and before
	// this it belonged to the quota card inside the operations fold, which meant
	// `view=ledger` and `view=progress` rendered no scope control at all: a page
	// of money for a subscription the reader could not change, narrowed by chips
	// they could neither see nor remove. Give this node a data-band and that
	// comes straight back for whichever views it is not tagged with.
	// #alertbell joins them at #123, and for it the rule is inherited twice
	// over: it is the alerts, which the entry above already argues belong on
	// every view, AND it is in the bar, which mountView never walks. The
	// attribute check is still worth making -- a data-band here would be
	// silently inert today and quietly correct-looking to whoever later moved
	// the bell back into <main>.
	for _, floater := range []string{`id="pulse"`, `id="alerts"`, `id="alertbell"`, `id="ledgerchip"`, `id="scopebar"`} {
		at := strings.Index(string(b), floater)
		if at < 0 {
			continue // the id check above already reported it
		}
		if end := strings.IndexByte(string(b)[at:], '>'); end > 0 &&
			strings.Contains(string(b)[at:at+end], "data-band") {
			t.Errorf("%s carries a data-band -- it floats above the tiers and belongs on every view", floater)
		}
	}
	// The token badge's mount point is in the BAR, not in <main> (#96).
	//
	// It is the strongest form of the floater rule just above. #alerts earns
	// "on every view" by carrying no data-band, which works but depends on an
	// attribute staying absent; #pulse earns it structurally -- a node mountView
	// never walks cannot be unmounted by a view at all.
	//
	// The other half is not a styling preference either. --navh is the sticky
	// bar measured (scope.js's navHeight), the offset everything the page
	// scrolls to lands against, and the badge's first frame arrives about one
	// round trip after the page does (now.js's startLive). In the bar it is
	// sized to fit inside the row's existing height so a late arrival cannot
	// move that number; back in <main> that sizing, and the reasoning around it,
	// becomes dead weight -- and the two-line move that put it there would read
	// like the revert of a cosmetic change.
	//
	// #123 put the ALERT BELL in the bar on the same argument, and for it the
	// second half is the load-bearing one. The count has to be on screen when
	// the reader needs it, and the card it replaces stopped being on screen the
	// moment anyone scrolled past it; --navh then says the bell must not change
	// the bar's height, which is why styles.css sizes the closed pill to fit and
	// takes the open panel out of flow. Back in <main> none of that is true and
	// none of it is needed -- so a move back is a real change, and this is where
	// it has to be argued rather than committed as a tidy-up.
	src := string(b)
	headEnd := strings.Index(src, `</header>`)
	if headEnd < 0 {
		t.Error(`index.html has no </header> -- the sticky bar is the shell's one static element`)
	}
	for _, inBar := range []struct{ id, why string }{
		{`id="pulse"`, `#96 put the token badge in the sticky bar, where no view can unmount it and its late first frame cannot move --navh`},
		{`id="alertbell"`, `#123 put the alert count in the sticky bar, where it stays on screen however far the reader has scrolled -- a card above the tiers did not`},
		{`id="ledgerchip"`, `#128 put the ledger's figure in the sticky bar, where it stays on screen however far the reader has scrolled -- the 206px card it replaces did not`},
	} {
		at := strings.Index(src, inBar.id)
		switch {
		case at < 0:
			t.Errorf(`index.html has no %s -- now.js has nowhere to mount it`, inBar.id)
		case headEnd >= 0 && at > headEnd:
			t.Errorf(`%s is outside <header id="scope"> -- %s`, inBar.id, inBar.why)
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
	//
	// #95 put two more nodes under the same rule, and for them it is not a
	// regression guard but the change itself:
	//
	//   #quota     was the FIRST CHILD of this fold, and the fold is shut by
	//              default. "How much runway is left before work stops" is the
	//              only question on this page with a deadline, and it was the
	//              one question a reader had to go looking for -- measured, the
	//              default view was 6,998px that did not contain it.
	//   #scopebar  is the page's subscription / source / span / chips. Folded
	//              away it takes the only control over what every other band is
	//              showing with it, which is how it ended up here: it was
	//              mounted ON the quota card, so neither could move alone.
	shell := string(b)
	opsAt := strings.Index(shell, `<details id="ops"`)
	if opsAt < 0 {
		t.Error("the operations tier is not a <details> -- a div+button fold loses keyboard and find-in-page for free behaviour")
	} else {
		for _, ledger := range []string{`id="spend"`, `id="consumption"`, `id="alerts"`, `id="quota"`, `id="scopebar"`} {
			if at := strings.Index(shell, ledger); at > opsAt {
				t.Errorf("%s is inside the folded operations tier; it must be on the page the reader opens", ledger)
			}
		}
	}
	// The quota band opens the page: it comes before the ledger band, which is
	// what "bring quota usage to the front" (#95) actually asks for. Checked by
	// POSITION rather than by the label, because the label is translated and the
	// ordering is the claim.
	if q, l := strings.Index(shell, `id="quota-band"`), strings.Index(shell, `id="ledger-band"`); q < 0 || l < 0 || q > l {
		t.Error(`the quota band must come before the ledger band -- every other band on this page answers in the past tense, and this one is the only question with a deadline`)
	}
	// Every module the shell depends on must actually be embedded, and none
	// of them may be a truncated placeholder.
	minBytes := map[string]int64{
		"styles.css": 4096, "app.js": 1024, "scope.js": 1024,
		"charts.js": 4096, "now.js": 4096, "quota.js": 2048,
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
	// The "am I about to hit the wall" gauge and its account-spanning shape used
	// to be right there in index.html, then in now.js's wallCard, and since #95
	// they are quota.js's -- its own band, out of the operations fold.
	//
	// The two halves are checked in the two files they actually live in, because
	// #95 SPLIT them: now.js still sends the request, since the same response
	// feeds the limits banners it draws and those are in no band, while quota.js
	// reads per_account and groups it. Asserting both against one file would have
	// gone green on a build where the card renders from a second, duplicate fetch.
	nowJS, err := fs.ReadFile(assets, "now.js")
	if err != nil {
		t.Fatalf("now.js unreadable: %v", err)
	}
	if !strings.Contains(string(nowJS), "/v1/limits") {
		t.Error("now.js no longer requests /v1/limits -- the limits banners have no other source")
	}
	quotaJS, err := fs.ReadFile(assets, "quota.js")
	if err != nil {
		t.Fatalf("quota.js unreadable: %v", err)
	}
	for _, want := range []string{"per_account", "quotaGroups"} {
		if !strings.Contains(string(quotaJS), want) {
			t.Errorf("quota.js is missing %q -- the card answers across subscriptions, grouped by provider", want)
		}
	}
	// ...and the card must not have quietly kept a fetch of its own. One response
	// feeds the card AND the banners; two would be one request spent to buy a
	// second chance at disagreeing with the first.
	if strings.Contains(string(quotaJS), "app.api(") {
		t.Error("quota.js fetches for itself -- it must read now.js's LIMITS_INDEX slot, which the banners already read")
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

// The per-person page is REACHED from the dashboard, not only routed by it.
//
// Issue #99: /u/<login> was routed in internal/api/server.go, served by
// internal/api/user.go, and listed by /access as a door — and searching all of
// web/ for "/u/" turned up nothing but user.html's own badge URL. Every part
// of the door existed except the way to it, and nothing failed, because
// "nobody links here" is not a thing a router or a handler can notice.
//
// So the Go side holds it: the route is declared here beside the assertion
// that some embedded script builds it. Delete the link from review.js and this
// fails, which is the only version of this fix that survives the next
// refactor of the breakdown card.
func TestAssets_DashboardLinksToTheUserPage(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "review.js")
	if err != nil {
		t.Fatalf("review.js unreadable: %v", err)
	}
	src := string(b)
	// The path this build actually routes (server.go: "/u/"). Built from the
	// login, which is why it is a template rather than a literal.
	if !strings.Contains(src, "`/u/${encodeURIComponent(login)}`") {
		t.Error("review.js no longer builds a /u/<login> link: the by-user breakdown row is a dead end again, " +
			"and /access still tells readers the dashboard leads there")
	}
	// Encoded, not interpolated raw. serveUserPage takes the login straight off
	// the path, so a login containing a slash or a '#' would silently become a
	// different route -- or no route.
	if strings.Contains(src, "`/u/${login}`") {
		t.Error("review.js interpolates a raw login into the path; a login with a '/' or '#' becomes another route")
	}
}

// The "when do we work" card draws the PERIODIC reading and nothing else, and
// it does not ask for data it will not draw.
//
// Issue #102: under 48 hours that card used to fall back to hourly BARS, which
// is the timeline's answer one band up -- the same measure in the same
// chronological order, at literally the same 1h granularity on span=7d. The
// card's own hint promised hour x weekday the whole time. So the bars are gone,
// and with them the only reader the `granularity=hour` request ever had at that
// length -- which is what lets the request itself be skipped.
//
// This is a Go guard rather than a comment for the reason the others here are:
// both halves fail SILENTLY if they drift apart. A re-added bars() branch just
// draws a chart nobody notices is a duplicate, and a threshold copied into the
// fetch plan is a request sent for a card that will not read it (or, the other
// way, a card drawn from a hole).
func TestAssets_WhenCardIsPeriodicOnly(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "review.js")
	if err != nil {
		t.Fatalf("review.js unreadable: %v", err)
	}
	src := string(b)
	if strings.Contains(src, "C.bars(") {
		t.Error("review.js draws bars again: a chronological hourly chart is the timeline card's answer, " +
			"and the 'when' card's hint promises hour x weekday (issue #102)")
	}
	if !strings.Contains(src, "sel.to - sel.from < WHEN_MIN_MS ? null : get(`/v1/history?") {
		t.Error("the granularity=hour request is no longer gated on the selection being long enough to fold: " +
			"below WHEN_MIN_MS its only reader draws nothing, so the response has nowhere to go (issue #102)")
	}
	// ONE copy of the threshold. The card decides what to draw from it and the
	// fetch plan decides what to ask for from it; a second literal is how those
	// two answers start disagreeing about the same selection.
	if n := strings.Count(src, "48 * 3600e3"); n != 1 {
		t.Errorf("review.js spells the 48h threshold %d times, want 1 (WHEN_MIN_MS): "+
			"the when card and the fetch plan must read the same constant", n)
	}
}

// `by=model` has ONE rendering in the usage band, and the timeline is not it.
//
// Issue #103: the same cut was drawn three times on the default page — the
// timeline stacked by top-6 model, breakdown card 2 (`DEFAULTS.g2`), and the
// consumption table's per-provider expansion one band up. The consumption
// table is the primary reading, because (provider, model) is the only key
// under which a per-model cost is safe (commit 321e027). The timeline's stack
// is the copy that went: that card is the page's SELECTOR, and its question is
// "when did work run", which a stack of coloured bands does not answer any
// better for having also half-answered "which model".
//
// Both halves are asserted because both fail silently. A re-added
// `stack: 'model'` draws a chart nobody notices is breakdown 2 in worse
// notation AND pays for a per-bucket top-6 breakdown on every span change; a
// `DEFAULTS.g2` moved off `model` empties the efficiency card's "$ per 1M
// output by model" list on every first screen, because issue #93 deleted the
// dedicated fetch behind it and left that list reading breakdown 2's response.
// The two are one decision and neither can be changed alone.
func TestDashboard_ModelIsCutOnceInTheUsageBand(t *testing.T) {
	assets := Assets()
	read := func(name string) string {
		b, err := fs.ReadFile(assets, name)
		if err != nil {
			t.Fatalf("%s unreadable: %v", name, err)
		}
		return string(b)
	}

	review := read("review.js")
	if strings.Contains(review, "stack: 'model'") {
		t.Error("review.js asks /v1/history for `stack=model` again: the timeline is the page's selector " +
			"and breakdown card 2 already draws that cut with numbers, a share and a previous-period mark (issue #103)")
	}
	if strings.Contains(review, "stackNames:") {
		t.Error("review.js stacks the timeline again (issue #103): one bar per bucket is the whole point — " +
			"the stack's top-6 membership re-ranks as the brush moves, which is the worst notation on the page for a ranking")
	}

	// The surviving copy, and the reason it survives: the efficiency card has
	// no by=model fetch of its own since #93.
	if !strings.Contains(read("lib/state.js"), "g2: 'model'") {
		t.Error("DEFAULTS.g2 is no longer 'model': the efficiency card's \"$ per 1M output by model\" list reads " +
			"breakdown card 2's response and has no fetch of its own (issue #93), so it now renders its " +
			"\"group breakdown 2 by model\" empty state on every default load (issue #103)")
	}
	if !strings.Contains(review, "state.g2 === 'model'") {
		t.Error("the efficiency card no longer gates on breakdown 2 being by model; if it gained its own " +
			"by=model fetch, DEFAULTS.g2 is free to move and this guard should say so instead of failing (issue #103)")
	}
}

// `source` and `provider` are two axes, and the page says so.
//
// Issue #103: they read as the same "group by vendor" cut to anyone who has
// not been told otherwise, and the difference — source is which tool reported
// the call, provider is who served it — lived only in web/dist/consumption.js's
// header comment, which no reader of the dashboard can see. Merging them is
// the one thing that must never happen here (it adds two invoices into one
// number), so the distinction has to be legible where a reader meets it.
//
// Asserted on the dictionaries rather than on rendered HTML because the strings
// are the artifact: a note deleted as redundant is exactly the silent failure.
func TestDashboard_SourceAndProviderAreDistinguishedOnThePage(t *testing.T) {
	assets := Assets()
	for _, loc := range []string{"lib/i18n/en.js", "lib/i18n/zh-CN.js"} {
		b, err := fs.ReadFile(assets, loc)
		if err != nil {
			t.Fatalf("%s unreadable: %v", loc, err)
		}
		if !strings.Contains(string(b), "breakdown.sourceNote") {
			t.Errorf("%s has no breakdown.sourceNote: the breakdown card grouped by source no longer tells a "+
				"reader how that axis differs from the consumption table's upstream (issue #103)", loc)
		}
	}
	if !strings.Contains(string(mustRead(t, assets, "review.js")), "dim === 'source' ?") {
		t.Error("review.js no longer prints the source note on the breakdown card: the string exists but " +
			"nothing renders it, which is the same as not having it (issue #103)")
	}
}

func mustRead(t *testing.T, assets fs.FS, name string) []byte {
	t.Helper()
	b, err := fs.ReadFile(assets, name)
	if err != nil {
		t.Fatalf("%s unreadable: %v", name, err)
	}
	return b
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

// The attribution seam must stay visible, whatever shape it is drawn in.
//
// README's "Known limits" makes a promise the code has to keep: when a machine
// logs out of one subscription and into another, rows already ingested keep
// their old attribution and CANNOT be corrected, so ccquota records the switch
// "so the seam is visible in the UI rather than silently wrong". That is the
// one thing the dashboard must not quietly stop doing.
//
// #100 downgraded the seam from a resident card to a column of the endpoint
// roster, which is a change of shape and explicitly allowed. Deleting the
// request, or the column, is a change of PROMISE — and it would look like an
// ordinary cleanup in a diff, because nothing else on the page reads
// /v1/account-switches. This test is what makes that specific deletion loud.
//
// Deliberately not asserting a card, a table or a heading: the point is that
// the page still ASKS and still RENDERS, not that it does so in the layout
// #100 happened to pick.
func TestDashboard_AttributionSeamStaysVisible(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "now.js")
	if err != nil {
		t.Fatal(err)
	}
	// The CALL, not the path. now.js names both these routes in prose too (the
	// comment where the two deleted cards used to be), and an assertion that a
	// comment satisfies is an assertion that goes green on the regression it
	// exists to catch. `get(...)` is the local helper that builds renderNow's
	// fetcher list, so this matches the request actually being sent.
	if !strings.Contains(string(b), "get(`/v1/account-switches") {
		t.Error("now.js no longer requests /v1/account-switches -- nothing else on the page reads it, " +
			"so the attribution seam README's \"Known limits\" promises to show is now invisible")
	}
	// Asked for AND drawn. A request whose result no card reads is the same
	// invisibility with a network cost attached.
	//
	// Both of these are CALL sites, for the same reason the request above is:
	// a bare identifier would still match after someone renamed the renderer
	// out of use, which is exactly the regression being guarded.
	for _, want := range []string{"t('endpoints.col.lastSwitch')", "switchCell(seam.get("} {
		if !strings.Contains(string(b), want) {
			t.Errorf("now.js is missing %q -- the switch record is fetched but no longer rendered "+
				"into the roster, which shows a clean history that is not clean", want)
		}
	}
	// A failed switch query must not read as "nobody switched". Empty is an
	// answer; unreadable is not, and the two must not render the same.
	if !strings.Contains(string(b), "endpoints.switchUnavailable") {
		t.Error("now.js no longer distinguishes a FAILED switch query from an empty one -- " +
			"a seam that could not be read must not be drawn as a seam that is not there")
	}
}

// The operations tier must not pay for /v1/endpoint-accounts on every open.
//
// #100's subtraction: the per-machine subscription list was a resident card
// costing a request on every open of the tier, answering a question ("which
// subscriptions does this machine run") that matters when you are chasing one
// specific machine and never otherwise. It is the roster's ⊞ reveal now, so the
// request is sent on demand, from the click handler -- not from renderNow's
// fetcher list.
//
// The regression this catches is the easy one: someone re-adds the fetcher to
// get the data "for free" at render time, and the request quietly returns to
// the default path where nothing reads it until a reader goes looking.
func TestDashboard_EndpointAccountsIsFetchedOnDemand(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "now.js")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	// Matched on the reveal's own call site rather than on the bare path: the
	// path also appears in prose a few hundred lines up, and a comment must not
	// be able to satisfy this.
	if !strings.Contains(src, "app.api(`/v1/endpoint-accounts") {
		t.Fatal("now.js no longer requests /v1/endpoint-accounts from the roster's ⊞ reveal -- " +
			"the reveal has no source, and nothing else on the page can say which subscriptions " +
			"a machine runs (the concurrency README's \"Several subscriptions at the same time\" documents)")
	}
	// The fetcher list is built with the local `get(...)` helper, which is what
	// makes a request part of the default round. The lazy reveal calls
	// app.api(...) directly from its click handler.
	if strings.Contains(src, "get(`/v1/endpoint-accounts") {
		t.Error("/v1/endpoint-accounts is back in renderNow's fetcher list -- it is sent on every " +
			"open of the operations tier again, to fill a reveal most readers never open")
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

// The sentinel is one value with two spellings, and the failure is silent.
//
// store.Undeclared is what the hub matches a blank dimension against; rows.js
// declares the same literal because it is the dashboard that TYPES it into the
// query string. Drift does not error anywhere: the page would send "(none)"
// against a hub expecting something else, `eq` would treat it as an ordinary
// provider name, and the "declares no upstream" row would go back to answering
// with zero rows instead of every row -- a different wrong answer to the same
// question issue #134 was about.
//
// Asserted as the exported declaration rather than a bare substring so that
// deleting the constant is as loud as changing it.
func TestDashboard_UndeclaredSentinelMatchesTheStore(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "lib/rows.js")
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("export const UNDECLARED = '%s';", store.Undeclared)
	if !strings.Contains(string(b), want) {
		t.Errorf("lib/rows.js does not declare %q -- the dashboard's drill-down sentinel has drifted "+
			"from store.Undeclared (%q), which is what internal/store/filter.go matches a blank "+
			"dimension against", want, store.Undeclared)
	}
	// The regression itself: sending the row's own empty key as the chip. That
	// is what made expanding a blank bucket return every upstream on the hub.
	c, err := fs.ReadFile(Assets(), "consumption.js")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(c), "provider: row.provider,") {
		t.Error("consumption.js sends the blank row's own empty key as ?provider= again -- " +
			"an empty chip means NO CONSTRAINT, which is the #134 bug")
	}
}

// The default page is not the whole page, and the record of how it got that way
// is still in the file.
//
// Issue #130 is the FOURTH turn this page has taken on "what is the navigation",
// and it is the one with no other guard. The JS tests pin bandsFor and VIEWS;
// nothing outside them pins the two things that are easiest to undo by accident
// from the Go side of this repo, where index.html and the embedded modules are
// the contract:
//
//  1. The default view is a SET of its own (nav.js's DEFAULT_BANDS), and
//     state.js's DEFAULTS points at it rather than at `all`. A "simplification"
//     that points the default back at every band passes every assertion about
//     `all` — because `all` is unchanged — while quietly restoring the whole
//     page, every band and every request those bands read on every first
//     screen. That is the entire saving of #130, reverted in one word.
//  2. `all` still exists and still means all. It is the bar's way back to the
//     whole page; narrowing it would leave this page with no view that shows
//     usage, progress and operations together at all.
//
// And the record itself, which EPIC #122's charter requires be APPENDED to and
// never trimmed: nav.js's header carries all four turns (no navigation → the
// anchor nav of #54 → the mounting views of #98 → this one). A later edit that
// "tidies" that header by keeping only the current position deletes the only
// place this page explains why it is shaped the way it is — the same failure
// mode as deleting a limiting sentence because it reads like an explanation.
func TestDashboard_TheDefaultViewIsNotTheWholePage(t *testing.T) {
	assets := Assets()
	read := func(name string) string {
		b, err := fs.ReadFile(assets, name)
		if err != nil {
			t.Fatalf("%s unreadable: %v", name, err)
		}
		return string(b)
	}

	nav, state := read("lib/nav.js"), read("lib/state.js")

	// The default is its own set, and the set is the one #122 拍板 6 named.
	if !strings.Contains(nav, "export const DEFAULT_BANDS") {
		t.Error("lib/nav.js no longer exports DEFAULT_BANDS -- the default view is a set of its own (#130); " +
			"without it the only way to be the default again is to BE `all`, which is the page this change stopped opening")
	}
	if !strings.Contains(nav, "export const VIEW_DEFAULT") {
		t.Error("lib/nav.js no longer exports VIEW_DEFAULT -- the default needs a word of its own, or the bar " +
			"has nothing to mark on the page every shared link lands on (scope.js's syncNav marks by view)")
	}
	if !strings.Contains(state, "view: VIEW_DEFAULT") {
		t.Error("state.js's DEFAULTS.view is not VIEW_DEFAULT any more: a bare URL is opening some other view. " +
			"If that is `all`, every band and every request it reads is back on every first screen (#130)")
	}

	// ...and `all` is untouched by it.
	if !strings.Contains(nav, "export const VIEW_ALL = 'all'") {
		t.Error("lib/nav.js no longer spells VIEW_ALL = 'all': #130 made the default a smaller set, " +
			"it did not retire the whole page -- `all` is the bar's only way back to it")
	}

	// The four turns. Matched on the numbered markers rather than on prose, so
	// rewording a paragraph is free and dropping one is not.
	for _, turn := range []string{"#54", "#98", "#130"} {
		if !strings.Contains(nav, turn) {
			t.Errorf("lib/nav.js's header no longer mentions %s -- it records every position this page has taken "+
				"on its own navigation, and EPIC #122 requires the fourth be APPENDED to the first three, not replace them", turn)
		}
	}
	if !strings.Contains(nav, "FOURTH position") {
		t.Error("lib/nav.js no longer opens by saying how many positions this page has taken on the same question; " +
			"that count is what makes the next person read the three that were overturned before adding a fifth")
	}
}
