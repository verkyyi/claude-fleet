package store

import (
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func previewFixture(t *testing.T, s *Store) Preview {
	t.Helper()
	now := time.Now()
	if e := s.EnsureNodes(); e != nil {
		t.Fatal(e)
	}
	p, e := s.EnsurePrincipalAs("gh:1001", "alice", "alice", 32, func(string) bool { return true }, now)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.AdoptAccount(p, "node", now); e != nil {
		t.Fatal(e)
	}
	if e = s.CreateJoinCodeFor("join", "node-alice", NodeKindFixed, "", NodeRoleManaged, "node", now, time.Hour); e != nil {
		t.Fatal(e)
	}
	if e = s.RedeemJoinCode("join", now, "ep", "node-alice", "hash", "node", "alice"); e != nil {
		t.Fatal(e)
	}
	task, e := s.CreateFleetTask(FleetTask{Owner: p.ID, Title: "Preview", Machine: "node", Login: "alice", WorkerID: "worker"}, "task", now)
	if e != nil {
		t.Fatal(e)
	}
	a, e := s.PreviewAuthority("ep")
	if e != nil {
		t.Fatal(e)
	}
	return Preview{ID: "preview", Owner: a.Owner, Endpoint: "ep", Machine: a.Machine, Login: a.Login, Generation: a.Generation, TokenHash: a.TokenHash, TaskID: task.ID, Worker: "worker", Socket: "app.sock", Expires: now.Add(time.Hour).Unix()}
}
func TestPreviewReplicas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "preview.db")
	a, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer a.Close()
	p := previewFixture(t, a)
	b, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer b.Close()
	now := time.Now()
	if e = a.CreatePreview(p, 3, now); e != nil {
		t.Fatal(e)
	}
	if _, e = b.Preview(p.ID, now); e != nil {
		t.Fatal(e)
	}
	if e = a.BeginPreviewAuth("state", p.ID, "callback", now); e != nil {
		t.Fatal(e)
	}
	if e = b.TicketPreview("state", p.ID, "evil", "ticket", PreviewSession{}, now); e == nil {
		t.Fatal("callback changed")
	}
	session := PreviewSession{Owner: p.Owner, SID: "sid", Issued: now.Unix(), Expires: now.Add(time.Hour).Unix()}
	if e = b.TicketPreview("state", p.ID, "callback", "ticket", session, now); e != nil {
		t.Fatal(e)
	}
	if e = a.ExchangePreview("state", "other", "callback", "ticket", "sess", now); e == nil {
		t.Fatal("cross preview exchange")
	}
	var wins atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			st := a
			if i%2 == 0 {
				st = b
			}
			if st.ExchangePreview("state", p.ID, "callback", "ticket", fmt.Sprint(i), now) == nil {
				wins.Add(1)
			}
		}(i)
	}
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("ticket winners %d", wins.Load())
	}
	wins.Store(0)
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			st := a
			if i%2 == 0 {
				st = b
			}
			if st.TakePreviewConnection(fmt.Sprint(i), p, 32, now) == nil {
				wins.Add(1)
			}
		}(i)
	}
	wg.Wait()
	if wins.Load() != 32 {
		t.Fatalf("connection winners %d", wins.Load())
	}
	if e = a.ClosePreview(p.ID, p.Owner); e != nil {
		t.Fatal(e)
	}
	if _, e = b.Preview(p.ID, now); e == nil {
		t.Fatal("replica retained revoked permission")
	}
}
func TestPreviewIdentityAndGeneration(t *testing.T) {
	for _, kind := range []string{"owner", "node", "login", "task", "token", "remove", "adopt", "expiry", "socket-owner"} {
		t.Run(kind, func(t *testing.T) {
			s, e := Open(filepath.Join(t.TempDir(), "db"))
			if e != nil {
				t.Fatal(e)
			}
			defer s.Close()
			p := previewFixture(t, s)
			now := time.Now()
			if kind == "owner" {
				p.Owner = "gh:other"
			}
			if kind == "node" {
				p.Endpoint = "other"
			}
			if kind == "login" {
				p.Login = "root"
			}
			if kind == "task" {
				p.TaskID++
			}
			e = s.CreatePreview(p, 3, now)
			if kind == "owner" || kind == "node" || kind == "login" || kind == "task" {
				if e == nil {
					t.Fatal("forged identity accepted")
				}
				return
			}
			if e != nil {
				t.Fatal(e)
			}
			switch kind {
			case "token":
				s.RotateEndpointToken(p.Endpoint, "newhash", now, 0)
			case "remove":
				s.RequestAccountRemoval(p.Owner, p.Machine, now)
			case "adopt":
				a, _ := s.Principal(p.Owner)
				s.AdoptAccount(a, p.Machine, now.Add(time.Second))
			case "socket-owner":
				s.write.Exec(`UPDATE fleet_join_codes SET joined_user='root' WHERE endpoint_id='ep'`)
			case "expiry":
				now = now.Add(2 * time.Hour)
			}
			if _, e = s.Preview(p.ID, now); e == nil {
				t.Fatal("old authority survived")
			}
		})
	}
}

func TestPreviewAuthExpiry(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p := previewFixture(t, s)
	now := time.Now()
	if err := s.CreatePreview(p, 3, now); err != nil {
		t.Fatal(err)
	}
	session := PreviewSession{Owner: p.Owner, SID: "sid", Issued: now.Unix(), Expires: now.Add(time.Hour).Unix()}
	for _, tc := range []struct {
		age   time.Duration
		valid bool
	}{
		{3*time.Minute + time.Second, true},
		{9 * time.Minute, true},
		{10 * time.Minute, false},
	} {
		state := tc.age.String()
		if err := s.BeginPreviewAuth(state, p.ID, "callback", now); err != nil {
			t.Fatal(err)
		}
		at := now.Add(tc.age)
		err := s.TicketPreview(state, p.ID, "callback", "ticket", session, at)
		if (err == nil) != tc.valid {
			t.Fatalf("at %s: %v", tc.age, err)
		}
		if tc.valid {
			if err := s.ExchangePreview(state, p.ID, "callback", "ticket", state, at); err != nil {
				t.Fatal(err)
			}
			if err := s.ExchangePreview(state, p.ID, "callback", "ticket", state+"replay", at); err == nil {
				t.Fatal("replayed ticket accepted")
			}
		}
	}
}
