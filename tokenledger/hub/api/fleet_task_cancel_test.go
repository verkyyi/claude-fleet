package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Real viewer cookies and the complete middleware/router chain, using HTTP
// recorders so node disconnection and local TCP policy cannot affect cancel.
func TestFleetTaskCancelOwnerAndOffline(t *testing.T) {
	s := &Server{Store: openTestStore(t), LiveStore: NewLive(), ViewerToken: viewerToken, Fleet: true}
	if err := s.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	enablePeople(t, &harness{srv: s}, pAlice, pBob, pCarol)
	if err := s.Store.UpsertHubUser(store.HubUser{GitHubID: 1003, Login: "admin", Role: store.RoleAdmin}); err != nil {
		t.Fatal(err)
	}
	h := s.Handler()
	create := func(token string) store.FleetTask {
		t.Helper()
		rec, err := s.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: token, AuthorityVersion: 1,
			RequestedAgent: "codex", ResolvedAgent: "codex"}, token, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		return rec
	}
	call := func(handler http.Handler, task store.FleetTask, cookie *http.Cookie, as, method, body string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, "http://fleet.test"+FleetTasksPath+"/"+task.Ref+"/cancel", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Accept", "application/json")
		r.Header.Set("Origin", "http://fleet.test")
		if cookie != nil {
			r.AddCookie(cookie)
		}
		if as != "" {
			r.Header.Set(ViewAsHeader, as)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, r)
		return out
	}
	owner, other, admin := personCookie(pAlice, "alice"), personCookie(pBob, "bob"), personCookie(pCarol, "admin")
	pending := create("pending")
	for _, test := range []struct {
		name   string
		cookie *http.Cookie
		as     string
		want   int
	}{
		{"anonymous", nil, "", http.StatusUnauthorized},
		{"other-owner", other, "", http.StatusNotFound},
		{"admin-as-owner", admin, pAlice, http.StatusForbidden},
		{"admin-as-other", admin, pBob, http.StatusForbidden},
	} {
		r := call(h, pending, test.cookie, test.as, http.MethodPost, "{}")
		if r.Code != test.want {
			t.Fatalf("%s: %d %s", test.name, r.Code, r.Body.String())
		}
	}
	ro := &http.Cookie{Name: authz.CookieName, Value: authz.SignReadOnly(store.IdentityGitHub, pAlice, "alice", roleUser, s.sessionKey(), time.Now(), time.Hour)}
	if r := call(h, pending, ro, "", http.MethodPost, "{}"); r.Code != http.StatusForbidden {
		t.Fatalf("read-only console: %d %s", r.Code, r.Body.String())
	}
	s.ReadOnly = true
	if r := call(s.Handler(), pending, owner, "", http.MethodPost, "{}"); r.Code != http.StatusServiceUnavailable || r.Header().Get("Retry-After") == "" {
		t.Fatalf("hub read-only: %d %s", r.Code, r.Body.String())
	}
	s.ReadOnly = false
	for _, body := range []string{"null", `{"force":true}`, "{} {}", ""} {
		if r := call(h, pending, owner, "", http.MethodPost, body); r.Code != http.StatusBadRequest {
			t.Fatalf("body %q: %d %s", body, r.Code, r.Body.String())
		}
	}
	if r := call(h, pending, owner, "", http.MethodGet, ""); r.Code != http.StatusMethodNotAllowed {
		t.Fatalf("cancel GET: %d", r.Code)
	}
	before, _ := s.Store.FleetTask(pending.ID)
	if before.Generation != pending.Generation || before.CancelRequest != "" {
		t.Fatal("refused callers changed the record")
	}
	// No node, connection, fleet or inventory has been created in this test.
	var first store.FleetTask
	for i := 0; i < 2; i++ {
		r := call(h, pending, owner, "", http.MethodPost, "{}")
		var got store.FleetTask
		if r.Code != http.StatusOK || json.Unmarshal(r.Body.Bytes(), &got) != nil || got.CancelRequest == "" || got.Generation != pending.Generation+1 {
			t.Fatalf("offline cancel/replay: %d %s", r.Code, r.Body.String())
		}
		if i == 0 {
			first = got
		} else if got.CancelRequest != first.CancelRequest || got.AttemptID != first.AttemptID {
			t.Fatal("repeat cancellation changed its identity")
		}
	}
	opened := create("opened")
	if _, err := s.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: pAlice, EndpointID: "disconnected-node", Machine: "fixture", Login: "alice", ID: opened.FID,
		Events: []map[string]any{{"ev": "opened", "id": opened.FID, "task": opened.Ref, "agent": "codex", "seq": 1.0, "ts": float64(time.Now().Unix())}}}); err != nil {
		t.Fatal(err)
	}
	if r := call(h, opened, owner, "", http.MethodPost, "{}"); r.Code != http.StatusConflict || !strings.Contains(r.Body.String(), "TASK_ALREADY_STARTED") {
		t.Fatalf("opened session: %d %s", r.Code, r.Body.String())
	}
	if got, _ := s.Store.FleetTask(opened.ID); got.CancelRequest != "" {
		t.Fatal("pending-start cancel altered an opened session")
	}
}
