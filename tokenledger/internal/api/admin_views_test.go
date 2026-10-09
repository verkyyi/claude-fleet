package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// An admin's daily pages show their own; the whole hub is the admin area's
// (claude-fleet#2515, EPIC #2512 C3).

// adminViewsHarness is rolesHarness with the admin's own login on record
// (verkyyi on mini), a fleet with one session on each machine, and a device
// each.
func adminViewsHarness(t *testing.T) (h *ghHarness, admin, user *http.Cookie) {
	t.Helper()
	h, admin, user = rolesHarness(t)
	now := time.Now()
	st := h.srv.Store
	p, err := st.AdoptPrincipal(githubPrincipal(ghAdmin.ID), ghAdmin.Login, ghAdmin.Login, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.RecordLoginAccount(p, "mini", "verkyyi", "ep_mini", "test", now); err != nil {
		t.Fatal(err)
	}
	snap := func(ep, host, osUser, fid, key, state string) {
		w, _ := json.Marshal([]map[string]any{{"key": key, "state": state, "worker_id": fid + "/w-" + key}})
		if _, err := st.RecordFleetSnapshot(ep, host, osUser, "mach-"+host, []store.FleetReport{{FleetID: fid,
			Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(w)}}, now); err != nil {
			t.Fatal(err)
		}
	}
	snap("ep_mini", "mini", "verkyyi", "11111111-1111-4111-8111-111111111111", "issue-1", "working")
	snap("ep_alicebox", "alicebox", aliceLogin, "22222222-2222-4222-8222-222222222222", "issue-2", "waiting")
	for _, d := range []store.FleetDevice{
		{Fingerprint: "SHA256:admin", PrincipalID: githubPrincipal(ghAdmin.ID), PublicKey: "ssh-ed25519 AAAAadmin", Name: "admin-mac"},
		{Fingerprint: "SHA256:alice", PrincipalID: githubPrincipal(ghAlice.ID), PublicKey: "ssh-ed25519 AAAAalice", Name: "alice-mac"},
	} {
		if _, err := st.RegisterDevice(d, now); err != nil {
			t.Fatal(err)
		}
	}
	return h, admin, user
}

func getJSON(t *testing.T, h *ghHarness, c *http.Cookie, path string, into any) int {
	t.Helper()
	code, b := rolesGet(t, h, c, path)
	if code == http.StatusOK {
		if err := json.Unmarshal(b, into); err != nil {
			t.Fatalf("GET %s: %v: %s", path, err, b)
		}
	}
	return code
}

func sessionLogins(t *testing.T, h *ghHarness, c *http.Cookie, path string) (int, []string) {
	t.Helper()
	var fs struct {
		Sessions []FleetSession `json:"sessions"`
	}
	code := getJSON(t, h, c, path, &fs)
	got := []string{}
	for _, s := range fs.Sessions {
		got = append(got, s.MachineName+"/"+s.OSUser)
	}
	sort.Strings(got)
	return code, got
}

func deviceNames(t *testing.T, h *ghHarness, c *http.Cookie, path string) (int, []string) {
	t.Helper()
	var dr DevicesResponse
	code := getJSON(t, h, c, path, &dr)
	got := []string{}
	for _, d := range dr.Devices {
		got = append(got, d.Name)
	}
	sort.Strings(got)
	return code, got
}

// The old routes answer an admin only their own; the new ones everyone's;
// a user is refused the new ones.
func TestAdminViews_DailyOwnAdminAll(t *testing.T) {
	h, admin, user := adminViewsHarness(t)
	rng := "&since=" + rolesSince + "&until=" + rolesUntil

	// Overview's reads.
	var usage struct {
		Buckets []store.Bucket `json:"buckets"`
	}
	getJSON(t, h, admin, "/v1/usage?by=user&account=all"+rng, &usage)
	if len(usage.Buckets) != 1 || usage.Buckets[0].Key != "verkyyi" {
		t.Errorf("admin /v1/usage by user = %+v; want only their own verkyyi", usage.Buckets)
	}
	var sum struct {
		Events int64 `json:"events"`
	}
	getJSON(t, h, admin, "/v1/summary?account=all"+rng, &sum)
	if sum.Events != 2 {
		t.Errorf("admin /v1/summary events = %d; want their own 2", sum.Events)
	}
	if code, _ := rolesGet(t, h, admin, "/v1/usage?by=account"+rng); code != http.StatusForbidden {
		t.Errorf("admin /v1/usage by account on the daily route = %d; want 403 (subscriptions are the admin area's)", code)
	}
	var ov AdminOverview
	if code := getJSON(t, h, admin, AdminOverviewPath+"?since=2026-08-31T00:00:00Z", &ov); code != http.StatusOK {
		t.Fatalf("admin %s = %d", AdminOverviewPath, code)
	}
	byLogin := map[string]AdminPerson{}
	for _, p := range ov.People {
		byLogin[p.Login] = p
	}
	if len(byLogin) != 2 || byLogin["verkyyi"].Tokens != 200 || byLogin[aliceLogin].Tokens != 100 {
		t.Errorf("admin overview people = %+v; want verkyyi 200 and %s 100", ov.People, aliceLogin)
	}
	if v := byLogin["verkyyi"]; v.Sessions != 1 || v.Running != 1 || len(v.Machines) != 1 || v.Machines[0] != "mini" ||
		len(v.People) != 1 || v.People[0] != ghAdmin.Login {
		t.Errorf("admin overview verkyyi = %+v; want 1 running session on mini, held by %s", v, ghAdmin.Login)
	}
	if ov.Totals.Sessions != 2 || ov.Totals.Running != 2 || ov.Totals.Tokens != 300 || ov.Totals.Machines != 2 {
		t.Errorf("admin overview totals = %+v", ov.Totals)
	}

	// Sessions.
	if _, got := sessionLogins(t, h, admin, "/v1/fleet/fleet_sessions"); !equalStrings(got, []string{"mini/verkyyi"}) {
		t.Errorf("admin /v1/fleet/fleet_sessions = %v; want only mini/verkyyi", got)
	}
	if _, got := sessionLogins(t, h, admin, AdminSessionsPath); !equalStrings(got, []string{"alicebox/" + aliceLogin, "mini/verkyyi"}) {
		t.Errorf("admin %s = %v; want both", AdminSessionsPath, got)
	}
	if _, got := sessionLogins(t, h, user, "/v1/fleet/fleet_sessions"); !equalStrings(got, []string{"alicebox/" + aliceLogin}) {
		t.Errorf("user /v1/fleet/fleet_sessions = %v; want only their own", got)
	}

	// Devices.
	if _, got := deviceNames(t, h, admin, "/v1/fleet/devices"); !equalStrings(got, []string{"admin-mac"}) {
		t.Errorf("admin /v1/fleet/devices = %v; want only admin-mac", got)
	}
	if _, got := deviceNames(t, h, admin, AdminDevicesPath); !equalStrings(got, []string{"admin-mac", "alice-mac"}) {
		t.Errorf("admin %s = %v; want both", AdminDevicesPath, got)
	}

	// The admin area refuses a user, data and page alike.
	for _, p := range []string{AdminSessionsPath, AdminOverviewPath, AdminDevicesPath, "/admin/sessions", "/admin/overview", "/admin/devices"} {
		if code, _ := rolesGet(t, h, user, p); code != http.StatusForbidden {
			t.Errorf("user GET %s = %d; want 403", p, code)
		}
	}

	// An admin still revokes anyone's device from All devices.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/devices/revoke", strings.NewReader(`{"fingerprint":"SHA256:alice"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(admin)
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("admin revoking a user's device = %d; want 200", resp.StatusCode)
	}
}

// The operator's doors are never cut: ownView is an admin's and a user's.
func TestAdminViews_OperatorNotCut(t *testing.T) {
	r, _ := http.NewRequest(http.MethodGet, "/", nil)
	ctx := withDoor(r.Context(), doorToken)
	own := ownViewCtx(ctx)
	if cutToSelf(own) {
		t.Error("an operator door on a daily route is cut; want everything")
	}
	adm := withRole(withPrincipal(ctx, githubPrincipal(ghAdmin.ID)), roleAdmin)
	if cutToSelf(adm) {
		t.Error("an admin off the daily routes is cut; want everything")
	}
	if !cutToSelf(ownViewCtx(adm)) {
		t.Error("an admin on a daily route is not cut; want their own")
	}
	usr := withPrincipal(ctx, githubPrincipal(ghAlice.ID))
	if !cutToSelf(usr) {
		t.Error("a user off the daily routes is not cut")
	}
}

func ownViewCtx(ctx context.Context) context.Context {
	return context.WithValue(ctx, ownViewKey{}, true)
}

func withPrincipal(ctx context.Context, p string) context.Context {
	return context.WithValue(ctx, principalKey{}, p)
}

// An admin imports into their own settings layer as anyone does (the same
// line of Config, claude-fleet#2515 / #2521); someone else's stays refused.
func TestAdminViews_AdminImportsOwnSettings(t *testing.T) {
	h, admin, _ := adminViewsHarness(t)
	put := func(query string) int {
		t.Helper()
		body, _ := json.Marshal(personV1)
		req, _ := http.NewRequest(http.MethodPut, h.http.URL+"/v1/fleet/person-bundle"+query, strings.NewReader(string(body)))
		req.Header.Set("Content-Type", "application/json")
		req.AddCookie(admin)
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := put(""); code != http.StatusOK {
		t.Errorf("admin PUT their own layer = %d; want 200", code)
	}
	if code := put("?principal=" + githubPrincipal(ghAdmin.ID)); code != http.StatusOK {
		t.Errorf("admin PUT naming themselves = %d; want 200", code)
	}
	if code := put("?principal=" + githubPrincipal(ghAlice.ID)); code != http.StatusForbidden {
		t.Errorf("admin PUT new content into a user's layer = %d; want 403", code)
	}
}
