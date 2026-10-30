package api

import (
	"net/http"
	"net/url"
	"testing"
	"time"
)

func TestPreviewSlowLogin(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	p := setupPreview(t, h.srv)
	first := previewRequest(h.srv, "GET", h.srv.previewURL(p.ID)+"/")
	state := cookieNamed(first.Result(), previewStateCookie)
	if state == nil || state.MaxAge != 600 {
		t.Fatalf("login cookie: %v", state)
	}
	// Advance the pending flow's age, without sleeping or extending its expiry.
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_preview_auth SET expires=expires-180`); err != nil {
		t.Fatal(err)
	}
	issued := previewRequest(h.srv, "GET", first.Header().Get("Location"), personCookie(pAlice, "alice"))
	if issued.Code != 302 {
		t.Fatal(issued.Code, issued.Body.String())
	}
	done := previewRequest(h.srv, "GET", issued.Header().Get("Location"), state)
	if done.Code != 303 || cookieNamed(done.Result(), previewCookie) == nil {
		t.Fatal(done.Code, done.Body.String())
	}
}

func TestPreviewExpiredLoginRestarts(t *testing.T) {
	for _, kind := range []string{"expired", "spent", "removed"} {
		t.Run(kind, func(t *testing.T) {
			h := newFleetHarness(t)
			enablePeople(t, h, pAlice, pBob)
			p := setupPreview(t, h.srv)
			base := h.srv.previewURL(p.ID)
			first := previewRequest(h.srv, "GET", base+"/")
			auth := first.Header().Get("Location")
			owner := personCookie(pAlice, "alice")
			switch kind {
			case "expired":
				if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_preview_auth SET expires=?`, time.Now().Add(-time.Second).Unix()); err != nil {
					t.Fatal(err)
				}
			case "removed":
				if _, err := h.srv.Store.DB().Exec(`DELETE FROM fleet_preview_auth`); err != nil {
					t.Fatal(err)
				}
			case "spent":
				if w := previewRequest(h.srv, "GET", auth, owner); w.Code != 302 {
					t.Fatal(w.Code)
				}
			}
			if w := previewRequest(h.srv, "GET", auth, personCookie(pBob, "bob")); w.Code != 404 {
				t.Fatal("wrong owner", w.Code)
			}
			restart := previewRequest(h.srv, "GET", auth, owner)
			if restart.Code != 302 || restart.Header().Get("Location") != base+"/" {
				t.Fatal("restart", restart.Code, restart.Body.String())
			}
			next := previewRequest(h.srv, "GET", restart.Header().Get("Location"))
			issued := previewRequest(h.srv, "GET", next.Header().Get("Location"), owner)
			done := previewRequest(h.srv, "GET", issued.Header().Get("Location"), cookieNamed(next.Result(), previewStateCookie))
			if done.Code != 303 || cookieNamed(done.Result(), previewCookie) == nil {
				t.Fatal("fresh flow", done.Code, done.Body.String())
			}
		})
	}
}

func TestPreviewOtherHubLogin(t *testing.T) {
	for _, signedInHost := range []string{"hub.example.com", "a.example.org", "b.example.org", ""} {
		t.Run("session="+signedInHost, func(t *testing.T) {
			h := newFleetHarness(t)
			enablePeople(t, h, pAlice)
			p := setupPreview(t, h.srv)
			h.srv.PublicHosts = map[string]string{"hub.example.com": "https://hub.example.com", "a.example.org": "https://a.example.org", "b.example.org": "https://b.example.org", "alias.example.org": "https://a.example.org"}
			first := previewRequest(h.srv, "GET", h.srv.previewURL(p.ID)+"/")
			state := cookieNamed(first.Result(), previewStateCookie)
			addr := first.Header().Get("Location")
			for step := 0; step < 5; step++ {
				u, err := url.Parse(addr)
				if err != nil {
					t.Fatal(err)
				}
				if u.Host != "hub.example.com" && u.Host != "a.example.org" && u.Host != "b.example.org" {
					t.Fatal("untrusted or duplicate origin", addr)
				}
				var sess *http.Cookie
				if u.Host == signedInHost {
					sess = personCookie(pAlice, "alice")
				}
				w := previewRequest(h.srv, "GET", addr, sess)
				if w.Code != 302 {
					t.Fatal(w.Code, w.Body.String())
				}
				loc := w.Header().Get("Location")
				if loc == appURL("/signin") {
					if signedInHost != "" {
						t.Fatal("asked to sign in despite existing session on", signedInHost)
					}
					ret := cookieNamed(w.Result(), entryReturnCookie)
					if u.Host != "hub.example.com" || ret == nil || !appReturnOK(ret.Value) {
						t.Fatal("lost login return", w.Header())
					}
					return
				}
				cb, _ := url.Parse(loc)
				if cb.Path == previewCallback {
					done := previewRequest(h.srv, "GET", loc, state)
					c := cookieNamed(done.Result(), previewCookie)
					if done.Code != 303 || c == nil {
						t.Fatal(done.Code, done.Body.String())
					}
					// Reopening with the preview session must not visit any sign-in page.
					again := previewRequest(h.srv, "GET", h.srv.previewURL(p.ID)+"/", c)
					if again.Code != 503 {
						t.Fatal("expected offline app, not reauthentication", again.Code)
					}
					return
				}
				addr = loc
			}
			t.Fatal("authorization redirect loop")
		})
	}
}

func TestPreviewLoginOrigins(t *testing.T) {
	s := &Server{FleetPublicURL: "https://hub.example.com/", PublicHosts: map[string]string{
		"hub.example.com":      "https://hub.example.com/",
		"valid.example.org":    "https://valid.example.org/",
		"alias.example.org":    "https://valid.example.org",
		"plain.example.org":    "http://plain.example.org",
		"user.example.org":     "https://user@user.example.org",
		"path.example.org":     "https://path.example.org/app",
		"query.example.org":    "https://query.example.org?redirect=evil",
		"fragment.example.org": "https://fragment.example.org#evil",
		"unserved.example.org": "https://unknown.example.org",
	}}
	for _, tc := range []struct{ addr, want string }{
		{"https://hub.example.com/preview/authorize?next=https://evil.test", "https://valid.example.org"},
		{"https://valid.example.org/preview/authorize?probe=1", "https://hub.example.com"},
		{"https://hub.example.com/preview/authorize?probe=1", ""},
	} {
		r, err := http.NewRequest("GET", tc.addr, nil)
		if err != nil {
			t.Fatal(err)
		}
		if got := s.previewLoginNext(r); got != tc.want {
			t.Fatalf("%s: got %q want %q", tc.addr, got, tc.want)
		}
	}
}

func TestPreviewPortalLoginReturn(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	p := setupPreview(t, h.srv)
	h.srv.PublicHosts = map[string]string{"portal.example.org": "https://portal.example.org"}
	if err := h.srv.ConfigurePortal("https://portal.example.org", "hub.example.com", ""); err != nil {
		t.Fatal(err)
	}
	first := previewRequest(h.srv, "GET", h.srv.previewURL(p.ID)+"/")
	probe := previewRequest(h.srv, "GET", first.Header().Get("Location"))
	addr := probe.Header().Get("Location")
	u, err := url.Parse(addr)
	if err != nil || u.Host != "portal.example.org" {
		t.Fatal("not on portal", addr, err)
	}
	login := previewRequest(h.srv, "GET", addr)
	ret := cookieNamed(login.Result(), entryReturnCookie)
	if login.Code != 302 || login.Header().Get("Location") != appURL("/signin") || ret == nil || !appReturnOK(ret.Value) {
		t.Fatal("lost portal return", login.Code, login.Header())
	}
	issued := previewRequest(h.srv, "GET", h.srv.PortalURL+ret.Value, personCookie(pAlice, "alice"))
	done := previewRequest(h.srv, "GET", issued.Header().Get("Location"), cookieNamed(first.Result(), previewStateCookie))
	if done.Code != 303 {
		t.Fatal("portal login", done.Code, done.Body.String())
	}
}
