package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// 只读控制台票据 (task T844): an acceptance session opens its own person's
// /app read-only, through a one-time link the hub hands it.

// ticketNode enrolls one more token for host's osUser (what a node of that
// login holds) and returns it with a worker assertion of one of its sessions.
func ticketNode(t *testing.T, h *ghHarness, label, host, osUser, acct string) (tok, assertion string) {
	t.Helper()
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.Enroll("ep_"+label, label, HashToken(tok)); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(model.Batch{Identity: model.Identity{AccountUUID: acct, Email: acct + "@example.com",
		Hostname: host, OS: "darwin", Arch: "arm64", SubscriptionType: "max", OSUser: osUser},
		AccountOrigin: model.OriginLogin, Events: []model.UsageEvent{{AccountUUID: acct, EndpointID: "ep_" + label,
			SessionID: "s-" + label, MessageUUID: "m-" + label, TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
			Model: "claude-opus-5", OutputTokens: 1, CWD: "/p", OSUser: osUser}}})
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("ingest %s: %d", label, resp.StatusCode)
	}
	now := time.Now()
	fleet := fleetid.ClientFleetID(HashToken(tok))
	c := workerClaims{V: 1, WorkerID: fleetid.WorkerID(fleet, assertFid), FleetUUID: fleet, Fid: assertFid,
		Key: "scratch-1", Node: host, Iat: now.Unix(), Exp: now.Add(5 * time.Minute).Unix()}
	return tok, signWorkerAssertion(c, HashToken(tok))
}

func ticketAsk(t *testing.T, h *ghHarness, tok, assertion string, body any) (int, ConsoleTicketResponse, string) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+ConsoleTicketNodePath, bytes.NewReader(b))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if assertion != "" {
		req.Header.Set(workerAssertHeader, assertion)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out ConsoleTicketResponse
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out, string(raw)
}

// ticketOpen follows the one-time link once: the redirect and the cookie set.
func ticketOpen(t *testing.T, h *ghHarness, path string) (string, *http.Cookie) {
	t.Helper()
	resp, err := noFollow.Get(h.http.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("GET %s = %d; want a redirect", path, resp.StatusCode)
	}
	for _, c := range resp.Cookies() {
		if c.Name == authz.CookieName && c.Value != "" {
			return resp.Header.Get("Location"), c
		}
	}
	return resp.Header.Get("Location"), nil
}

func ticketAudits(t *testing.T, h *ghHarness, action string) []string {
	t.Helper()
	rows, err := h.srv.Store.DB().Query(`SELECT outcome FROM fleet_audit WHERE action = ? ORDER BY id`, action)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var o string
		if err := rows.Scan(&o); err != nil {
			t.Fatal(err)
		}
		out = append(out, o)
	}
	return out
}

// alice's session gets a link; opened once it is alice's /app, read-only,
// and the second opening is nothing. Both ends are audited.
func TestConsoleTicketReadsAsTheOwner(t *testing.T) {
	h, _, _ := rolesHarness(t)
	alice := githubPrincipal(ghAlice.ID)
	tok, a := ticketNode(t, h, "alicebox-t", "alicebox", aliceLogin, "acct-b")

	code, tk, raw := ticketAsk(t, h, tok, a, map[string]any{"next": "/app/sessions"})
	if code != http.StatusOK || tk.Person != alice || !strings.HasPrefix(tk.Path, ConsoleTicketPath+"?t=") ||
		!strings.HasSuffix(tk.URL, tk.Path) || tk.TTLSec != int(consoleTicketSessionDef.Seconds()) {
		t.Fatalf("ticket = %d %s; want alice's link", code, raw)
	}
	loc, ro := ticketOpen(t, h, tk.Path)
	if loc != "/app/sessions" || ro == nil {
		t.Fatalf("open = %q %v; want /app/sessions and a cookie", loc, ro)
	}
	if loc, again := ticketOpen(t, h, tk.Path); again != nil || !strings.Contains(loc, "/signin") {
		t.Errorf("second open = %q %v; want the sign-in page, no cookie", loc, again)
	}

	_, b := viewAsDo(t, h, ro, http.MethodGet, "/v1/me", "")
	me := viewAsMe(t, b)
	if me.Person != alice || me.Role != roleUser || !me.ReadOnly || me.CanLogout || me.ViewAs != nil {
		t.Errorf("ticket /v1/me = %s; want alice, a member, read-only, no sign-out", b)
	}
	var rows []store.SessionRow
	_, b = viewAsDo(t, h, ro, http.MethodGet, "/v1/sessions?account=all&since="+rolesSince+"&until="+rolesUntil, "")
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	for _, r := range rows {
		if r.OSUser != aliceLogin {
			t.Errorf("ticket /v1/sessions has %+v; want alice's only", r)
		}
	}
	if iss := ticketAudits(t, h, "console_ticket"); len(iss) != 1 || !strings.HasPrefix(iss[0], "issued ct_") {
		t.Errorf("issue audit = %q; want one issued row", iss)
	}
	if use := ticketAudits(t, h, "console_ticket_used"); len(use) != 2 || !strings.HasPrefix(use[0], "OK read-only") ||
		use[1] != "refused:already used" {
		t.Errorf("use audit = %q; want OK then refused", use)
	}
}

// Every write the table holds answers 403 on a ticket's session, and so do
// the conversation and a websocket.
func TestConsoleTicketRefusesEveryWrite(t *testing.T) {
	h, _, _ := rolesHarness(t)
	tok, a := ticketNode(t, h, "alicebox-t", "alicebox", aliceLogin, "acct-b")
	_, tk, raw := ticketAsk(t, h, tok, a, nil)
	_, ro := ticketOpen(t, h, tk.Path)
	if ro == nil {
		t.Fatalf("no cookie: %s", raw)
	}
	patterns := make([]string, 0, len(routeAccess))
	for p, acc := range routeAccess {
		if acc == accessUser || acc == accessAdmin {
			patterns = append(patterns, p)
		}
	}
	sort.Strings(patterns)
	n := 0
	for _, p := range patterns {
		for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
			n++
			if code, b := viewAsDo(t, h, ro, m, p, ""); code != http.StatusForbidden || !strings.Contains(string(b), "只读票据") {
				t.Errorf("ticket %s %s = %d %s; want the read-only 403", m, p, code, b)
			}
		}
	}
	if n < 40 {
		t.Fatalf("walked %d writes; the table looks empty", n)
	}
	for _, p := range []string{ChatPathPrefix + "conversation", ChatPathPrefix + "turn", ChatPathPrefix + "file?ref=x", ChatPathPrefix + "takeover"} {
		if code, _ := viewAsDo(t, h, ro, http.MethodGet, p, ""); code != http.StatusForbidden {
			t.Errorf("ticket GET %s = %d; want 403", p, code)
		}
	}
	// a terminal session read along (task YP39): past the guard (the route's own
	// answer — here no such session — not the ticket's refusal)
	for _, p := range []string{ChatPathPrefix + "view?worker=x", ChatPathPrefix + "file?ref=x&worker=x"} {
		if code, b := viewAsDo(t, h, ro, http.MethodGet, p, ""); strings.Contains(string(b), "只读票据") {
			t.Errorf("ticket GET %s = %d %s; want past the read-only guard", p, code, b)
		}
	}
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/me", nil)
	req.Header.Set("Upgrade", "websocket")
	req.AddCookie(ro)
	if resp, err := noFollow.Do(req); err != nil || resp.StatusCode != http.StatusForbidden {
		t.Errorf("ticket upgrade = %v %v; want 403", resp, err)
	} else {
		resp.Body.Close()
	}
}

// An admin's ticket is a member's: no admin route, no view through anyone.
func TestConsoleTicketAdminIsAMember(t *testing.T) {
	h, _, _ := rolesHarness(t)
	ivan := githubPrincipal(ghAdmin.ID)
	p, err := h.srv.Store.Principal(ivan)
	if errors.Is(err, store.ErrNoPrincipal) {
		p, err = h.srv.Store.AdoptPrincipal(ivan, ghAdmin.Login, ghAdmin.Login, time.Now())
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mini", time.Now()); err != nil {
		t.Fatal(err)
	}
	tok, a := ticketNode(t, h, "mini-t", "mini", ghAdmin.Login, "acct-a")
	code, tk, raw := ticketAsk(t, h, tok, a, map[string]any{"next": "https://evil.example/app"})
	if code != http.StatusOK || tk.Person != ivan {
		t.Fatalf("admin ticket = %d %s", code, raw)
	}
	loc, ro := ticketOpen(t, h, tk.Path)
	if loc != AppPrefix || ro == nil {
		t.Fatalf("open = %q; want %s (never another site)", loc, AppPrefix)
	}
	_, b := viewAsDo(t, h, ro, http.MethodGet, "/v1/me", githubPrincipal(ghAlice.ID))
	if me := viewAsMe(t, b); me.Person != ivan || me.Role != roleUser || me.ViewAs != nil || !me.ReadOnly {
		t.Errorf("admin ticket /v1/me as alice = %s; want ivan himself, a member, read-only", b)
	}
	if code, _ := viewAsDo(t, h, ro, http.MethodGet, "/v1/usage?by=account", ""); code != http.StatusForbidden {
		t.Errorf("admin ticket /v1/usage by account = %d; want a member's 403", code)
	}
}

// No assertion, a login nobody owns, a forged or stale ticket: nothing.
func TestConsoleTicketRefusals(t *testing.T) {
	h, _, _ := rolesHarness(t)
	tok, a := ticketNode(t, h, "alicebox-t", "alicebox", aliceLogin, "acct-b")
	if code, _, raw := ticketAsk(t, h, tok, "", nil); code != http.StatusUnauthorized {
		t.Errorf("no assertion = %d %s; want 401", code, raw)
	}
	if code, _, raw := ticketAsk(t, h, "", a, nil); code != http.StatusUnauthorized {
		t.Errorf("no token = %d %s; want 401", code, raw)
	}
	if code, _, raw := ticketAsk(t, h, tok, a, map[string]any{"ttl_sec": 7200}); code != http.StatusBadRequest {
		t.Errorf("ttl 7200 = %d %s; want 400", code, raw)
	}
	other, oa := ticketNode(t, h, "stray-t", "straybox", "nobody", "acct-c")
	if code, _, raw := ticketAsk(t, h, other, oa, nil); code != http.StatusForbidden {
		t.Errorf("an unowned login = %d %s; want 403", code, raw)
	}
	_, tk, _ := ticketAsk(t, h, tok, a, nil)
	forged := tk.Path[:len(tk.Path)-2] + "xx"
	if loc, c := ticketOpen(t, h, forged); c != nil || !strings.Contains(loc, "/signin") {
		t.Errorf("forged = %q %v; want the sign-in page", loc, c)
	}
	q, _ := url.ParseQuery(strings.TrimPrefix(tk.Path, ConsoleTicketPath+"?"))
	cl, ok := h.srv.verifyConsoleTicket(q.Get("t"), time.Now())
	if !ok {
		t.Fatal("the hub's own ticket does not verify")
	}
	if _, ok := h.srv.verifyConsoleTicket(q.Get("t"), time.Unix(cl.Exp+1, 0)); ok {
		t.Error("a ticket past its two minutes still verifies")
	}
	// a ticket's session is no session to every other reader
	_, ro := ticketOpen(t, h, tk.Path)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/signin", nil)
	req.AddCookie(ro)
	if _, _, in := h.srv.personSession(req); in {
		t.Error("personSession takes a read-only ticket's cookie")
	}
	if _, _, in := h.srv.personSessionValue(ro.Value); in {
		t.Error("a read-only ticket's value works as a bearer")
	}
}
