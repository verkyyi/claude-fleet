package api

import (
	"context"
	"encoding/json"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestHealthPrivacyFreshnessAndNotes(t *testing.T) {
	h, admin, user := rolesHarness(t)
	now := time.Now().Truncate(time.Minute)
	for _, k := range healthComponents {
		_, err := h.srv.Store.RecordHealthProbe(store.HealthProbe{Component: k, At: now.UnixMilli(), State: "ok", MS: 12}, 3)
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.RecordLinkPing("private-machine", "private-login", now, 100, true); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: githubPrincipal(ghAlice.ID), Machine: "own-machine", Login: "own-login", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.RecordLinkPing("own-machine", "own-login", now, 123, true); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.RecordChatTiming(store.ChatTiming{At: now, MS: 1200, Agent: "codex", Machine: "private-machine"}); err != nil {
		t.Fatal(err)
	}
	if code, _ := rolesGet(t, h, nil, HealthPath); code == 200 {
		t.Fatal("anonymous health allowed")
	}
	code, b := rolesGet(t, h, user, HealthPath)
	if code != 200 {
		t.Fatalf("member: %d %s", code, b)
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out["admin"] != nil || out["state"] != "ok" || strings.Contains(string(b), "private-") || strings.Contains(string(b), "own-machine") || !strings.Contains(string(b), `"mean_ms":123`) {
		t.Fatalf("member data: %s", b)
	}
	code, b = rolesGet(t, h, admin, HealthPath)
	if code != 200 || !strings.Contains(string(b), "requests_1h_replica") || strings.Contains(string(b), "private-") {
		t.Fatalf("admin data: %s", b)
	}
	// Unmonitored/stale is not an operational result.
	h2 := newFleetHarness(t)
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", HealthPath, nil)
	h2.srv.handleHealth(w, r)
	if !strings.Contains(w.Body.String(), `"state":"degraded"`) {
		t.Fatal(w.Body.String())
	}
	// No member may add a public note, and admins cannot add raw addresses.
	for _, tc := range []struct {
		role, body string
		want       int
	}{{roleUser, `{}`, 403}, {roleAdmin, `{"id":"x","note_en":"http://internal.example/token"}`, 400}, {roleAdmin, `{"id":"missing","note_en":"Investigating"}`, 404}} {
		r = httptest.NewRequest("POST", HealthPath, strings.NewReader(tc.body))
		r.Header.Set("X-Fleet-Webchat", "1")
		r = r.WithContext(withRole(r.Context(), tc.role))
		w = httptest.NewRecorder()
		h.srv.annotateHealth(w, r)
		if w.Code != tc.want {
			t.Fatalf("note %s: %d %s", tc.role, w.Code, w.Body.String())
		}
	}
}
func TestHealthProbesDedupAndNoLoginSideEffects(t *testing.T) {
	h := newFleetHarness(t)
	failing := true
	calls := 0
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			writeJSON(w, 200, map[string]any{"access_token": "fake-secret", "expires_at": time.Now().Add(time.Hour).Unix()})
			return
		}
		if r.URL.Path == "/cgi-bin/qrcode/create" {
			calls++
			if failing {
				writeJSON(w, 200, map[string]any{"errcode": 61004, "errmsg": "fake-secret internal.example"})
			} else {
				writeJSON(w, 200, map[string]any{"url": "https://example.com/unused"})
			}
			return
		}
		w.WriteHeader(503)
	}))
	defer fake.Close()
	h.srv.WxGW = &WxGateway{URL: fake.URL, Token: "gate-secret", APIBase: fake.URL}
	t.Setenv("CCQUOTA_HEALTH_TARGETS", `{"claudefleet":"`+fake.URL+`/healthz"}`)
	notices := []string{}
	h.srv.Notify = func(m string) { notices = append(notices, m) }
	now := time.Now().Truncate(time.Minute)
	for i := 0; i < 4; i++ {
		h.srv.probeHealth(context.Background(), now.Add(time.Duration(i)*time.Minute))
	}
	if calls != 4 || len(notices) != 2 {
		t.Fatalf("calls=%d notices=%v", calls, notices)
	}
	n, err := h.srv.Store.WxScenesSince(now.Add(-time.Hour))
	if err != nil || n != 0 {
		t.Fatalf("probe created login scenes %d %v", n, err)
	}
	ps, err := h.srv.Store.HealthProbes(now.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(ps)
	if strings.Contains(string(b), "secret") || strings.Contains(string(b), "internal.example") {
		t.Fatal(string(b))
	}
	failing = false
	h.srv.probeHealth(context.Background(), now.Add(4*time.Minute))
	es, _ := h.srv.Store.HealthEvents(now.Add(-time.Minute))
	for _, e := range es {
		if e.Component == "wechat" && e.Ended == 0 {
			t.Fatal("not resolved")
		}
	}
}
func TestHealthHTTPRejectsRedirect(t *testing.T) {
	h := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/signin", 302) }))
	defer h.Close()
	if healthHTTP(context.Background(), h.URL) == nil {
		t.Fatal("redirect was healthy")
	}
}

func TestHealthTargetsAndEdition(t *testing.T) {
	s := &Server{PublicHosts: map[string]string{"claudefleet.example.com": "https://claudefleet.example.com", "ccquota.example.com": "https://ccquota.example.com", "tokenman.io": "https://tokenman.io", "core.tokenman.io": "https://tokenman.io"}, FleetPublicURL: "https://core.tokenman.io"}
	t.Setenv("FLEET_NOTIFY_KF_URL", "https://notify.example.com")
	ts := s.healthTargets()
	for _, k := range []string{"claudefleet", "ccquota", "tokenman", "core", "notify"} {
		if ts[k] == "" {
			t.Fatal(k)
		}
	}
	if ts["core"] != "https://core.tokenman.io/healthz" {
		t.Fatal(ts)
	}
	h := newFleetHarness(t)
	h.srv.SiteHosts = map[string]string{"tokenman.io": SiteEditionSandbox}
	for _, host := range []string{"tokenman.io", "claudefleet.example.com"} {
		r := httptest.NewRequest("GET", "https://"+host+HealthPath, nil)
		w := httptest.NewRecorder()
		h.srv.handleHealth(w, r)
		want := `"language":"zh"`
		if host == "tokenman.io" {
			want = `"language":"en"`
		}
		if !strings.Contains(w.Body.String(), want) {
			t.Fatal(w.Body.String())
		}
	}
}

func TestHealthReleaseReadsCurrentManifest(t *testing.T) {
	h := newFleetHarness(t)
	dir := t.TempDir()
	sha := strings.Repeat("a", 40)
	build := "b1-aaaaaaaaaaaa"
	must(t, os.MkdirAll(filepath.Join(dir, sha, build), 0700))
	must(t, os.WriteFile(filepath.Join(dir, "stable"), []byte(`{"sha":"`+sha+`","seq":1}`), 0600))
	must(t, os.WriteFile(filepath.Join(dir, sha, "current"), []byte(build), 0600))
	manifest := filepath.Join(dir, sha, build, release.ManifestName)
	must(t, os.WriteFile(manifest, []byte(`{}`), 0600))
	h.srv.Releases = &ReleaseStore{Dir: dir}
	now := time.Now().Truncate(time.Minute)
	h.srv.probeHealth(context.Background(), now)
	ps, e := h.srv.Store.HealthProbes(now.Add(-time.Second))
	if e != nil {
		t.Fatal(e)
	}
	for _, p := range ps {
		if p.Component == "releases" && p.State != "ok" {
			t.Fatal(p)
		}
	}
	must(t, os.Remove(manifest))
	h.srv.probeHealth(context.Background(), now.Add(time.Minute))
	ps, _ = h.srv.Store.HealthProbes(now.Add(time.Minute))
	for _, p := range ps {
		if p.Component == "releases" && p.State != "failed" {
			t.Fatal(p)
		}
	}
}

func TestHealthTrialIsAlsoSignedIn(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	c := trialSession(t, h, "p:00000000-0000-4000-8000-000000004060")
	r, _ := http.NewRequest("GET", h.http.URL+HealthPath, nil)
	r.AddCookie(c)
	resp, e := noFollow.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	var out map[string]any
	if e = json.NewDecoder(resp.Body).Decode(&out); e != nil {
		t.Fatal(e)
	}
	if resp.StatusCode != 200 || out["admin"] != nil {
		t.Fatalf("trial: %d %v", resp.StatusCode, out)
	}
	if !trialRoute(AppPrefix + "/health") {
		t.Fatal("health page is not available to trial members")
	}
}
