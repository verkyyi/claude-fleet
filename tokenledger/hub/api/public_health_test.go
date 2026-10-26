package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestPublicHealthAnonymousPrivacyAndPrivateExtension(t *testing.T) {
	h, admin, member := rolesHarness(t)
	now := time.Now().Truncate(time.Minute)
	for _, k := range healthComponents {
		_, err := h.srv.Store.RecordHealthProbe(store.HealthProbe{Component: k, At: now.UnixMilli(), State: "ok", MS: 10}, 3)
		must(t, err)
	}
	must(t, h.srv.Store.RecordLinkPing("secret-machine", "secret-login", now, 100, true))
	must(t, h.srv.Store.RecordLinkPing("other-machine", "other-login", now, 300, true))
	must(t, h.srv.Store.RecordChatTiming(store.ChatTiming{At: now, MS: 1200, Agent: "codex", Machine: "secret-machine"}))
	code, body := rolesGet(t, h, nil, PublicHealthPath)
	if code != 200 {
		t.Fatalf("anonymous %d %s", code, body)
	}
	var data map[string]any
	must(t, json.Unmarshal(body, &data))
	if data["state"] != "ok" || data["latency"].(map[string]any)["mean_ms"] != float64(200) {
		t.Fatal(data)
	}
	for _, forbidden := range []string{"secret-", "other-", `"links"`, `"admin"`, `"n"`, `"fails"`, `"machine"`, `"login"`, `"requests_1h_replica"`, `"release"`} {
		if strings.Contains(string(body), forbidden) {
			t.Fatalf("public field %s: %s", forbidden, body)
		}
	}
	// An admin cookie or query cannot turn the shared cache into a private response.
	for _, cookie := range []*http.Cookie{admin, member} {
		c, b := rolesGet(t, h, cookie, PublicHealthPath+"?admin=1&token=invalid&as=someone")
		if c != 200 || string(b) != string(body) {
			t.Fatalf("identity varied cache: %d %s", c, b)
		}
	}
	if code, _ := rolesGet(t, h, nil, HealthPath); code == 200 {
		t.Fatal("private extension lost authentication")
	}
	if code, b := rolesGet(t, h, member, HealthPath); code != 200 || strings.Contains(string(b), `"admin"`) {
		t.Fatalf("member %d %s", code, b)
	}
	if code, b := rolesGet(t, h, admin, HealthPath); code != 200 || !strings.Contains(string(b), `"admin"`) {
		t.Fatalf("admin %d %s", code, b)
	}
}

func TestPublicHealthCacheCoalescingEditionAndFailures(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.SiteHosts = map[string]string{"tokenman.io": SiteEditionSandbox}
	hd := h.srv.Handler()
	get := func(host string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		hd.ServeHTTP(w, httptest.NewRequest("GET", "https://"+host+PublicHealthPath, nil))
		return w
	}
	first := get("claudefleet.example.com")
	if first.Code != 200 || !strings.Contains(first.Body.String(), `"language":"zh"`) || first.Header().Get("Cache-Control") != "public, max-age=30, s-maxage=30" || first.Header().Get("Set-Cookie") != "" {
		t.Fatal(first)
	}
	// Neither a query, concurrent cold-edition requests nor an auth header
	// reloads the store while the single snapshot is fresh.
	st := h.srv.Store
	h.srv.Store = nil
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := get("tokenman.io")
			if w.Code != 200 || !strings.Contains(w.Body.String(), `"language":"en"`) {
				t.Errorf("cached edition %d %s", w.Code, w.Body.String())
			}
		}()
	}
	wg.Wait()
	h.srv.Store = st
	must(t, st.Close())
	h.srv.publicHealth.until = time.Time{}
	w := get("tokenman.io")
	if w.Code != 503 || strings.Contains(w.Body.String(), "database") || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("failure %d %s", w.Code, w.Body.String())
	}
	// Failed refreshes are cached too, so a database outage cannot amplify queries.
	h.srv.Store = nil
	w = get("tokenman.io")
	h.srv.Store = st
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
}

func TestPublicHealthRoutesLimitsAndMethods(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("PUBLIC-STATUS-ENTRY")}}
	h.srv.ChatFrameOrigins = []string{"https://private.example"}
	hd := h.srv.Handler()
	for _, path := range []string{"/status", PublicHealthPath} {
		w := httptest.NewRecorder()
		hd.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 200 || w.Header().Get("Set-Cookie") != "" || strings.Contains(w.Header().Get("Content-Security-Policy"), "private.example") {
			t.Fatal(w)
		}
		w = httptest.NewRecorder()
		hd.ServeHTTP(w, httptest.NewRequest("HEAD", path, nil))
		if w.Code != 200 || w.Body.Len() != 0 {
			t.Fatal(w)
		}
		w = httptest.NewRecorder()
		hd.ServeHTTP(w, httptest.NewRequest("POST", path, strings.NewReader(`{"note_en":"changed"}`)))
		if w.Code != 405 {
			t.Fatal(w.Code)
		}
	}
	c := &h.srv.publicHealth
	c.rateMu.Lock()
	c.last = time.Now()
	c.tokens = 0
	c.rateMu.Unlock()
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", PublicHealthPath+"?cachebust=1", nil)
	r.Header.Set("X-Forwarded-For", "1.2.3.4")
	hd.ServeHTTP(w, r)
	if w.Code != 429 || w.Header().Get("Retry-After") == "" || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal(w)
	}
	lim := publicHealthCache{}
	now := time.Now()
	for i := 0; i < 120; i++ {
		if !lim.allow(now) {
			t.Fatal("burst too small")
		}
	}
	if lim.allow(now) {
		t.Fatal("unlimited")
	}
	for i := 0; i < 60; i++ {
		if !lim.allow(now.Add(time.Second)) {
			t.Fatal("refill")
		}
	}
	if lim.allow(now.Add(time.Second)) {
		t.Fatal("refill unbounded")
	}
}

func TestPublicHealthFiltersLegacyDiagnosticNotes(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now().Truncate(time.Minute)
	for i := 0; i < 3; i++ {
		_, err := h.srv.Store.RecordHealthProbe(store.HealthProbe{Component: "wechat", At: now.Add(time.Duration(i-2) * time.Minute).UnixMilli(), State: "failed"}, 3)
		must(t, err)
	}
	events, err := h.srv.Store.HealthEvents(now.Add(-time.Hour))
	must(t, err)
	if len(events) != 1 {
		t.Fatal(events)
	}
	_, err = h.srv.Store.AnnotateHealthEvent(events[0].ID, "内部 2001:db8::1", "http://private.example/token")
	must(t, err)
	out, err := h.srv.publicHealthSnapshot(now)
	must(t, err)
	if len(out.Events) != 1 || out.Events[0].NoteZH != "" || out.Events[0].NoteEN != "" {
		t.Fatal(out.Events)
	}
}

func TestPublicHealthStaysOnEditionHostWithPortal(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.PortalURL = "https://portal.example.com"
	h.srv.PortalAliases = []string{"claudefleet.example.com", "tokenman.example.com"}
	h.srv.SiteHosts = map[string]string{"tokenman.example.com": SiteEditionSandbox}
	h.srv.ConsoleFS = fstest.MapFS{
		"app/index.html":           {Data: []byte("PUBLIC-STATUS")},
		"app/assets/main.js":       {Data: []byte("PUBLIC-ASSET")},
		"app/manifest.webmanifest": {Data: []byte("{}")},
	}
	hd := h.srv.Handler()
	for _, host := range h.srv.PortalAliases {
		for _, path := range []string{"/status", PublicHealthPath, "/app/assets/main.js", AppManifestPath} {
			w := httptest.NewRecorder()
			hd.ServeHTTP(w, httptest.NewRequest("GET", "https://"+host+path, nil))
			if w.Code != 200 || w.Header().Get("Location") != "" {
				t.Fatalf("%s%s: %d %s", host, path, w.Code, w.Header().Get("Location"))
			}
			if path == PublicHealthPath {
				want := `"language":"zh"`
				if host == "tokenman.example.com" {
					want = `"language":"en"`
				}
				if !strings.Contains(w.Body.String(), want) {
					t.Fatal(w.Body.String())
				}
			}
		}
		w := httptest.NewRecorder()
		hd.ServeHTTP(w, httptest.NewRequest("GET", "https://"+host+"/app", nil))
		if w.Code != 301 || w.Header().Get("Location") != "https://portal.example.com/app" {
			t.Fatal("ordinary portal redirect changed", w)
		}
	}
}
