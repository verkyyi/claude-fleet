package api

import (
	"net/http"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

// The door map's contract, in four parts: it is gated, it is complete, it is
// live, and it leaks nothing.

// Gated. A page that names the tailnet allowlist and says whether SSO is on
// must not answer someone who holds no credential -- that is precisely the
// answer /enter's unconditional 404 exists to withhold.
func TestAccess_NeedsTheViewerToken(t *testing.T) {
	h := newHarness(t)
	for _, path := range []string{"/v1/access", "/access", "/access/"} {
		resp, err := http.Get(h.http.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("GET %s with no credential = %d; want 401", path, resp.StatusCode)
		}
	}
}

// Complete. The point of this issue was that nothing in the binary listed the
// ways in, so an incomplete list is the bug coming back. Every door the router
// actually mounts has to be in the table, and the CLI -- the one that is not
// on HTTP at all -- most of all: leaving it out is how "one process" got read
// as "one entrance".
func TestAccess_ListsEveryDoorIncludingTheOneThatIsNotHTTP(t *testing.T) {
	h := newHarness(t)

	var m AccessMap
	h.getJSON(t, "/v1/access", &m)

	want := map[string]string{
		"dashboard": "http",
		"enter":     "http",
		"api":       "http",
		"mcp":       "http",
		"ingest":    "http",
		"share":     "http",
		"badges":    "http",
		"healthz":   "http",
		"cli":       "hub-shell",
	}
	got := map[string]Door{}
	for _, d := range m.Doors {
		got[d.ID] = d
	}
	for id, via := range want {
		d, ok := got[id]
		if !ok {
			t.Errorf("door %q is missing from /v1/access", id)
			continue
		}
		if d.Via != via {
			t.Errorf("door %q via = %q; want %q", id, d.Via, via)
		}
		// A row with no credential named is worse than no row: it reads as
		// "just open it".
		for field, v := range map[string]string{"name": d.Name, "credential": d.Credential, "can": d.Can, "note": d.Note} {
			if strings.TrimSpace(v) == "" {
				t.Errorf("door %q has an empty %s", id, field)
			}
		}
		if d.State != "open" && d.State != "public" && d.State != "off" {
			t.Errorf("door %q state = %q; want open, public or off", id, d.State)
		}
	}
	for id := range got {
		if _, ok := want[id]; !ok {
			t.Errorf("door %q is reported but not expected -- add it to this test with its Via", id)
		}
	}
	if !strings.Contains(m.OneProcess, "not an access fact") {
		t.Errorf("the one-process caveat did not travel in the payload: %q", m.OneProcess)
	}
}

// Live. The whole reason this is an endpoint rather than a README section is
// that it reports THIS hub. Flip each switch and the map has to change.
func TestAccess_ReportsWhatIsActuallyTurnedOn(t *testing.T) {
	h := newHarness(t)

	var off AccessMap
	h.getJSON(t, "/v1/access", &off)
	if off.Hub.SSO.Enabled {
		t.Error("SSO reported as enabled on a hub that never configured it")
	}
	if len(off.Hub.TailnetViewers) != 0 {
		t.Errorf("tailnet viewers = %v; want none", off.Hub.TailnetViewers)
	}
	if off.Hub.PublicBadges {
		t.Error("public badges reported on by default; they are off by default")
	}
	if doorState(off.Doors, "badges") != "open" {
		t.Errorf("badges door = %q with --public-badges off; want open", doorState(off.Doors, "badges"))
	}
	if doorState(off.Doors, "mcp") != "off" {
		t.Errorf("mcp door = %q with no MCP handler; want off", doorState(off.Doors, "mcp"))
	}
	if !strings.Contains(doorNote(off.Doors, "enter"), "404") {
		t.Errorf("the /enter row does not say it 404s when SSO is unconfigured: %q", doorNote(off.Doors, "enter"))
	}

	// Now turn things on. The handler reads the Server at request time, so
	// this is the same hub answering differently -- which is the claim.
	h.srv.PublicBadges = true
	h.srv.MCP = http.NotFoundHandler()
	h.srv.SSO = &SSO{
		AppID: "ccquota", Slug: "ops", TicketSecret: "t", SessionSecret: "s",
		EnterURL: "https://ai.example.com/enter", TTL: 3 * time.Hour,
	}
	h.srv.Tailnet = NewTailnetViewers([]string{"Ada@example.com", "bob@example.com"}, nil, nil)
	h.srv.Listeners = ListenerFacts{HTTP: []string{"127.0.0.1:8787"}, HTTPS: ":443", HTTPSURL: "https://hub.example.ts.net/"}

	var on AccessMap
	h.getJSON(t, "/v1/access", &on)
	if !on.Hub.SSO.Enabled || on.Hub.SSO.EnterURL != "https://ai.example.com/enter" {
		t.Errorf("SSO facts = %+v; want enabled with the enter URL", on.Hub.SSO)
	}
	if on.Hub.SSO.SessionHours != 3 {
		t.Errorf("session hours = %v; want 3", on.Hub.SSO.SessionHours)
	}
	// Lower-cased and sorted, the same normalisation the gate itself applies,
	// so the page cannot imply an allowlist entry that would never match.
	if got := strings.Join(on.Hub.TailnetViewers, ","); got != "ada@example.com,bob@example.com" {
		t.Errorf("tailnet viewers = %q; want the allowlist lower-cased and sorted", got)
	}
	if !on.Hub.PublicBadges || doorState(on.Doors, "badges") != "public" {
		t.Errorf("badges door = %q with --public-badges on; want public", doorState(on.Doors, "badges"))
	}
	if doorState(on.Doors, "mcp") != "open" {
		t.Errorf("mcp door = %q with MCP mounted; want open", doorState(on.Doors, "mcp"))
	}
	if on.Hub.Listeners.HTTPSURL != "https://hub.example.ts.net/" {
		t.Errorf("https url = %q; want the one the hub bound", on.Hub.Listeners.HTTPSURL)
	}
	// The dashboard row lists the ways in, so a new one has to show up there
	// too -- a reader who reads only the row must not be told "token only"
	// while two other credentials work.
	note := doorNote(on.Doors, "dashboard")
	for _, want := range []string{"viewer token", "WeCom", "tailnet"} {
		if !strings.Contains(note, want) {
			t.Errorf("the dashboard row does not mention %q: %q", want, note)
		}
	}
}

// Live, second half: the counts come from the database, not from a constant.
func TestAccess_CountsEnrollmentsAndShareLinks(t *testing.T) {
	h := newHarness(t)
	h.enroll(t, "laptop")
	h.enroll(t, "desktop")
	h.enrollKind(t, "repo-bot", "repo_shipper")
	h.enrollKind(t, "monday-brief", "growth_reader")

	if _, err := h.srv.Store.CreateShareLink("board", HashToken("s1"), false, nil); err != nil {
		t.Fatal(err)
	}
	gone, err := h.srv.Store.CreateShareLink("old", HashToken("s2"), false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RevokeShareLink(gone.ID); err != nil {
		t.Fatal(err)
	}

	var m AccessMap
	h.getJSON(t, "/v1/access", &m)

	for kind, want := range map[string]int{"agent": 2, "repo_shipper": 1, "growth_reader": 1} {
		if m.Hub.Enrollments[kind] != want {
			t.Errorf("enrollments[%q] = %d; want %d", kind, m.Hub.Enrollments[kind], want)
		}
	}
	if m.Hub.ShareLinks.Active != 1 || m.Hub.ShareLinks.Total != 2 {
		t.Errorf("share links = %+v; want 1 active of 2", m.Hub.ShareLinks)
	}
	// A revoked link is not an open door, and the row has to say the number
	// that is still usable rather than the number ever minted.
	if note := doorNote(m.Doors, "share"); !strings.Contains(note, "1 active link") {
		t.Errorf("the share row does not report the active count: %q", note)
	}
	if note := doorNote(m.Doors, "ingest"); !strings.Contains(note, "2 agents") {
		t.Errorf("the ingest row does not report the enrolled agents: %q", note)
	}
}

// Leaks nothing. This is the assertion that must never be deleted: the page
// describes credentials, and the moment it starts carrying one it has become
// the door it was written to explain.
func TestAccess_CarriesNoSecret(t *testing.T) {
	h := newHarness(t)
	h.srv.SSO = &SSO{
		AppID: "ccquota", TicketSecret: "ticket-key-do-not-leak",
		SessionSecret: "session-key-do-not-leak", EnterURL: "https://ai.example.com/enter",
	}
	shareTok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.CreateShareLink("board", HashToken(shareTok), true, nil); err != nil {
		t.Fatal(err)
	}
	enrollTok := h.enroll(t, "laptop")

	_, body := h.get(t, "/v1/access")
	for name, secret := range map[string]string{
		"the viewer token":     viewerToken,
		"a share token":        shareTok,
		"an enrollment token":  enrollTok,
		"the SSO ticket key":   "ticket-key-do-not-leak",
		"the SSO session key":  "session-key-do-not-leak",
		"a share token's hash": HashToken(shareTok),
	} {
		if strings.Contains(string(body), secret) {
			t.Errorf("/v1/access carries %s", name)
		}
	}
}

// A no-auth hub is a real configuration and the page has to say so plainly
// rather than printing the usual "you need a token" and being wrong.
func TestAccess_SaysWhenAuthIsOff(t *testing.T) {
	h := newHarness(t)
	h.srv.ViewerToken = ""

	var m AccessMap
	h.getJSON(t, "/v1/access", &m)
	if m.Hub.ViewerAuth != "off (--no-auth)" {
		t.Errorf("viewer auth = %q; want it to name --no-auth", m.Hub.ViewerAuth)
	}
	if note := doorNote(m.Doors, "dashboard"); !strings.Contains(note, "NO viewer token") {
		t.Errorf("the dashboard row still implies a token is needed: %q", note)
	}
}

// The page is served, and it is served from the embedded UI rather than
// rendered -- a binary built without a dashboard says so instead of 404-ing
// mysteriously.
func TestAccess_ServesItsPage(t *testing.T) {
	h := newHarness(t)
	h.srv.UI = fstest.MapFS{
		"access.html": &fstest.MapFile{Data: []byte("<!doctype html><title>Ways in</title>")},
	}
	resp, body := h.get(t, "/access")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /access = %d; want 200", resp.StatusCode)
	}
	if !strings.Contains(string(body), "Ways in") {
		t.Errorf("GET /access did not serve access.html: %q", body)
	}
	// /access/ must be the page too, not the SPA's index.html fallback.
	if code := h.getCode(t, "/access/"); code != http.StatusOK {
		t.Errorf("GET /access/ = %d; want 200", code)
	}

	h.srv.UI = nil
	if code := h.getCode(t, "/access"); code != http.StatusNotFound {
		t.Errorf("GET /access with no UI = %d; want 404", code)
	}
	// The data still answers: an operator on a UI-less build is exactly the
	// person who needs the door map, and they can read it as JSON.
	if code := h.getCode(t, "/v1/access"); code != http.StatusOK {
		t.Errorf("GET /v1/access with no UI = %d; want 200", code)
	}
}

func doorState(doors []Door, id string) string {
	for _, d := range doors {
		if d.ID == id {
			return d.State
		}
	}
	return "<missing>"
}

func doorNote(doors []Door, id string) string {
	for _, d := range doors {
		if d.ID == id {
			return d.Note
		}
	}
	return "<missing>"
}
