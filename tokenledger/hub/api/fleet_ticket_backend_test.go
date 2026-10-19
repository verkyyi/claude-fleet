package api

import (
	"fmt"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A ticket_ref's backend is checked, not just carried (claude-fleet#4654): a
// hub-ticketed repo refuses gh:…#N, a GitHub-ticketed one refuses hub:…#N —
// refused before any task.
func TestTicketRefBackendChecked(t *testing.T) {
	type try struct {
		ref  string
		want int
	}
	cases := []struct {
		name  string
		setup func(t *testing.T, s *store.Store, owner string)
		tries []try
	}{
		{"hub-ticketed repo (forge none)", func(t *testing.T, s *store.Store, owner string) {
			hubTicket(t, s, owner, 7)
		}, []try{{"gh:" + writeRepo + "#7", 400}, {"hub:" + writeRepo + "#8", 400}, {"gh:" + writeRepo + "#8", 400}, {"hub:" + writeRepo + "#7", 200}}},
		{"GitHub-ticketed repo", func(*testing.T, *store.Store, string) {}, []try{{"hub:" + writeRepo + "#7", 400}, {"gh:" + writeRepo + "#7", 200}}},
		// An old per-repo authority row (claude-fleet#4885's ticket home) takes
		// no part any more (claude-fleet#4896): only the ticket rows decide.
		{"old repo authority row ignored", func(t *testing.T, s *store.Store, owner string) {
			setOldRepoAuthority(t, s, `{"repo":"`+writeRepo+`","mode":"hub","revision":3,"legacy_tickets":"hub"}`)
		}, []try{{"hub:" + writeRepo + "#7", 400}, {"gh:" + writeRepo + "#7", 200}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, _, target, _, _ := twoNodesCaps(t, control.CapLaunch)
			// A plain start first: it names the caller, whose tickets these are.
			postFleet(t, h, "worker_start", map[string]any{"issue": 99, "repo": writeRepo, "idempotency_key": "who", "coding_agent": "codex"}, 200)
			probe, err := h.srv.Store.FleetTask(store.ParseTaskRef(target.writes[0]["params"].(map[string]any)["task"].(string)))
			if err != nil {
				t.Fatal(err)
			}
			c.setup(t, h.srv.Store, probe.Owner)
			launched := 1
			for i, tr := range c.tries {
				var issue int
				fmt.Sscanf(tr.ref[len(tr.ref)-1:], "%d", &issue)
				args := map[string]any{"issue": issue, "repo": writeRepo, "idempotency_key": fmt.Sprintf("ref-%d", i), "coding_agent": "codex", "ticket_ref": tr.ref}
				postFleet(t, h, "worker_start", args, tr.want)
				if tr.want == 200 {
					launched++
				}
				if target.count() != launched {
					t.Fatalf("%s: launches=%d want %d", tr.ref, target.count(), launched)
				}
			}
			tasks, err := h.srv.Store.FleetTasksFor(probe.Owner, 100)
			if err != nil || len(tasks) != launched {
				t.Fatalf("tasks=%d want %d (%v)", len(tasks), launched, err)
			}
			for _, task := range tasks {
				for _, tr := range c.tries {
					if tr.want != 200 && task.TicketRef == tr.ref {
						t.Fatalf("refused ref %s was written as a task", tr.ref)
					}
				}
			}
		})
	}
}

// Another owner's ticket is FORBIDDEN, never 409 IDEMPOTENCY_CONFLICT; a key
// reused for a different start still is one (claude-fleet#4697).
func TestTicketRefOfAnotherOwnerIsForbidden(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapLaunch)
	hubTicket(t, h.srv.Store, "someone-else", 7)
	args := map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "foreign", "coding_agent": "codex",
		"ticket_ref": "hub:" + writeRepo + "#7"}
	if e := postFleet(t, h, "worker_start", args, 403)["error"].(map[string]any); e["code"] != "FORBIDDEN" {
		t.Fatalf("another owner's ticket: %v; want FORBIDDEN", e)
	}
	if target.count() != 0 {
		t.Fatalf("a fenced start launched (%d)", target.count())
	}
	postFleet(t, h, "worker_start", map[string]any{"issue": 99, "repo": writeRepo, "idempotency_key": "k", "coding_agent": "codex"}, 200)
	if e := postFleet(t, h, "worker_start", map[string]any{"issue": 98, "repo": writeRepo, "idempotency_key": "k", "coding_agent": "codex"}, 409)["error"].(map[string]any); e["code"] != "IDEMPOTENCY_CONFLICT" {
		t.Fatalf("reused key: %v; want IDEMPOTENCY_CONFLICT", e)
	}
}

func setOldRepoAuthority(t *testing.T, s *store.Store, raw string) {
	t.Helper()
	if err := s.SetFleetSetting("task-authority:"+store.NormRepo(writeRepo), raw, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func hubTicket(t *testing.T, s *store.Store, owner string, n int64) {
	t.Helper()
	if _, err := s.CreateFleetTicket(store.FleetTicket{Repo: writeRepo, Owner: owner, Title: "only on the hub"}, n, time.Now()); err != nil {
		t.Fatal(err)
	}
}
