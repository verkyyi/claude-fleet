package store

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// Two openers never get one number (claude-fleet#2677): twenty at once in one
// repo take 1…20, each once; another repo counts from 1 on its own.
func TestTicketNumbersConcurrent(t *testing.T) {
	s := newStore(t)
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	const k = 20
	got := make(chan int64, k)
	var wg sync.WaitGroup
	for i := 0; i < k; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tk, err := s.CreateFleetTicket(FleetTicket{Repo: "Verk/Notes", Owner: "gh:1", Title: "x"}, 0, time.Now())
			if err != nil {
				t.Error(err)
				return
			}
			got <- tk.Number
		}()
	}
	wg.Wait()
	close(got)
	seen := map[int64]bool{}
	for n := range got {
		if seen[n] || n < 1 || n > k {
			t.Fatalf("number %d twice or out of 1…%d", n, k)
		}
		seen[n] = true
	}
	if len(seen) != k {
		t.Fatalf("%d numbers, want %d", len(seen), k)
	}
	other, err := s.CreateFleetTicket(FleetTicket{Repo: "verk/other", Owner: "gh:1", Title: "y"}, 0, time.Now())
	if err != nil || other.Number != 1 || other.ID != "hub:verk/other#1" {
		t.Fatalf("another repo: %+v %v", other, err)
	}
	// an import takes its own number, refuses a taken one, and the repo
	// carries on past the highest
	imp, err := s.CreateFleetTicket(FleetTicket{Repo: "verk/notes", Owner: "gh:1", Title: "z"}, 40, time.Now())
	if err != nil || imp.Number != 40 {
		t.Fatalf("import 40: %+v %v", imp, err)
	}
	if _, err := s.CreateFleetTicket(FleetTicket{Repo: "verk/notes", Owner: "gh:1", Title: "z"}, 40, time.Now()); !errors.Is(err, ErrTicketTaken) {
		t.Fatalf("import 40 again: %v", err)
	}
	if low, err := s.CreateFleetTicket(FleetTicket{Repo: "verk/notes", Owner: "gh:1", Title: "z"}, 30, time.Now()); err != nil || low.Number != 30 {
		t.Fatalf("import 30 below the sequence: %+v %v", low, err)
	}
	if next, err := s.CreateFleetTicket(FleetTicket{Repo: "verk/notes", Owner: "gh:1", Title: "z"}, 0, time.Now()); err != nil || next.Number != 41 {
		t.Fatalf("after the import: %+v %v, want 41", next, err)
	}
}

// The registry's rows (#2676) come over once as gh tickets, and a re-run
// copies nothing twice.
func TestTicketIndexCarriedOver(t *testing.T) {
	s := newStore(t)
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	ts := time.Now().UTC().Format(rfc)
	if _, err := s.write.Exec(`INSERT INTO fleet_ticket_index (id, owner, title, state, backend, url, origin,
		endpoint_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		"gh:Verkyyi/claude-fleet#2700", "gh:1005", "写设计页", "open", "gh",
		"https://github.com/verkyyi/claude-fleet/issues/2700", "orchestrator", "ep_m5", ts, ts); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := s.EnsureNodes(); err != nil {
			t.Fatal(err)
		}
	}
	list, err := s.FleetTickets(TicketFilter{Owner: "gh:1005"})
	if err != nil || len(list) != 1 {
		t.Fatalf("carried over: %+v %v", list, err)
	}
	if g := list[0]; g.ID != "gh:verkyyi/claude-fleet#2700" || g.Backend != TicketGitHub || g.Title != "写设计页" ||
		g.Body != "" || g.Origin != "orchestrator" || len(g.Labels) != 0 {
		t.Fatalf("carried over as %+v", g)
	}
	if none, _ := s.FleetTickets(TicketFilter{}); len(none) != 0 {
		t.Fatalf("no owner and not all lists %d", len(none))
	}
}
