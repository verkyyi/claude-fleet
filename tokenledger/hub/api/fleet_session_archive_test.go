package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestSessionArchiveOwnerAndVisibility(t *testing.T) {
	s := &Server{Store: openTestStore(t), LiveStore: NewLive(), ViewerToken: viewerToken, Fleet: true}
	if err := s.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	enablePeople(t, &harness{srv: s}, pAlice, pBob, pCarol)
	if err := s.Store.UpsertHubUser(store.HubUser{GitHubID: 1003, Login: "admin", Role: store.RoleAdmin}); err != nil {
		t.Fatal(err)
	}
	task, err := s.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "Archive me", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "archive", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	s.GitHub.Admins = []string{"admin"}
	if _, err := s.Store.PinLogin("admin", 1003, time.Now()); err != nil {
		t.Fatal(err)
	}
	handler := s.Handler()
	call := func(cookie *http.Cookie, as, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://fleet.test"+path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", "http://fleet.test")
		r.Header.Set("Accept", "application/json")
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
	body := `{"id":"` + task.FID + `","archived":true}`
	owner := personCookie(pAlice, "alice")
	for _, tc := range []struct {
		cookie *http.Cookie
		as     string
		want   int
	}{
		{nil, "", 401}, {personCookie(pBob, "bob"), "", 404}, {personCookie(pCarol, "admin"), pAlice, 403}, {personCookie(pCarol, "admin"), "", 404},
		{&http.Cookie{Name: authz.CookieName, Value: authz.SignReadOnly(store.IdentityGitHub, pAlice, "alice", roleUser, s.sessionKey(), time.Now(), time.Hour)}, "", 403},
	} {
		got := call(tc.cookie, tc.as, "POST", "/v1/fleet/session_archive", body)
		if got.Code != tc.want {
			t.Fatalf("authorization: %d want %d: %s", got.Code, tc.want, got.Body.String())
		}
	}
	if got := call(owner, "", "GET", "/v1/fleet/session_archive", ""); got.Code != 405 {
		t.Fatalf("GET write: %d", got.Code)
	}
	for _, bad := range []string{`{}`, `{"id":"` + task.FID + `","archived":"yes"}`, `{"id":"scratch-1","archived":true}`, `{"id":"` + task.FID + `","archived":true,"owner":"other"}`} {
		if got := call(owner, "", "POST", "/v1/fleet/session_archive", bad); got.Code != 400 {
			t.Fatalf("bad input %s: %d %s", bad, got.Code, got.Body.String())
		}
	}
	before, _ := s.Store.FleetTask(task.ID)
	old, _ := s.buildBoard(pAlice, nil, time.Now())
	revision, _ := s.Store.FleetSessionsRevision()
	for i := 0; i < 2; i++ {
		got := call(owner, "", "POST", "/v1/fleet/session_archive", body)
		if got.Code != 200 {
			t.Fatalf("archive: %d %s", got.Code, got.Body.String())
		}
	}
	after, _ := s.Store.FleetTask(task.ID)
	if !reflect.DeepEqual(before, after) {
		t.Fatal("archiving changed execution/task")
	}
	board, err := s.buildBoard(pAlice, nil, time.Now())
	if err != nil || len(board.Rows) != 1 || !board.Rows[0].Archived || board.Count != 0 || board.Digest == old.Digest {
		t.Fatalf("board archive: %+v %v", board, err)
	}
	next, _ := s.Store.FleetSessionsRevision()
	if next <= revision {
		t.Fatal("replica cache revision unchanged")
	}
	args, _ := json.Marshal(map[string]any{"id": task.FID, "archived": false})
	envelope, _ := json.Marshal(map[string]any{"tool": "session_archive", "args_json": string(args)})
	got := call(owner, "", "POST", "/v1/fleet/write", string(envelope))
	if got.Code != 200 {
		t.Fatalf("unarchive via terminal door: %d %s", got.Code, got.Body.String())
	}
	board, err = s.buildBoard(pAlice, nil, time.Now())
	if err != nil || len(board.Rows) != 1 || board.Rows[0].Archived || board.Count != old.Count {
		t.Fatalf("unarchive: %+v %v", board, err)
	}
}

func TestSessionArchiveLiveAndOldHistory(t *testing.T) {
	s := historyCacheServer(t)
	now := time.Now()
	m := historyCacheRecord(t, s, "alice", 701, "native-history")
	before, err := s.Store.FleetIDOf("alice", m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Store.SetSessionArchived("alice", m.ID, true); err != nil {
		t.Fatal(err)
	}
	wid := "fleet/" + m.ID
	live := []FleetSession{{WorkerID: &wid, Availability: "online", Worker: map[string]any{"identity": m.ID, "state": "working", "key": "scratch-1"}}}
	b, err := s.buildBoard("alice", live, now)
	if err != nil || len(b.Rows) != 1 || !b.Rows[0].Archived || !b.Rows[0].Active || b.Active != 1 || b.Count != 0 {
		t.Fatalf("live archive: %+v %v", b, err)
	}
	b, err = s.buildBoard("alice", nil, now.Add(90*24*time.Hour))
	if err != nil || len(b.Rows) != 1 || !b.Rows[0].Archived || b.Rows[0].History == nil {
		t.Fatalf("old archive: %+v %v", b, err)
	}
	if err := s.Store.SetSessionArchived("alice", m.ID, false); err != nil {
		t.Fatal(err)
	}
	b, err = s.buildBoard("alice", nil, now.Add(90*24*time.Hour))
	if err != nil || len(b.Rows) != 1 || b.Rows[0].Archived {
		t.Fatalf("restoring old history lost the row: %+v %v", b, err)
	}
	after, _ := s.Store.FleetIDOf("alice", m.ID)
	if !reflect.DeepEqual(before, after) {
		t.Fatal("archiving changed native identity/history")
	}
	other := historyCacheRecord(t, s, "alice", 702, "")
	b, err = s.buildBoard("alice", []FleetSession{{Availability: "online", Worker: map[string]any{"identity": other.ID, "state": "idle", "key": "scratch-1"}}}, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range b.Rows {
		if r.ID == other.ID && r.Archived {
			t.Fatal("recycled key inherited archive")
		}
	}
	b, err = s.buildBoard("bob", nil, now)
	if err != nil || len(b.Rows) != 0 {
		t.Fatal("archive leaked across owners")
	}
}
