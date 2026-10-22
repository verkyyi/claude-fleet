package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestHistoryHideLegacyPendingBindings(t *testing.T) {
	s := historyCacheServer(t)
	// Realistic legacy backlog: 20 unfinished tasks predate task FIDs. Neither
	// absent task_id nor absent task reference on a candidate binds these rows.
	for i := 0; i < 20; i++ {
		task, err := s.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "retained requirement", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, fmt.Sprint(i), time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if _, err = s.Store.DB().Exec(`UPDATE fleet_tasks SET fid='',state='blocked',asked='retained input' WHERE id=?`, task.ID); err != nil {
			t.Fatal(err)
		}
	}
	for i := 1; i <= 61; i++ {
		m := historyCacheRecord(t, s, pAlice, i, "")
		if err := s.Store.HideHistory(m, "admin", false, true, time.Now(), s.historyMirrorSession); err != nil {
			t.Fatal(err)
		}
	}
	hidden, err := s.Store.HiddenHistory(pAlice, s.historyMirrorSession)
	if err != nil || len(hidden) != 61 {
		t.Fatalf("hidden=%d err=%v", len(hidden), err)
	}
	var retained int
	if err := s.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_tasks WHERE owner=? AND fid='' AND state='blocked' AND asked='retained input' AND title='retained requirement'`, pAlice).Scan(&retained); err != nil || retained != 20 {
		t.Fatalf("backlog changed: %d %v", retained, err)
	}
	for _, binding := range []string{"fid", "task_id", "task", "numeric_task", "worker_id"} {
		t.Run(binding, func(t *testing.T) {
			ss := historyCacheServer(t)
			m := historyCacheRecord(t, ss, pAlice, 100, "")
			task, err := ss.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "private pending requirement", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "bound", time.Now())
			if err != nil {
				t.Fatal(err)
			}
			switch binding {
			case "fid":
				_, err = ss.Store.DB().Exec(`UPDATE fleet_tasks SET fid=? WHERE id=?`, m.ID, task.ID)
			case "task_id":
				_, err = ss.Store.DB().Exec(`UPDATE fleet_ids SET task_id=? WHERE id=?`, task.FID, m.ID)
			case "task", "numeric_task":
				ref := fmt.Sprint(task.ID)
				if binding == "task" {
					ref = "T" + ref
				}
				_, err = ss.Store.DB().Exec(`UPDATE fleet_ids SET task=? WHERE id=?`, ref, m.ID)
			case "worker_id":
				_, err = ss.Store.DB().Exec(`UPDATE fleet_tasks SET worker_id=? WHERE id=?`, "fleet/"+m.ID, task.ID)
			}
			if err != nil {
				t.Fatal(err)
			}
			err = ss.Store.HideHistory(m, "admin", false, true, time.Now(), ss.historyMirrorSession)
			var refusal *store.HistoryHideError
			if !errors.As(err, &refusal) || refusal.Reason != "pending_task" || !errors.Is(err, store.ErrHistoryEvidence) {
				t.Fatalf("pending %s: %v", binding, err)
			}
			if strings.Contains(err.Error(), "private") {
				t.Fatal("refusal leaked content")
			}
		})
	}
}

type historyHideRoundTrip func(*http.Request) (*http.Response, error)

func (f historyHideRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Exercise the real reverse proxy and complete auth middleware on both replicas
// via an in-process transport: no agent start and no localhost networking needed.
func TestHistoryHideReplicaForwarding(t *testing.T) {
	a := historyCacheServer(t)
	b := &Server{Store: a.Store, Vault: a.Vault}
	for _, s := range []*Server{a, b} {
		s.Fleet = true
		s.ViewerToken = viewerToken
		s.Admins = []string{pAlice}
		enablePeople(t, &harness{srv: s}, pAlice, pBob)
	}
	a.Replica = &Replica{Name: "a", Token: replicaTestToken}
	b.Replica = &Replica{Name: "b", Token: replicaTestToken}
	st := a.Store
	for _, err := range []error{st.Enroll("node", "test", "test-node-hash"), st.EnsureFleetNodeConns(), st.EnsureFleetReplicas(), st.NodeConnected("node", "test", "test", "test", control.Proto, 1000, time.Now()), st.BeatReplica(store.ReplicaRow{Name: "b", URL: "http://replica-b", StartedAt: time.Now(), SeenAt: time.Now()}), st.ClaimNodeConn(store.NodeConn{EndpointID: "node", Replica: "b", URL: "http://replica-b", Epoch: "test", Caps: []string{control.CapChat}, ConnectedAt: time.Now()})} {
		if err != nil {
			t.Fatal(err)
		}
	}
	n := &nodeConn{canChat: true}
	n.host.Store("test")
	n.osUser.Store("test")
	n.proto.Store(control.Proto)
	b.nodes.put("node", n)
	m := historyCacheRecord(t, a, pAlice, 1, "")
	raw, _ := json.Marshal(map[string]any{"manifest": m, "apply": false, "undo": false})
	// Include intentional whitespace: forwarding must preserve the original body.
	raw = append([]byte(" \n"), raw...)
	bHandler := b.Handler()
	hops := 0
	a.Replica.Client = &http.Client{Transport: historyHideRoundTrip(func(r *http.Request) (*http.Response, error) {
		hops++
		body, err := io.ReadAll(r.Body)
		if err != nil {
			return nil, err
		}
		if !bytes.Equal(body, raw) || r.Header.Get("X-Fleet-History-Review") != "1" || (r.Header.Get("Cookie") == "" && r.Header.Get("Authorization") == "") || r.Header.Get(replicaTokenHeader) != replicaTestToken {
			t.Error("lost reviewed body/header/auth/hop token")
		}
		// A fresh request discards A's authenticated context: B must authenticate.
		req := httptest.NewRequest(r.Method, r.URL.String(), bytes.NewReader(body))
		req.Header = r.Header.Clone()
		rr := httptest.NewRecorder()
		bHandler.ServeHTTP(rr, req)
		return rr.Result(), nil
	})}
	aHandler := a.Handler()
	call := func(person, query, hop string) (int, string) {
		req := httptest.NewRequest("POST", "/v1/fleet/history-hide"+query, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Fleet-History-Review", "1")
		if person == "shared-token" {
			req.Header.Set("Authorization", "Bearer "+viewerToken)
		} else if person != "" {
			req.AddCookie(personCookie(person, "test"))
		}
		if hop != "" {
			req.Header.Set(replicaTokenHeader, hop)
		}
		rr := httptest.NewRecorder()
		aHandler.ServeHTTP(rr, req)
		return rr.Code, rr.Body.String()
	}
	if code, body := call(pAlice, "", ""); code != 200 || !strings.Contains(body, `"applied":false`) || hops != 1 {
		t.Fatalf("peer dry-run: %d %s hops=%d", code, body, hops)
	}
	// The documented CLI uses the shared operator bearer. It is authorized
	// by both replicas' full middleware and audited as a role, never a human.
	if code, body := call("shared-token", "", ""); code != 200 || !strings.Contains(body, `"applied":false`) {
		t.Fatalf("bearer dry-run: %d %s", code, body)
	}
	var audits int
	if err := st.DB().QueryRow(`SELECT COUNT(*) FROM fleet_history_hide_audit`).Scan(&audits); err != nil || audits != 0 {
		t.Fatalf("dry-run wrote audit: %d %v", audits, err)
	}
	for _, actor := range []string{"shared-token", pAlice} {
		wantActor := actor
		if actor == "shared-token" {
			wantActor = "operator"
		}
		raw, _ = json.Marshal(map[string]any{"manifest": m, "apply": true})
		before := hops
		if code, body := call(actor, "", ""); code != 200 || !strings.Contains(body, `"applied":true`) || hops != before+1 {
			t.Fatalf("%s peer apply: %d %s", actor, code, body)
		}
		hidden, err := st.HiddenHistory(pAlice, a.historyMirrorSession)
		if err != nil || !hidden[m.ID] {
			t.Fatalf("apply did not hide: %v", err)
		}
		// Undo needs only identity and is available even without a live link.
		raw, _ = json.Marshal(map[string]any{"manifest": map[string]string{"owner": m.Owner, "id": m.ID}, "apply": true, "undo": true})
		if code, body := call(actor, "", ""); code != 200 || !strings.Contains(body, `"undo":true`) {
			t.Fatalf("%s undo: %d %s", actor, code, body)
		}
		hidden, err = st.HiddenHistory(pAlice, a.historyMirrorSession)
		if err != nil || hidden[m.ID] {
			t.Fatalf("undo did not restore: %v", err)
		}
		for _, action := range []string{"hide", "undo"} {
			var got int
			if err := st.DB().QueryRow(`SELECT COUNT(*) FROM fleet_history_hide_audit WHERE owner=? AND fid=? AND actor=? AND action=?`, m.Owner, m.ID, wantActor, action).Scan(&got); err != nil || got != 1 {
				t.Fatalf("%s audit actor=%s: %d %v", action, wantActor, got, err)
			}
		}
	}
	// Receiving replica still runs exact ledger checks, not just connectivity.
	bad := m
	bad.Seq++
	raw, _ = json.Marshal(map[string]any{"manifest": bad})
	if code, body := call(pAlice, "", ""); code != 409 || !strings.Contains(body, `"reason":"ledger_mismatch"`) {
		t.Fatalf("peer ledger recheck: %d %s", code, body)
	}
	raw, _ = json.Marshal(map[string]any{"manifest": m})
	before := hops
	for _, person := range []string{pBob, ""} {
		if code, _ := call(person, "", ""); code == 200 || hops != before {
			t.Fatal("nonadmin forwarded")
		}
	}
	for _, actor := range []string{pAlice, "shared-token"} {
		if code, _ := call(actor, "?as="+pBob, ""); code != 403 || hops != before {
			t.Fatal("view-as forwarded")
		}
	}
	if code, body := call(pAlice, "", replicaTestToken); code != 409 || !strings.Contains(body, `"reason":"offline_unknown"`) || hops != before {
		t.Fatalf("loop guard: %d %s", code, body)
	}
	// Even a fresh peer registry row cannot substitute for its actual connection.
	b.nodes.mu.Lock()
	delete(b.nodes.conns, "node")
	b.nodes.mu.Unlock()
	if code, body := call(pAlice, "", ""); code != 409 || !strings.Contains(body, `"reason":"offline_unknown"`) {
		t.Fatalf("disconnected peer: %d %s", code, body)
	}
	n.canChat = false
	b.nodes.put("node", n)
	if code, body := call(pAlice, "", ""); code != 409 || !strings.Contains(body, `"reason":"old_agent"`) {
		t.Fatalf("old agent: %d %s", code, body)
	}
	hidden, err := st.HiddenHistory(pAlice, a.historyMirrorSession)
	if err != nil || len(hidden) != 0 {
		t.Fatalf("dry-run changed visibility: %v", err)
	}
}

func TestHistoryHideRefusalReasons(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Server, *store.HistoryHideManifest)
	}{
		{"invalid_identity", func(s *Server, m *store.HistoryHideManifest) { m.ID = "bad" }},
		{"identity_not_found", func(s *Server, m *store.HistoryHideManifest) { m.Owner = "another-owner" }},
		{"ledger_mismatch", func(s *Server, m *store.HistoryHideManifest) { m.Seq++ }},
		{"evidence_incomplete", func(s *Server, m *store.HistoryHideManifest) { m.Backups = "unknown" }},
		{"evidence_stale", func(s *Server, m *store.HistoryHideManifest) { m.CheckedAt -= 301 }},
		{"natives_mismatch", func(s *Server, m *store.HistoryHideManifest) { m.Natives = []string{"wrong-secret"} }},
		{"native_cache_present", func(s *Server, m *store.HistoryHideManifest) {
			historyCachePut(t, s, m.Owner, "old/key", "private-native", time.Now())
		}},
		{"cache_identity_unknown", func(s *Server, m *store.HistoryHideManifest) {
			historyCachePut(t, s, m.Owner, "old/key", "unknown-private-native", time.Now())
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := historyCacheServer(t)
			m := historyCacheRecord(t, s, pAlice, 1, "private-native")
			tc.change(s, &m)
			err := s.Store.HideHistory(m, "admin", false, false, time.Now(), s.historyMirrorSession)
			var refusal *store.HistoryHideError
			if !errors.As(err, &refusal) || refusal.Reason != tc.name || !errors.Is(err, store.ErrHistoryEvidence) {
				t.Fatalf("reason: %v", err)
			}
			if err.Error() != "history hide refused: "+tc.name {
				t.Fatalf("unexpected disclosure: %v", err)
			}
		})
	}
}
