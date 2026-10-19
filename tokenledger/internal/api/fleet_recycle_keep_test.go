package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#4195 (#4194 A): a recycle no longer re-joins. Where the wash
// keeps the login's root-held node token (CapRecycleKeep), the hub leaves that
// node enrolled and changes only who the login belongs to (the spare), while
// everything the last person held goes — the passes that node issued, leases,
// the link, 家, and — kept or not — every live SSH certificate of theirs
// naming the login, on the revocation list at once (BREAK-IT recycle-rejoins,
// recycle-old-cert).

// plantCredentials gives person a live session pass from node and an SSH
// certificate naming login.
func plantCredentials(t *testing.T, h *harness, person, login string, node *fleetNode) {
	t.Helper()
	now := time.Now()
	if err := h.srv.Store.AddSessionCred(store.SessionCred{ID: "pass-" + login, PrincipalID: person, WorkerID: "w-" + login,
		Machine: "m8", OSUser: login, EndpointID: node.id, Providers: []string{"claude"},
		IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.RecordCert(store.FleetCert{Serial: "4195" + login, PrincipalID: person, KeyID: "k-" + login,
		Principals: []string{"other", login}, KeyFingerprint: "SHA256:x", Via: "device",
		IssuedAt: now.Add(-time.Minute), ValidAfter: now.Add(-time.Minute), ValidBefore: now.Add(12 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
}

func revocationJTIs(t *testing.T, h *harness) map[string]bool {
	t.Helper()
	_, list, err := h.srv.Store.RevocationList(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, r := range list {
		out[r.JTI] = true
		if r.JTI == "" {
			out["scope:"+r.Machine+"|"+r.Principal] = true
		}
	}
	return out
}

func TestRecycleKeepsRootHeldNode(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.RevocationsToken = "rev-4195"
	admin := recycleFleet(t, h, control.CapCredsep, control.CapRecycle, control.CapRecycleKeep)
	sparesOn(t, h, "2")
	const p, login = "gh:7101", "wangwu"
	openLogin(t, h, admin, p, login)
	node := plantPerson(t, h, p, login)
	plantCredentials(t, h, p, login, node)

	removeLogin(t, h, p, false)
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountReset || op.Login != login {
		t.Fatalf("op = %+v; want a reset of %s", op, login)
	}
	// Before the wash: the node stays enrolled, the person's pieces go.
	if ep, err := h.srv.Store.EndpointByID(node.id); err != nil || ep.RetiredAt != nil {
		t.Fatalf("the login's node %s = %+v, %v; want kept enrolled (its token is root-held)", node.id, ep, err)
	}
	if c, err := h.srv.Store.SessionCredByID("pass-" + login); err != nil || c.RevokedAt == nil {
		t.Fatalf("the person's pass = %+v, %v; want revoked", c, err)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 0 {
		t.Fatalf("leases = %+v; want the person's released", ls)
	}
	if _, ok, _ := h.srv.Store.EntryHomeOf(p); ok {
		t.Fatalf("the person's 家 is still %s@m8", login)
	}
	rev := revocationJTIs(t, h)
	for _, want := range []string{"ssh:4195" + login, "fcp:pass-" + login, "scope:m8|" + p} {
		if !rev[want] {
			t.Fatalf("revocation list %v lacks %s", rev, want)
		}
	}
	if e := hubAuditHas(t, h, "spare.revoke", login); e == nil || !strings.Contains(e.Detail, "certs 1") || !strings.Contains(e.Detail, "node kept") {
		t.Fatalf("audit spare.revoke = %+v; want the cert and the kept node", e)
	}

	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated,
		Detail: "timing: stop=0.4 keep=0.1 rejoin=3.0 total=6.0\n\nnode: kept (root-held token, no re-join)\nreset: clean\ncredsep: separated"})
	waitFor(t, 3*time.Second, "the recycled spare to be ready", func() bool {
		return h.srv.spareReadyHosts()["m8"] == 1
	})
	if ep, err := h.srv.Store.EndpointByID(node.id); err != nil || ep.RetiredAt != nil {
		t.Fatalf("the kept node = %+v, %v; want still enrolled after the recycle", ep, err)
	}
	if a := accountState(t, h, p, "m8"); a.State != "" {
		t.Fatalf("the person still has %+v on m8", a)
	}
	// who the login belongs to now: the spare, read the way every reader does
	who, err := h.srv.principalOnNode(node.id, "m8", login)
	if err != nil || !strings.HasPrefix(who, "spare:m8:") {
		t.Fatalf("login %s on m8 belongs to %q, %v; want the spare", login, who, err)
	}
	if e := hubAuditHas(t, h, "spare.recycle", login); e == nil || !strings.Contains(e.Detail, p) {
		t.Fatalf("audit spare.recycle = %+v; want the mapping change from %s", e, p)
	}
}

func TestRecycleKeptNodeAmbiguousFails(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h, control.CapCredsep, control.CapRecycle, control.CapRecycleKeep)
	sparesOn(t, h, "2")
	const p, login = "gh:7102", "zhaoliu"
	openLogin(t, h, admin, p, login)
	a := plantPerson(t, h, p, login)
	b := connectCaps(t, h, "m8-"+login+"-2", "m8", login, false)
	time.Sleep(5 * time.Millisecond)

	removeLogin(t, h, p, false)
	m, _ := expectAccountOp(t, admin.tnode)
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated, Detail: "node: kept\nreset: clean\ncredsep: separated"})
	row := waitState(t, h, p, "m8", store.AccountFailed)
	if !strings.Contains(row.Detail, "2 node(s)") {
		t.Fatalf("failed row = %q; want why", row.Detail)
	}
	for _, id := range []string{a.id, b.id} {
		if ep, err := h.srv.Store.EndpointByID(id); err != nil || ep.RetiredAt == nil {
			t.Fatalf("node %s = %+v, %v; want retired (none can be told kept)", id, ep, err)
		}
	}
}

func TestRecycleRevokesOldCertsWhenRejoining(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.RevocationsToken = "rev-4195"
	admin := recycleFleet(t, h) // no CapRecycleKeep: the old road, re-join
	sparesOn(t, h, "2")
	const p, login = "gh:7103", "sunqi"
	openLogin(t, h, admin, p, login)
	node := plantPerson(t, h, p, login)
	plantCredentials(t, h, p, login, node)

	removeLogin(t, h, p, false)
	m, op := expectAccountOp(t, admin.tnode)
	if op.JoinCode == "" {
		t.Fatalf("op = %+v; want a join code (no keep)", op)
	}
	if ep, err := h.srv.Store.EndpointByID(node.id); err != nil || ep.RetiredAt == nil {
		t.Fatalf("node = %+v, %v; want retired (the wash re-joins)", ep, err)
	}
	if rev := revocationJTIs(t, h); !rev["ssh:4195"+login] || !rev["scope:m8|"+p] {
		t.Fatalf("revocation list %v lacks the person's certificate / scope", rev)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated, Detail: "reset: clean\ncredsep: separated"})
	waitFor(t, 3*time.Second, "the recycled spare to be ready", func() bool {
		return h.srv.spareReadyHosts()["m8"] == 1
	})
}
