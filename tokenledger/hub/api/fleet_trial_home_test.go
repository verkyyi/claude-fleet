package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet T789: an approved newcomer heard 「你还没有家」 for good —
// least-busy had picked another person's pod, whose node refuses any other
// login (exit 3), and nothing tried elsewhere; and they started with no
// limits at all.

// A person's pod is never where a newcomer's login opens, however idle.
func TestLeastBusySkipsAPersonsPod(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	leastBusyFleet(t, h)
	pod := connectNode(t, h, "pod-op", "u-drillcn4150", "ivan", true)
	beatCount(t, pod, "u-drillcn4150", "ivan", 0)
	waitFor(t, 3*time.Second, "the pod on the roster", func() bool {
		snap, err := h.srv.Nodes(time.Now())
		if err != nil {
			return false
		}
		for _, m := range snap.Machines {
			if m.Hostname == "u-drillcn4150" && m.Status == "online" && m.Sessions != nil {
				return true
			}
		}
		return false
	})
	if got := h.srv.leastBusyMachine(time.Now()); got != "mac-d" {
		t.Fatalf("least busy = %q; want mac-d, never the pod", got)
	}
	if got := h.srv.leastBusyMachine(time.Now(), "mac-d", "mac-c"); got != "" {
		t.Fatalf("with mac-c and mac-d out = %q; want none — the pod is not a choice", got)
	}
}

// A create that fails goes to the next machine; a person with a login is
// never opened another at their next sign-in.
func TestFailedCreateTriesTheNextMachine(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4789"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	listPerson(t, h, p, "zhaoliu")

	h.srv.onPrincipalSignIn(p, "zhaoliu")
	m, op := expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Op != control.AccountCreate {
		t.Fatalf("op = %+v", op)
	}
	if why := h.srv.noHomeWhy(p); !strings.Contains(why, "正在为你开家") {
		t.Fatalf("no home while opening = %q", why)
	}
	sendResult(t, nodes["mac-d"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login,
		Exit: 3, Exists: true, Detail: "this pod is someone's alone"})
	m2, op2 := expectAccountOp(t, nodes["mac-c"].tnode)
	if op2.Op != control.AccountCreate || op2.Login != op.Login {
		t.Fatalf("next op = %+v; want the same create on mac-c", op2)
	}
	if a := accountState(t, h, p, "mac-d"); a.State != store.AccountFailed {
		t.Fatalf("mac-d = %+v; want failed", a)
	}
	sendResult(t, nodes["mac-c"].c, m2.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitFor(t, 3*time.Second, "the mac-c login active", func() bool {
		return accountState(t, h, p, "mac-c").State == store.AccountActive
	})

	h.srv.onPrincipalSignIn(p, "zhaoliu")
	for _, host := range []string{"mac-c", "mac-d", "m6"} {
		if got, ok := readMsg(nodes[host].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("a second sign-in sent %s %+v", host, got)
		}
	}
}

// Every machine failing ends in a sentence, not a loop.
func TestFailedCreateStopsAndSays(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4790"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	listPerson(t, h, p, "sunqi")
	h.srv.onPrincipalSignIn(p, "sunqi")
	for _, host := range []string{"mac-d", "mac-c"} {
		m, op := expectAccountOp(t, nodes[host].tnode)
		sendResult(t, nodes[host].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, Exit: 1})
	}
	waitFor(t, 3*time.Second, "both failed", func() bool {
		return accountState(t, h, p, "mac-c").State == store.AccountFailed
	})
	if got, ok := readMsg(nodes["m6"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("维护中 m6 was sent %+v", got)
	}
	if why := h.srv.noHomeWhy(p); !strings.Contains(why, "没有成功") {
		t.Fatalf("no home after failing = %q", why)
	}
}

func TestMemberLimitsParse(t *testing.T) {
	now := time.Date(2026, 10, 21, 8, 0, 0, 0, time.UTC)
	tt, err := parseTrialTerms(applyTrialDefault)
	if err != nil || tt.Days != 7 || tt.Tokens != 1_500_000 || tt.USD != 0 || tt.Sessions != 1 {
		t.Fatalf("default = %+v %v", tt, err)
	}
	l := tt.limits(now)
	back, err := parseMemberLimits(l.String())
	if err != nil || !back.Until.Equal(now.Add(7*24*time.Hour)) || back.Tokens != 1_500_000 || back.Sessions != 1 || !back.Since.Equal(now) {
		t.Fatalf("round trip %q = %+v %v", l.String(), back, err)
	}
	if off, _ := parseTrialTerms("off"); !off.limits(now).empty() {
		t.Fatal("off holds something")
	}
	for _, bad := range []string{"days=x", "usd=-1", "tokens=-5", "tokens=lots", "sessions=1000", "weeks=1", "nonsense"} {
		if _, err := parseTrialTerms(bad); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
}

// Past the trial's end, or its dollars spent, the person's requests are
// refused with a sentence that says which.
func TestMemberLimitsRefuse(t *testing.T) {
	h := newFleetHarness(t)
	const p = "p:11111111-2222-4333-8444-555555555555"
	now := time.Now()
	key := MemberLimitsPrefix + p
	setHubSetting(t, h.srv, key, MemberLimits{Until: now.Add(time.Hour), USD: 1, Since: now.Add(-time.Hour)}.String())
	st, err := h.srv.personBudgetState(p, now)
	if err != nil || st.Over || st.TrialUSD != 1 || st.TrialUntil == nil {
		t.Fatalf("fresh = %+v %v", st, err)
	}
	// 100k output tokens of Opus = $2.50 > $1
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: p, Provider: "claude", Model: "claude-opus-5",
		Out: 100_000, At: now.Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	st, _ = h.srv.personBudgetState(p, now)
	if !st.Over || st.Error != PersonBudgetExceeded || !strings.Contains(st.Message, "试用额度已用完") || st.TrialSpentUSD < 2.4 {
		t.Fatalf("spent = %+v", st)
	}
	setHubSetting(t, h.srv, key, MemberLimits{Until: now.Add(-time.Minute), Since: now.Add(-time.Hour)}.String())
	st, _ = h.srv.personBudgetState(p, now)
	if !st.Over || !strings.Contains(st.Message, "试用期已于") {
		t.Fatalf("ended = %+v", st)
	}
	setHubSetting(t, h.srv, key, "")
	if st, _ = h.srv.personBudgetState(p, now); st.Over {
		t.Fatalf("转正 still over: %+v", st)
	}
}

// Approval starts a newcomer with fleet.apply.trial's limits (or the
// approval's own) and the subscriptions a converted trial gets.
func TestApproveWritesLimitsAndSubscriptions(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	now := time.Now()
	seedRequest(t, h, "rq-t1", store.IdentityEmail, "erin@example.com", "erin@example.com", now)
	seedRequest(t, h, "rq-t2", store.IdentityEmail, "finn@example.com", "finn@example.com", now)
	seedRequest(t, h, "rq-t3", store.IdentityEmail, "gwen@example.com", "gwen@example.com", now)
	if st, b := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-t1/approve", map[string]any{"limits": "days=x"}); st != http.StatusBadRequest {
		t.Fatalf("bad limits = %d %s", st, b)
	}
	approve := func(id string, body map[string]any) string {
		st, b := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/"+id+"/approve", body)
		var d adminRequestDetail
		if st != http.StatusOK || json.Unmarshal(b, &d) != nil || d.Person == "" {
			t.Fatalf("approve %s = %d %s", id, st, b)
		}
		return d.Person
	}
	settings := func() map[string]string {
		s, err := h.srv.Store.FleetSettings()
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	p1 := approve("rq-t1", map[string]any{})
	l, ok := memberLimitsOf(settings(), p1)
	if !ok || l.Tokens != 1_500_000 || l.Sessions != 1 || l.Until.Sub(now) < 6*24*time.Hour {
		t.Fatalf("default limits = %+v %v", l, ok)
	}
	if v := settings()[credUserKey(p1)]; v != `"*"` {
		t.Fatalf("subscriptions = %q; want the trial's \"*\"", v)
	}
	p2 := approve("rq-t2", map[string]any{"limits": "days=3,usd=5"})
	if l, _ := memberLimitsOf(settings(), p2); l.USD != 5 || l.Sessions != 0 || l.Until.Sub(now) > 4*24*time.Hour {
		t.Fatalf("own limits = %+v", l)
	}
	p3 := approve("rq-t3", map[string]any{"limits": "off"})
	if _, ok := memberLimitsOf(settings(), p3); ok {
		t.Fatal("off wrote limits")
	}
	// approving again never resets them
	before := settings()[MemberLimitsPrefix+p1]
	approve("rq-t1", map[string]any{"limits": "days=30"})
	if after := settings()[MemberLimitsPrefix+p1]; after != before {
		t.Fatalf("re-approve changed %q → %q", before, after)
	}
}
