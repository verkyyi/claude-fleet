package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The real local Task path records a stable session ID; it need not populate
// the old task.machine/login/worker_id projections (T978).
func TestPreviewRegisteredTask(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	p := setupPreview(t, h.srv)
	now := time.Now()
	token := "preview-registration-node"
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET token_hash=? WHERE endpoint_id=?`, HashToken(token), p.Endpoint); err != nil {
		t.Fatal(err)
	}
	claims := assertClaims("11111111-2222-4333-8444-555555555555", now)
	claims.Node = p.Machine
	if _, err := h.srv.Store.RecordFleetSnapshot(p.Endpoint, p.Machine, p.Login, "preview-machine", []store.FleetReport{{FleetID: claims.FleetUUID, Name: "preview", State: "up"}}, now); err != nil {
		t.Fatal(err)
	}
	task, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: p.Owner, Title: "Real Task", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "preview-real-task", now)
	if err != nil {
		t.Fatal(err)
	}
	claims.Fid = task.FID
	claims.WorkerID = claims.FleetUUID + "/" + task.FID
	_, err = h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: p.Owner, EndpointID: p.Endpoint, Machine: p.Machine, Login: p.Login, ID: task.FID, Events: []map[string]any{
		{"id": task.FID, "ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "task": task.Ref, "agent": "codex", "key": "scratch-978"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", "/v1/node/previews?task="+task.Ref, strings.NewReader(`{"action":"register","socket":"app.sock"}`))
	r.Host = "hub.example.com"
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set(workerAssertHeader, signWorkerAssertion(claims, HashToken(token)))
	w := httptest.NewRecorder()
	h.srv.Handler().ServeHTTP(w, r)
	if w.Code != 201 {
		t.Fatalf("real Task registration: %d %s", w.Code, w.Body.String())
	}
	claims.Fid = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
	claims.WorkerID = claims.FleetUUID + "/" + claims.Fid
	r = httptest.NewRequest("GET", "/v1/node/previews?task="+task.Ref, nil)
	r.Host = "hub.example.com"
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set(workerAssertHeader, signWorkerAssertion(claims, HashToken(token)))
	w = httptest.NewRecorder()
	h.srv.Handler().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("another session listed Task previews", w.Code)
	}
}

func TestPreviewEnrollmentBindingRoute(t *testing.T) {
	h, admin, user := rolesHarness(t)
	p := setupPreview(t, h.srv)
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_join_codes SET role='',machine='',label='legacy-rejoin' WHERE endpoint_id=?`, p.Endpoint); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(FleetAccountRequest{Action: "preview-bind", PrincipalID: p.Owner, Hostname: p.Machine, Login: p.Login, EndpointID: p.Endpoint})
	for _, tc := range []struct {
		name   string
		cookie *http.Cookie
		origin string
		want   int
	}{
		{"anonymous", nil, "", 401},
		{"owner cannot self-approve", user, "https://hub.example.com", 403},
		{"admin cross-site", admin, "https://evil.test", 403},
		{"admin approval", admin, "https://hub.example.com", 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/v1/fleet/accounts", strings.NewReader(string(body)))
			r.Host = "hub.example.com"
			if tc.cookie != nil {
				r.AddCookie(tc.cookie)
			}
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			w := httptest.NewRecorder()
			h.srv.Handler().ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("%d %s", w.Code, w.Body.String())
			}
			_, err := h.srv.Store.PreviewAuthority(p.Endpoint)
			if (err == nil) != (tc.want == 200) {
				t.Fatal("unexpected binding", err)
			}
		})
	}
}
