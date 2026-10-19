package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet T490: hub-coordinated tasks are every NEW account's default.
// A person put on the list for the first time (here: an invite) starts on the
// hub; a person already on the list keeps no setting and reads legacy, and so
// does a newcomer with task history of their own.
func TestNewPersonStartsOnHub(t *testing.T) {
	h := inviteHarness(t)
	// on the list before: legacy, never flipped
	if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pBob, Login: "bob", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	inv := h.mintInvite(t, "")
	if cb, _ := h.signInWith(t, ghMallory, inviteCookieOf(inv.Code)); cb.StatusCode != http.StatusFound {
		t.Fatalf("invite sign-in = %d", cb.StatusCode)
	}
	mallory := githubPrincipal(ghMallory.ID)
	if a, err := h.srv.Store.OwnerAuthority(mallory); err != nil || a.Mode != "hub" || a.Revision != 1 || a.Owner != mallory {
		t.Fatalf("the invited newcomer's authority = %+v %v; want hub r1", a, err)
	}
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'repo_authority' AND actor = ?`, "task-authority:"+mallory).Scan(&n); err != nil || n != 1 {
		t.Fatalf("the seed is not journalled: %d %v", n, err)
	}
	if b, _ := h.srv.Store.OwnerAuthority(pBob); b.Mode != "legacy" || b.Revision != 0 {
		t.Fatalf("a person already on the list moved: %+v", b)
	}
	if set, _ := h.srv.Store.FleetSettings(); set["task-authority:owner:"+pBob] != "" {
		t.Fatal("a setting was written for a person already on the list")
	}

	// Admitted again (an admin's add over an existing row): untouched.
	if err := h.srv.Store.AdmitHubUser(store.HubUser{PrincipalID: pBob, Login: "bob", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	if b, _ := h.srv.Store.OwnerAuthority(pBob); b.Mode != "legacy" || b.Revision != 0 {
		t.Fatalf("re-admitting moved an existing person: %+v", b)
	}

	// Not on the list yet, but with legacy work of their own: left for the
	// migration, never flipped here.
	if _, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "old", WorkerID: "f/old", State: store.TaskOpen}, "alice-v0", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdmitHubUser(store.HubUser{PrincipalID: pAlice, Login: "alice", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	if a, _ := h.srv.Store.OwnerAuthority(pAlice); a.Mode != "legacy" || a.Revision != 0 {
		t.Fatalf("a newcomer with legacy work was flipped: %+v", a)
	}
}

// claude-fleet T490: a new person's first login — no repo hosted yet — hears
// the hub mode on its first beat, its gate read says hub, and their first
// task is the hub's: the accepted record is taken.
func TestNewPersonFirstLoginFollowsHub(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	if err := h.srv.Store.AdmitHubUser(store.HubUser{PrincipalID: pAlice, Login: "alice", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-a", Login: "alice"}); code != 200 {
		t.Fatalf("adopt: %d", code)
	}
	tok := h.enroll(t, "mac-a")
	node := connectWriteNodeCaps(t, h, tok, control.CapRead, control.CapWrite, control.CapLaunch, control.CapRepoAuthority)
	node.beatLoad("mac-a", "alice", machineA, 1, 0)
	waitFor(t, 3*time.Second, "the new login told hub", func() bool {
		p := node.authorityPushes()
		return len(p) == 1 && p[0] == control.RepoAuthority{Repo: "", Mode: "hub", Revision: 1}
	})

	st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, map[string]any{
		"authority_version": 1, "token": "first", "title": "first task", "repo": writeRepo,
		"requested_agent": "claude", "resolved_agent": "claude"})
	if st != 200 || rec["owner"] != pAlice {
		t.Fatalf("the first task = %d %v", st, rec)
	}
	// The node's gate read — what fleet_repo_authority.py --sync writes into
	// the login's fleet.conf — says hub.
	if st, g := nodeTaskCall(t, h, tok, http.MethodGet, FleetAuthorityPath+"?gate=1", nil); st != 200 || g["mode"] != "hub" || g["owner"] != pAlice {
		t.Fatalf("the new login's gate = %d %v", st, g)
	}
}
