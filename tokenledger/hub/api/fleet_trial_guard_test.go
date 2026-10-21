package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet WACK C4: a machine's trial guard reads who is on trial there
// and the limits, and raises trial_runaway / trial_abuse — only for a trial
// login, the admins told once in 30 minutes.

func TestTrialLimitsSetting(t *testing.T) {
	for v, want := range map[string]string{
		"":                      "cpu=4,mem=8G,disk=20G",
		"cpu=2":                 "cpu=2,mem=8G,disk=20G",
		"cpu=4,mem=8G,disk=20G": "cpu=4,mem=8G,disk=20G",
		"cpu=1.5 mem=512M":      "cpu=1.5,mem=512M,disk=20G",
		"disk=1T":               "cpu=4,mem=8G,disk=1T",
		"OFF":                   "off",
		"mem=8GB,disk=20480M":   "cpu=4,mem=8G,disk=20G",
	} {
		got, why := checkTrialLimits(nil, v)
		if why != "" || got != want {
			t.Errorf("check(%q) = %q, %q; want %q", v, got, why, want)
		}
	}
	for _, bad := range []string{"cpu=0", "cpu=x", "mem=-1G", "net=1", "disk"} {
		if _, why := checkTrialLimits(nil, bad); why == "" {
			t.Errorf("check(%q) passed; want refused", bad)
		}
	}
	if _, ok := hubSettings[TrialLimitsKey]; !ok || hubSettings[TrialLimitsKey].help == "" {
		t.Fatal("fleet.trial.limits is not in the settings table with a help line")
	}
}

// trialGuardFixture: mac-t's machine program, a trial person (the trial road),
// a person on trial terms (member_limits until), and a member — each with a
// login there.
func trialGuardFixture(t *testing.T) (*harness, string) {
	t.Helper()
	h := newFleetHarness(t)
	_, tok := rootNode(t, h, "roottg", "mac-t")
	now := time.Now()
	for _, p := range [][2]string{{"wx-tria", "tria"}, {"wx-terms", "terms"}, {"wx-memb", "memb"}} {
		pr, err := h.srv.Store.AdoptPrincipal(p[0], p[1], p[1], now)
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.AdoptAccount(pr, "mac-t", now); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.StartTrial("wx-tria", now); err != nil {
		t.Fatal(err)
	}
	setHubSetting(t, h.srv, MemberLimitsPrefix+"wx-terms", "until="+now.Add(72*time.Hour).UTC().Format(time.RFC3339)+",tokens=3000000")
	// a member's limits without an until (a ceiling only) are not a trial
	setHubSetting(t, h.srv, MemberLimitsPrefix+"wx-memb", "tokens=9000000")
	return h, tok
}

func TestTrialIdentityIsOneReading(t *testing.T) {
	h, _ := trialGuardFixture(t)
	for pid, want := range map[string]bool{"wx-tria": true, "wx-terms": true, "wx-memb": false, "": false, "wx-nobody": false} {
		set, _ := h.srv.Store.FleetSettings()
		if got := h.srv.trialIdentity(set, pid); got != want {
			t.Errorf("trialIdentity(%q) = %v; want %v", pid, got, want)
		}
	}
}

func TestNodeTrialLimitsListsTrialLoginsOnly(t *testing.T) {
	h, tok := trialGuardFixture(t)
	code, raw := entryCall(t, h, http.MethodGet, TrialLimitsNodePath, asNode(tok), nil)
	if code != http.StatusOK {
		t.Fatalf("GET: HTTP %d %s", code, raw)
	}
	var l TrialGuardList
	if err := json.Unmarshal([]byte(raw), &l); err != nil {
		t.Fatal(err)
	}
	if !l.On || l.CPU != 4 || l.MemBytes != 8<<30 || l.DiskBytes != 20<<30 {
		t.Fatalf("limits = %+v; want on, 4 cores, 8G, 20G", l)
	}
	if len(l.Logins) != 2 || l.Logins["tria"] != "wx-tria" || l.Logins["terms"] != "wx-terms" {
		t.Fatalf("logins = %v; want tria + terms, never the member", l.Logins)
	}
	if code, _ := entryCall(t, h, http.MethodGet, TrialLimitsNodePath, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("no token: HTTP %d; want 401", code)
	}
	setHubSetting(t, h.srv, TrialLimitsKey, "off")
	_, raw = entryCall(t, h, http.MethodGet, TrialLimitsNodePath, asNode(tok), nil)
	l = TrialGuardList{}
	_ = json.Unmarshal([]byte(raw), &l)
	if l.On || len(l.Logins) != 0 {
		t.Fatalf("off: %s; want on=false and no login", raw)
	}
}

func TestNodeTrialAlertRaisesOnceAndSparesMembers(t *testing.T) {
	h, tok := trialGuardFixture(t)
	var mu sync.Mutex
	var told []string
	h.srv.Notify = func(m string) { mu.Lock(); told = append(told, m); mu.Unlock() }
	trialTold.Lock()
	trialTold.at = map[string]time.Time{}
	trialTold.Unlock()

	post := func(body TrialAlertRequest) (int, string) {
		t.Helper()
		return entryCall(t, h, http.MethodPost, TrialAlertNodePath, asNode(tok), body)
	}
	if code, raw := post(TrialAlertRequest{Login: "tria", Kind: "runaway", What: "cpu", Action: "renice", Detail: "412% of 400% for 3 min"}); code != 200 ||
		!strings.Contains(raw, `"raised":true`) || !strings.Contains(raw, `"told":true`) {
		t.Fatalf("first runaway: HTTP %d %s", code, raw)
	}
	detail, _, ok, err := h.srv.Store.OpenFleetAlert(store.AlertTrialRunaway, "mac-t/tria")
	if err != nil || !ok || !strings.Contains(detail, `"renice"`) || !strings.Contains(detail, "wx-tria") {
		t.Fatalf("open trial_runaway = %q %v %v", detail, ok, err)
	}
	// the escalation inside 30 minutes: recorded in the audit, the admins not told again
	if code, raw := post(TrialAlertRequest{Login: "tria", Kind: "runaway", What: "cpu", Action: "pause"}); code != 200 ||
		!strings.Contains(raw, `"told":false`) {
		t.Fatalf("second runaway: HTTP %d %s", code, raw)
	}
	// another kind is its own line
	if code, raw := post(TrialAlertRequest{Login: "terms", Kind: "abuse", What: "miner", Action: "pause", Detail: "xmrig"}); code != 200 ||
		!strings.Contains(raw, `"told":true`) {
		t.Fatalf("abuse: HTTP %d %s", code, raw)
	}
	if _, _, ok, _ := h.srv.Store.OpenFleetAlert(store.AlertTrialAbuse, "mac-t/terms"); !ok {
		t.Fatal("no open trial_abuse for terms")
	}
	mu.Lock()
	n := len(told)
	first := ""
	if n > 0 {
		first = told[0]
	}
	mu.Unlock()
	if n != 2 || !strings.Contains(first, "试用告警") || !strings.Contains(first, "trial alert") {
		t.Fatalf("told %d: %q; want 2 messages, Chinese and English", n, first)
	}
	// a member is never written up as a trial
	if code, raw := post(TrialAlertRequest{Login: "memb", Kind: "runaway", What: "cpu", Action: "renice"}); code != http.StatusForbidden {
		t.Fatalf("member: HTTP %d %s; want 403", code, raw)
	}
	if code, _ := post(TrialAlertRequest{Login: "tria", Kind: "runaway", What: "rm -rf", Action: "renice"}); code != http.StatusBadRequest {
		t.Fatalf("unknown what: HTTP %d; want 400", code)
	}
	// back under its line: the machine clears it
	if code, raw := post(TrialAlertRequest{Login: "tria", Kind: "runaway", What: "cpu", Clear: true}); code != 200 || !strings.Contains(raw, `"cleared":true`) {
		t.Fatalf("clear: HTTP %d %s", code, raw)
	}
	if _, _, ok, _ := h.srv.Store.OpenFleetAlert(store.AlertTrialRunaway, "mac-t/tria"); ok {
		t.Fatal("trial_runaway still open after the clear")
	}
}
