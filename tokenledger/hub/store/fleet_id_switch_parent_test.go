package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// A session opened after the switch — its record accepted and never claimed,
// Claude or Codex — may dispatch independent Tasks without creating Parent links.
func TestUnclaimedSessionDispatchesIndependentTasks(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	mk := func(token, agent, repo, parent, session string) (store.FleetTask, error) {
		return st.CreateFleetTask(store.FleetTask{Owner: "alice", Title: token, Repo: repo, AuthorityVersion: store.TaskAuthorityVersion,
			RequestedAgent: agent, ResolvedAgent: agent, ParentTask: parent, ParentSession: session,
			RequestPayload: `{"body":"` + token + `"}`}, "tok:"+token, now)
	}
	for _, agent := range []string{"claude", "codex"} {
		parent, err := mk("parent-"+agent, agent, "", "", "")
		if err != nil {
			t.Fatal(err)
		}
		session := migFleet + "/" + fid364
		for _, repo := range []string{"", "o/r"} {
			child, err := mk("child-"+agent+"-"+repo, "claude", repo, parent.Ref, session)
			if err != nil {
				t.Fatalf("%s %q: %v", agent, repo, err)
			}
			if child.ParentTask != "" || child.ParentSession != "" || child.ParentGeneration != 0 {
				t.Fatalf("%s %q: parent link: %+v", agent, repo, child)
			}
			kids, err := st.FleetTaskChildren("alice", parent.Ref)
			if err != nil || len(kids) != 0 {
				t.Fatalf("%s %q: children %d %v", agent, repo, len(kids), err)
			}
		}
		if _, err := st.CreateFleetTask(store.FleetTask{Owner: "bob", Title: "x", AuthorityVersion: store.TaskAuthorityVersion,
			RequestedAgent: "claude", ResolvedAgent: "claude", ParentTask: parent.Ref, ParentSession: session}, "tok:parent-"+agent, now); !errors.Is(err, store.ErrTaskFence) {
			t.Fatalf("%s: another owner's task token: %v", agent, err)
		}
	}
}
