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

func TestBadgeRoute_ForwardsParams(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET",
		"/badge/u/alice.svg?theme=auto&bg=transparent&pac=ff0000&from=4000", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{"prefers-color-scheme:dark", "#ff0000"} {
		if !strings.Contains(body, want) {
			t.Errorf("param not applied: missing %q", want)
		}
	}
	if strings.Contains(body, `fill="var(--g)"`) {
		t.Error("bg=transparent still paints a ground")
	}
	// from=4000 -> 4242: ones wheel starts on 0 and travels 242 steps capped.
	if !strings.Contains(body, `class="w"`) {
		t.Error("no wheels")
	}
}

// The raw figure is what a live embed polls. It is data, not a badge, so it
// must never be cached -- and it is behind exactly the same gate as the SVG.
func TestBadgeRoute_RawJSON(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/badge/u/alice.json?format=raw&period=30d", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "no-store") {
		t.Errorf("raw figure is cacheable (%q); a live embed would poll a stale copy", cc)
	}
	for _, want := range []string{`"tokens":4242`, `"period":"30d"`} {
		if !strings.Contains(rec.Body.String(), want) {
			t.Errorf("raw JSON missing %s: %s", want, rec.Body.String())
		}
	}

	closed := badgeServer(t, false)
	rec = httptest.NewRecorder()
	closed.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/badge/u/alice.json?format=raw", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("raw JSON served without a token while --public-badges is off (status %d)", rec.Code)
	}
}

func TestEmbedPage(t *testing.T) {
	s := badgeServer(t, true)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/embed/u/alice?theme=auto&bg=transparent&every=15", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("Content-Type = %q", ct)
	}
	body := rec.Body.String()
	// It embeds the badge for this login and forwards the params to it.
	if !strings.Contains(body, "/badge/u/alice.svg?") || !strings.Contains(body, "theme=auto") || !strings.Contains(body, "bg=transparent") {
		t.Error("embed page does not point at this login's badge with the given params")
	}
	// It polls the raw figure, never the SVG, to decide whether to roll.
	if !strings.Contains(body, "format=raw") {
		t.Error("embed page does not poll the raw figure")
	}
	// It is self-contained: nothing loads from anywhere but this hub.
	for _, forbidden := range []string{"http://", "https://", "<link", "@import"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("embed page references %q; it must be self-contained", forbidden)
		}
	}
	// A hostile login in the path must not become markup.
	rec = httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/embed/u/%3Cscript%3Ealert(1)%3C%2Fscript%3E", nil))
	if strings.Contains(rec.Body.String(), "<script>alert") {
		t.Error("embed page interpolates the login into HTML unescaped")
	}
}

func TestEmbedPage_SameGateAsBadges(t *testing.T) {
	s := badgeServer(t, false)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/embed/u/alice", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("embed page served without a token while --public-badges is off (status %d)", rec.Code)
	}
}

func TestJSString(t *testing.T) {
	got := jsString(`a"b\c</script>&`)
	want := `"a\"b\\c\u003c/script\u003e\u0026"`
	if got != want {
		t.Errorf("jsString = %s, want %s", got, want)
	}
	// The one property that matters: a closing tag cannot survive.
	if strings.Contains(got, "</script>") {
		t.Error("jsString lets </script> through; a login could end the script block")
	}
}
