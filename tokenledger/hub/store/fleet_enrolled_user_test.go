package store

import (
	"errors"
	"testing"
	"time"
)

// Task MPCX: endpoints.enrolled_user is the login an endpoint enrolled as —
// written once at the join, never moved by a report; an endpoint enrolled
// before the column existed is stamped from its join's login, else its
// current os_user; a code minted for one opened login enrolls that login only.
func TestEnrolledUserWrittenOnceAndBackfilled(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	if err := s.CreateJoinCodeFor("c1", "", NodeKindFixed, "", "", "", now, time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemJoinCode("c1", now, "ep_a", "a", "h1", "mac-a", "alice"); err != nil {
		t.Fatal(err)
	}
	enrolled := func(id string) string {
		t.Helper()
		et, err := s.EndpointTrustOf(id)
		if err != nil {
			t.Fatal(err)
		}
		return et.EnrolledUser
	}
	if got := enrolled("ep_a"); got != "alice" {
		t.Fatalf("at the join: %q; want alice", got)
	}
	// A report (usage push, heartbeat) naming another login moves nothing.
	if err := s.NodeConnected("ep_a", "mac-a", "alice", "t", 1, 5000, now); err != nil {
		t.Fatal(err)
	}
	if err := s.NodeHeartbeat("ep_a", "mac-b", "bob", "", 1, "{}", now); err != nil {
		t.Fatal(err)
	}
	if got := enrolled("ep_a"); got != "alice" {
		t.Fatalf("after a heartbeat saying bob: %q; want alice", got)
	}

	// A row from before the column: the join's login wins over the report
	// that overwrote os_user since; a row with no join takes its os_user.
	if err := s.Enroll("ep_old", "old", "h2"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`UPDATE endpoints SET enrolled_user = '', os_user = 'root-or-not' WHERE endpoint_id = 'ep_a'`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`UPDATE endpoints SET enrolled_user = '', os_user = 'frank' WHERE endpoint_id = 'ep_old'`); err != nil {
		t.Fatal(err)
	}
	if err := backfillEnrolledUser(s.write); err != nil {
		t.Fatal(err)
	}
	if got := enrolled("ep_a"); got != "alice" {
		t.Fatalf("backfilled from the join: %q; want alice", got)
	}
	if got := enrolled("ep_old"); got != "frank" {
		t.Fatalf("backfilled from os_user: %q; want frank", got)
	}

	// An opened login's code: its own login only, and a refusal spends nothing.
	if err := s.CreateJoinCodeFor("c2", "mac-a-carol", NodeKindFixed, "", NodeRoleManaged, "mac-a", now, time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemJoinCode("c2", now, "ep_c", "x", "h3", "mac-a", "root"); !errors.Is(err, ErrJoinLogin) {
		t.Fatalf("redeemed as root: %v; want ErrJoinLogin", err)
	}
	if err := s.RedeemJoinCode("c2", now, "ep_c", "x", "h3", "mac-a", "carol"); err != nil {
		t.Fatalf("redeemed as carol: %v", err)
	}
	if got := enrolled("ep_c"); got != "carol" {
		t.Fatalf("carol's code: %q", got)
	}
}

// The boot backfill never stamps root or the admin role account onto an
// endpoint a device enrolled or was linked to (task MPCX): it stays
// unstamped, as a first report would leave it.
func TestEnrolledUserBackfillSkipsDeviceHeldLogins(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	if err := s.CreateJoinCodeForDevice("dc", "SHA256:dev", now, time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemJoinCode("dc", now, "ep_dev", "dev", "hd", "bob-box", "bob"); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep_ops", "ops", "ho"); err != nil {
		t.Fatal(err)
	}
	for id, login := range map[string]string{"ep_dev": "root", "ep_ops": "root"} {
		if _, err := s.write.Exec(`UPDATE endpoints SET enrolled_user = '', os_user = ? WHERE endpoint_id = ?`, login, id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.write.Exec(`UPDATE fleet_join_codes SET joined_user = '_fleetadmin' WHERE endpoint_id = 'ep_dev'`); err != nil {
		t.Fatal(err)
	}
	if err := backfillEnrolledUser(s.write); err != nil {
		t.Fatal(err)
	}
	if et, _ := s.EndpointTrustOf("ep_dev"); et.EnrolledUser != "" {
		t.Errorf("a device endpoint backfilled as %q; want unstamped", et.EnrolledUser)
	}
	if et, _ := s.EndpointTrustOf("ep_ops"); et.EnrolledUser != "root" {
		t.Errorf("an operator's endpoint backfilled as %q; want root, as before", et.EnrolledUser)
	}
}
