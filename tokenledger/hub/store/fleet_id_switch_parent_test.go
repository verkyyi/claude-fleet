package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// With the switch on (EPIC T497 C16) a session opened after it — its record
// accepted and never claimed, Claude or Codex — still dispatches children: the
// parent is its ID (parent_session), the record only named. Off, an unclaimed
// parent is fenced as before.
func TestIDSwitchUnclaimedParentDispatches(t *testing.T) {
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
		if _, err := mk("off-"+agent, "claude", "", parent.Ref, session); !errors.Is(err, store.ErrTaskFence) {
			t.Fatalf("%s: switch off, unclaimed parent: %v", agent, err)
		}
		if err := st.SetIDSwitch(true, now); err != nil {
			t.Fatal(err)
		}
		for i, repo := range []string{"", "o/r"} {
			child, err := mk("child-"+agent+"-"+repo, "claude", repo, parent.Ref, session)
			if err != nil {
				t.Fatalf("%s %q: switch on: %v", agent, repo, err)
			}
			if child.ParentTask != parent.Ref || child.ParentSession != session || child.ParentGeneration != parent.Generation {
				t.Fatalf("%s %q: parent link: %+v", agent, repo, child)
			}
			kids, err := st.FleetTaskChildren("alice", parent.Ref, session, parent.Generation)
			if err != nil || len(kids) != i+1 {
				t.Fatalf("%s %q: children %d %v", agent, repo, len(kids), err)
			}
		}
		if _, err := st.CreateFleetTask(store.FleetTask{Owner: "bob", Title: "x", AuthorityVersion: store.TaskAuthorityVersion,
			RequestedAgent: "claude", ResolvedAgent: "claude", ParentTask: parent.Ref, ParentSession: session}, "tok:bob-"+agent, now); !errors.Is(err, store.ErrTaskFence) {
			t.Fatalf("%s: another owner's parent: %v", agent, err)
		}
		if err := st.SetIDSwitch(false, now); err != nil {
			t.Fatal(err)
		}
	}
}
