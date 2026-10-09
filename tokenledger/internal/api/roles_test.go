package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Admin and user see different hubs (claude-fleet#1985): every route is
// named in routeAccess, and a user's cookie is refused every admin route and
// sees only its own rows on the rest.

// fullServer turns on everything Handler can mount.
func fullServer(s *Server) {
	if s.Store != nil {
		if err := s.Store.EnsureNodes(); err != nil {
			panic(err)
		}
	}
	s.Fleet = true
	s.MCP = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(roleOf(r.Context())))
	})
}

// Every pattern Handler mounts has a row, and every row is mounted: a new
// route with no class fails here.
func TestRouteTable_EveryRouteNamed(t *testing.T) {
	s := &Server{LiveStore: NewLive()}
	fullServer(s)
	mounted := map[string]bool{}
	for _, p := range s.routes().patterns {
		mounted[p] = true
		if _, ok := routeAccess[p]; !ok {
			t.Errorf("route %q is mounted but not in routeAccess: name it admin, user, self or public (roles.go)", p)
		}
	}
	for p := range routeAccess {
		if !mounted[p] {
			t.Errorf("routeAccess names %q, which Handler no longer mounts", p)
		}
	}
	for p, c := range routeAccess {
		switch c {
		case accessPublic, accessSelf, accessAdmin, accessUser:
		default:
			t.Errorf("route %q has class %q", p, c)
		}
	}
}

const (
	aliceLogin = "alice-mac"
	rolesSince = "2026-08-31T12:00:00Z"
	rolesUntil = "2026-08-31T15:00:00Z"
)

// rolesHarness: a full hub, an admin (verkyyi) and a user (alice, machine
// login alice-mac), usage from both on two subscriptions.
func rolesHarness(t *testing.T) (h *ghHarness, admin, user *http.Cookie) {
	t.Helper()
	h = newGitHubHarnessWith(t, fullServer, "verkyyi")
	h.addUser(t, ghAlice)
	if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: ghAlice.ID, Login: ghAlice.Login,
		Role: store.RoleUser, MachineLogin: aliceLogin, AddedBy: "gh:100"}); err != nil {
		t.Fatal(err)
	}
	_, admin = h.signIn(t, ghAdmin)
	_, user = h.signIn(t, ghAlice)
	if admin == nil || user == nil {
		t.Fatal("sign-in failed")
	}
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	push := func(label, acct, osUser string, sessions ...string) {
		tok, err := MintToken()
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.Enroll("ep_"+label, label, HashToken(tok)); err != nil {
			t.Fatal(err)
		}
		var evs []model.UsageEvent
		for i, sid := range sessions {
			evs = append(evs, model.UsageEvent{AccountUUID: acct, EndpointID: "ep_" + label, SessionID: sid,
				MessageUUID: label + sid, TS: base.Add(time.Duration(i) * time.Minute), Model: "claude-opus-5",
				OutputTokens: 100, CWD: "/p/" + label, OSUser: osUser})
		}
		body, _ := json.Marshal(model.Batch{Identity: model.Identity{AccountUUID: acct, Email: acct + "@example.com",
			Hostname: label, OS: "darwin", Arch: "arm64", SubscriptionType: "max", OSUser: osUser},
			AccountOrigin: model.OriginLogin, Events: evs})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("push %s: %d", label, resp.StatusCode)
		}
	}
	push("mini", "acct-a", "verkyyi", "s-admin-1", "s-admin-2")
	push("alicebox", "acct-b", aliceLogin, "s-alice")
	// alice-mac is hers on alicebox: what adoption records once the
	// machine's agent runs as her mapped login (claude-fleet#2514).
	giveAccount(t, h.srv, githubPrincipal(ghAlice.ID), "alicebox")
	return h, admin, user
}

// giveAccount records principal's login as theirs on host, as adoption does.
func giveAccount(t *testing.T, s *Server, principal, host string) {
	t.Helper()
	p, err := s.Store.Principal(principal)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Store.AdoptAccount(p, host, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func rolesGet(t *testing.T, h *ghHarness, sess *http.Cookie, path string) (int, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.http.URL+path, nil)
	req.Header.Set("Accept", "application/json")
	if sess != nil {
		req.AddCookie(sess)
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		return resp.StatusCode, nil // a stream: the status is the answer
	}
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

// The completion table: every admin route answers a user 403 (and is
// audited), every user route answers them something other than 403, and an
// admin is refused nothing.
func TestRouteTable_UserCookieOnEveryRoute(t *testing.T) {
	h, admin, user := rolesHarness(t)
	patterns := make([]string, 0, len(routeAccess))
	for p := range routeAccess {
		patterns = append(patterns, p)
	}
	sort.Strings(patterns)
	admins := 0
	for _, p := range patterns {
		path := p
		switch routeAccess[p] {
		case accessAdmin:
			admins++
			if code, b := rolesGet(t, h, user, path); code != http.StatusForbidden {
				t.Errorf("user GET %s = %d %s; want 403", path, code, b)
			}
			if code, _ := rolesGet(t, h, admin, path); code == http.StatusForbidden || code == http.StatusUnauthorized {
				t.Errorf("admin GET %s = %d; want it let through", path, code)
			}
		case accessUser:
			if code, b := rolesGet(t, h, user, path); code == http.StatusForbidden || code == http.StatusUnauthorized {
				t.Errorf("user GET %s = %d %s; want it let through", path, code, b)
			}
		}
	}
	var refused int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'role_denied'
		AND outcome = 'FORBIDDEN' AND actor LIKE 'gh:200%'`).Scan(&refused); err != nil {
		t.Fatal(err)
	}
	if refused < admins {
		t.Errorf("%d role refusals audited; want at least %d", refused, admins)
	}
}

// A user's lists carry only their machine login's rows, and no subscription.
func TestRoleScope_UserSeesOwnRows(t *testing.T) {
	h, admin, user := rolesHarness(t)
	rng := "&since=" + rolesSince + "&until=" + rolesUntil

	var usage struct {
		Buckets []store.Bucket `json:"buckets"`
	}
	_, b := rolesGet(t, h, user, "/v1/usage?by=user&account=acct-a"+rng)
	if err := json.Unmarshal(b, &usage); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	if len(usage.Buckets) != 1 || usage.Buckets[0].Key != aliceLogin {
		t.Errorf("user /v1/usage by user = %+v; want only %s", usage.Buckets, aliceLogin)
	}
	// An admin's Overview is their own too (claude-fleet#2515) — none on
	// record here; everyone's is the admin area's.
	_, b = rolesGet(t, h, admin, "/v1/usage?by=user&account=all"+rng)
	_ = json.Unmarshal(b, &usage)
	if len(usage.Buckets) != 0 {
		t.Errorf("admin /v1/usage by user = %+v; want none of their own", usage.Buckets)
	}
	var ov AdminOverview
	_, b = rolesGet(t, h, admin, AdminOverviewPath+"?since="+rolesSince)
	_ = json.Unmarshal(b, &ov)
	if len(ov.People) != 2 {
		t.Errorf("admin %s = %s; want both logins", AdminOverviewPath, b)
	}
	if code, _ := rolesGet(t, h, user, "/v1/usage?by=account"+rng); code != http.StatusForbidden {
		t.Errorf("user /v1/usage by account = %d; want 403", code)
	}

	var rows []store.SessionRow
	_, b = rolesGet(t, h, user, "/v1/sessions?account=all"+rng)
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	if len(rows) != 1 || rows[0].OSUser != aliceLogin || rows[0].AccountUUID != "" {
		t.Errorf("user /v1/sessions = %+v; want only s-alice, no subscription", rows)
	}
	if code, _ := rolesGet(t, h, user, "/v1/sessions/s-admin-1?account=all"); code != http.StatusNotFound {
		t.Errorf("user /v1/sessions/<admin's> = %d; want 404", code)
	}
	if code, _ := rolesGet(t, h, user, "/v1/sessions/s-alice?account=all"); code != http.StatusOK {
		t.Errorf("user /v1/sessions/<own> = %d; want 200", code)
	}

	var sum struct {
		Events int64            `json:"events"`
		Spend  []map[string]any `json:"subscription_spend"`
	}
	_, b = rolesGet(t, h, user, "/v1/summary?account=all"+rng)
	_ = json.Unmarshal(b, &sum)
	if sum.Events != 1 || len(sum.Spend) != 0 {
		t.Errorf("user /v1/summary = %+v; want 1 event, no subscription spend", sum)
	}

	var page struct {
		Login string `json:"os_user"`
	}
	_, b = rolesGet(t, h, user, "/v1/user?user=verkyyi"+rng)
	_ = json.Unmarshal(b, &page)
	if page.Login != aliceLogin {
		t.Errorf("user /v1/user?user=verkyyi answered %q; want their own page", page.Login)
	}

	var m Me
	_, b = rolesGet(t, h, user, "/v1/me")
	_ = json.Unmarshal(b, &m)
	if m.Role != roleUser || m.Login != aliceLogin || !reflect.DeepEqual(m.Pages, userPages) {
		t.Errorf("user /v1/me = %+v", m)
	}
	_, b = rolesGet(t, h, admin, "/v1/me")
	_ = json.Unmarshal(b, &m)
	if m.Role != roleAdmin || !reflect.DeepEqual(m.Pages, adminPages) {
		t.Errorf("admin /v1/me = %+v", m)
	}
}

// A user with no machine login sees nothing, never everything.
func TestRoleScope_NoMachineLoginSeesNothing(t *testing.T) {
	h, _, _ := rolesHarness(t)
	h.addUser(t, ghMallory)
	_, mallory := h.signIn(t, ghMallory)
	var rows []store.SessionRow
	_, b := rolesGet(t, h, mallory, "/v1/sessions?account=all&since="+rolesSince+"&until="+rolesUntil)
	if err := json.Unmarshal(b, &rows); err != nil || len(rows) != 0 {
		t.Errorf("no-login user /v1/sessions = %s; want []", b)
	}
}

// Live: a user's own sessions, with no subscription on them.
func TestRoleScope_LiveFilteredToLogin(t *testing.T) {
	s := &Server{}
	snap := Snapshot{Sessions: []LiveSession{
		{SessionID: "a", Account: "acct-a", OSUser: "verkyyi", InputTokens: 5},
		{SessionID: "b", Account: "acct-b", ProfileID: "p", OSUser: aliceLogin, InputTokens: 7},
	}}
	got := s.FilterLiveFor(snap, "all", "", &UserLogins{Login: aliceLogin})
	if len(got.Sessions) != 1 || got.Sessions[0].SessionID != "b" || got.Sessions[0].Account != "" ||
		got.Sessions[0].ProfileID != "" || got.SessionTokens != 7 {
		t.Errorf("FilterLiveFor = %+v", got)
	}
	if all := s.FilterLiveFor(snap, "all", "", nil); len(all.Sessions) != 2 {
		t.Errorf("FilterLiveFor with no login = %d sessions; want 2", len(all.Sessions))
	}
}

// fleetToolTrim is how each /v1/fleet/<tool> trims a person's answer
// (claude-fleet#2513): "scope" = rows filtered by FleetScope, "principal" =
// only what this principal asked for, "write" = journalled and checked
// against FleetScope before it runs. Every tool CallFleetTool serves has a
// row, so a new tool cannot arrive answering a user the whole hub.
var fleetToolTrim = map[string]string{
	"fleet_list": "scope", "fleet_sessions": "scope", "fleet_status": "scope", "config_get": "scope",
	"fleet_alerts":  "scope",
	"operation_get": "principal",
	"gh_issue_view": "principal", "gh_pr_view": "principal", "gh_pr_checks": "principal",
	"worker_start": "write", "worker_message": "write", "worker_stop": "write", "worker_resume": "write",
	"worker_answer": "write", "worker_reap": "write", "worker_switch": "write", "worker_rename": "write",
	"worker_reap_policy": "write", "config_set": "write", "gh_comment": "write", "service_control": "write",
}

// Every fleet tool, one by one: it has a trim class, a user's cookie gets
// through the role gate to it (the prefix alone was all that was tested), and
// fleet_alerts answers a user only the alerts about their own logins.
func TestRoleScope_FleetToolsEachTrimmed(t *testing.T) {
	h, admin, user := rolesHarness(t)
	served := append([]string{"fleet_alerts"}, FleetTools...)
	for _, tool := range served {
		c, ok := fleetToolTrim[tool]
		if !ok {
			t.Errorf("fleet tool %q has no trim class in fleetToolTrim", tool)
			continue
		}
		code, b := rolesGet(t, h, user, "/v1/fleet/"+tool)
		if code == http.StatusForbidden || code == http.StatusUnauthorized {
			t.Errorf("user GET /v1/fleet/%s = %d %s; want it past the role gate", tool, code, b)
		}
		if c == "write" && code != http.StatusMethodNotAllowed {
			t.Errorf("user GET /v1/fleet/%s (a write) = %d %s; want 405", tool, code, b)
		}
	}
	for tool := range fleetToolTrim {
		if !hasString(served, tool) {
			t.Errorf("fleetToolTrim names %q, which CallFleetTool no longer serves", tool)
		}
	}

	// Two people, two machines: verkyyi@mini and alice@alicebox.
	at := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	raise := func(kind, subject string, detail any) {
		b, _ := json.Marshal(detail)
		if _, err := h.srv.Store.RaiseFleetAlert(kind, subject, string(b), at); err != nil {
			t.Fatal(err)
		}
	}
	raise(store.AlertNodeLost, "ep_mini", map[string]any{"endpoint_id": "ep_mini", "hostname": "mini", "os_user": "verkyyi"})
	raise(store.AlertNodeLost, "ep_alicebox", map[string]any{"endpoint_id": "ep_alicebox", "hostname": "alicebox", "os_user": aliceLogin})
	raise(store.AlertLeaseConflict, "o/r#1", leaseConflict{Repo: "o/r", Issue: 1,
		Holder: leaseConflictSide{EndpointID: "ep_mini"}, Reporter: leaseConflictSide{EndpointID: "ep_gone"}})
	raise(store.AlertLeaseConflict, "o/r#2", leaseConflict{Repo: "o/r", Issue: 2,
		Holder: leaseConflictSide{EndpointID: "ep_mini"}, Reporter: leaseConflictSide{EndpointID: "ep_alicebox"}})
	raise("some_future_kind", "x", map[string]any{"hostname": "alicebox", "os_user": aliceLogin})

	alerts := func(who *http.Cookie) []string {
		t.Helper()
		code, b := rolesGet(t, h, who, "/v1/fleet/fleet_alerts")
		var out struct {
			Open   int `json:"open"`
			Alerts []struct {
				Kind    string `json:"kind"`
				Subject string `json:"subject"`
			} `json:"alerts"`
		}
		if code != http.StatusOK || json.Unmarshal(b, &out) != nil {
			t.Fatalf("GET fleet_alerts = %d %s", code, b)
		}
		if out.Open != len(out.Alerts) {
			t.Errorf("fleet_alerts open = %d over %d rows; the count must be of the rows shown", out.Open, len(out.Alerts))
		}
		var got []string
		for _, a := range out.Alerts {
			got = append(got, a.Kind+" "+a.Subject)
		}
		sort.Strings(got)
		return got
	}
	if got, want := alerts(user), []string{"lease_conflict o/r#2", "node_lost ep_alicebox"}; !reflect.DeepEqual(got, want) {
		t.Errorf("user fleet_alerts = %v; want only their own %v", got, want)
	}
	if got := alerts(admin); len(got) != 5 {
		t.Errorf("admin fleet_alerts = %v; want all 5", got)
	}
}
