package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The ticket registry (claude-fleet#2676): a node registers a ticket it opened
// with its own token; the row carries the person behind the login, re-registering
// refreshes it, another person's id is refused, and nothing but the registry
// fields is taken. Since #2677 the row is a gh ticket in fleet_tickets.
func TestFleetTicketRegister(t *testing.T) {
	h, tok5, tok4, _, _ := sessHarness(t)
	reg := func(tok string, body map[string]any) (int, map[string]any) {
		t.Helper()
		return sessDo(t, h, http.MethodPost, FleetTicketRegisterPath, tok, "", body)
	}
	row := map[string]any{"id": "gh:verkyyi/claude-fleet#2700", "backend": "gh", "title": "写设计页（编排架构）",
		"state": "open", "url": "https://github.com/verkyyi/claude-fleet/issues/2700", "origin": "orchestrator"}
	st, out := reg(tok5, row)
	if st != http.StatusCreated || out["owner"] != "gh:1005" || out["title"] != "写设计页（编排架构）" || out["origin"] != "orchestrator" ||
		out["id"] != "gh:verkyyi/claude-fleet#2700" {
		t.Fatalf("register: %d %v", st, out)
	}
	// a re-register is the same row, refreshed
	row["state"] = "closed"
	if st, out = reg(tok5, row); st != http.StatusCreated || out["state"] != "closed" {
		t.Fatalf("re-register: %d %v", st, out)
	}
	list, err := h.srv.Store.FleetTickets(store.TicketFilter{Owner: "gh:1005"})
	if err != nil || len(list) != 1 || list[0].State != "closed" || list[0].EndpointID != "ep_m5" || list[0].Backend != store.TicketGitHub {
		t.Fatalf("the person's list: %v %v", list, err)
	}
	// m4's login is nobody's: registered with no owner — and it cannot take m5's id
	if st, out = reg(tok4, row); st != http.StatusConflict {
		t.Fatalf("another person's id: %d %v", st, out)
	}
	other := map[string]any{"id": "gh:verkyyi/claude-fleet#2701", "title": "调研", "url": "https://github.com/verkyyi/claude-fleet/issues/2701"}
	if st, out = reg(tok4, other); st != http.StatusCreated || out["owner"] != "" || out["state"] != "open" || out["backend"] != "gh" {
		t.Fatalf("a login with no person: %d %v", st, out)
	}
	for name, bad := range map[string]map[string]any{
		"hub tickets are opened": {"id": "hub:7", "title": "x"},
		"not an id":              {"id": "verkyyi/claude-fleet#7", "title": "x"},
		"body is refused":        {"id": "gh:a/b#7", "title": "x", "body": "the whole thread"},
		"another page":           {"id": "gh:a/b#7", "title": "x", "url": "https://evil.example/a/b/issues/7"},
		"two-line title":         {"id": "gh:a/b#7", "title": "x\ny"},
		"no title":               {"id": "gh:a/b#7"},
		"state":                  {"id": "gh:a/b#7", "title": "x", "state": "merged"},
	} {
		if st, out := reg(tok5, bad); st != http.StatusBadRequest {
			t.Fatalf("%s: %d %v", name, st, out)
		}
	}
	if st, _ := reg("not-a-token", row); st != http.StatusUnauthorized {
		t.Fatalf("no node token → %d", st)
	}
	if st, _ := sessDo(t, h, http.MethodGet, FleetTicketRegisterPath, tok5, "", nil); st != http.StatusMethodNotAllowed {
		t.Fatalf("GET → %d", st)
	}
}

// ticketCall is one request to the ticket road with auth (a bearer).
func ticketCall(t *testing.T, h *harness, auth func(http.Header), method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	if auth != nil {
		auth(req.Header)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if out == nil {
		out = map[string]any{"raw": string(raw)}
	}
	return res.StatusCode, out
}

// ticketHarness: Alice on macmini + macmini-m4, Bob on macmini-m4, verk the
// operator's admin login; each node with the caps given.
func ticketHarness(t *testing.T, caps ...string) (*harness, map[string]*fleetNode) {
	t.Helper()
	h, _ := certHarness(t)
	h.srv.FleetAdmins = []string{"verk"}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "macmini-m4", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	return h, map[string]*fleetNode{
		"alice5": personNode(t, h, "alice5", "macmini", "alice", caps...),
		"alice4": personNode(t, h, "alice4", "macmini-m4", "alice"), // never says CapTicket
		"bob4":   personNode(t, h, "bob4", "macmini-m4", "bob", caps...),
	}
}

// The completion criterion's road: open a ticket, comment on it, claim it,
// close it, hang a child on it — all on the hub, no GitHub — and another
// person can neither read nor write it.
func TestTicketRoad(t *testing.T) {
	h, n := ticketHarness(t)
	bob, alice := asNode(n["bob4"].token), asNode(n["alice4"].token)
	const repo = "verkyyi/notes"
	path := FleetTicketsPath + "/" + repo + "/1"

	st, tk := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath, map[string]any{"repo": "Verkyyi/Notes",
		"title": "续费域名", "body": "到期前一周续。", "labels": []string{"ops", "ops", "钱"}, "priority": "p1", "origin": "scratch-4"})
	if st != 201 || tk["id"] != "hub:"+repo+"#1" || tk["owner"] != pBob || tk["state"] != "open" || tk["body"] != "到期前一周续。" ||
		len(tk["labels"].([]any)) != 2 || tk["priority"] != "p1" || tk["backend"] != "hub" {
		t.Fatalf("open: %d %v", st, tk)
	}
	if st, tk := ticketCall(t, h, asSession(pBob), http.MethodPost, FleetTicketsPath, map[string]any{"repo": repo, "title": "第二张"}); st != 201 || tk["number"] != float64(2) || tk["owner"] != pBob {
		t.Fatalf("open from the page: %d %v", st, tk)
	}

	// another person: 404 on every verb, from the page or a node
	for _, who := range []func(http.Header){alice, asSession(pAlice)} {
		for _, c := range []struct {
			m, p string
			b    any
		}{{http.MethodGet, path, nil}, {http.MethodPatch, path, map[string]any{"state": "closed"}},
			{http.MethodPost, path + "/comments", map[string]any{"body": "x"}}, {http.MethodPost, path + "/claim", map[string]any{}},
			{http.MethodGet, path + "/children", nil}} {
			if st, out := ticketCall(t, h, who, c.m, c.p, c.b); st != 404 {
				t.Fatalf("another person %s %s: %d %v", c.m, c.p, st, out)
			}
		}
	}
	if st, out := ticketCall(t, h, asSession(pAlice), http.MethodGet, FleetTicketsPath, nil); st != 200 || len(out["tickets"].([]any)) != 0 {
		t.Fatalf("Alice's list: %d %v", st, out)
	}

	// comments: a session names itself, the page writes as the person
	if st, c := ticketCall(t, h, bob, http.MethodPost, path+"/comments", map[string]any{"body": "已提醒", "author": "issue-9",
		"source": "fleet", "marker": "<!-- fleet:x -->"}); st != 201 || c["source"] != "fleet" || c["author"] != "issue-9 (node:bob@macmini-m4)" {
		t.Fatalf("a node's comment: %d %v", st, c)
	}
	if st, c := ticketCall(t, h, asSession(pBob), http.MethodPost, path+"/comments", map[string]any{"body": "好", "source": "fleet"}); st != 201 || c["author"] != pBob || c["source"] != "hub" {
		t.Fatalf("the page's comment: %d %v", st, c)
	}

	// claim: one holder; a second claimer is told who
	if st, c := ticketCall(t, h, bob, http.MethodPost, path+"/claim", map[string]any{"by": "worker-a"}); st != 200 || c["assignee"] != "worker-a" {
		t.Fatalf("claim: %d %v", st, c)
	}
	if st, c := ticketCall(t, h, asSession(pBob), http.MethodPost, path+"/claim", map[string]any{"by": "worker-b"}); st != 409 || c["assignee"] != "worker-a" {
		t.Fatalf("a second claim: %d %v", st, c)
	}
	if st, c := ticketCall(t, h, bob, http.MethodPost, path+"/claim", map[string]any{"by": "worker-a"}); st != 200 || c["assignee"] != "worker-a" {
		t.Fatalf("the holder again: %d %v", st, c)
	}
	if st, c := ticketCall(t, h, bob, http.MethodPost, path+"/claim", map[string]any{"by": "worker-a", "release": true}); st != 200 || c["assignee"] != nil {
		t.Fatalf("release: %d %v", st, c)
	}

	// close, with the reason filled in
	if st, c := ticketCall(t, h, bob, http.MethodPatch, path, map[string]any{"state": "closed"}); st != 200 || c["state"] != "closed" || c["state_reason"] != "completed" {
		t.Fatalf("close: %d %v", st, c)
	}

	// a child hangs on it (a batch and its member)
	if st, c := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath+"/"+repo+"/2/children", map[string]any{"child": repo + "#1"}); st != 200 || c["parent"] != repo+"#2" {
		t.Fatalf("hang #1 on #2: %d %v", st, c)
	}
	if st, c := ticketCall(t, h, bob, http.MethodGet, FleetTicketsPath+"/"+repo+"/2/children", nil); st != 200 || len(c["children"].([]any)) != 1 {
		t.Fatalf("children: %d %v", st, c)
	}

	// read it back: the whole ticket and its thread
	st, got := ticketCall(t, h, asSession(pBob), http.MethodGet, path, nil)
	if tk, _ := got["ticket"].(map[string]any); st != 200 || tk["state"] != "closed" || tk["parent"] != repo+"#2" || len(got["comments"].([]any)) != 2 {
		t.Fatalf("read: %d %v", st, got)
	}
	if st, out := ticketCall(t, h, bob, http.MethodGet, FleetTicketsPath+"?repo="+repo+"&state=open", nil); st != 200 || len(out["tickets"].([]any)) != 1 {
		t.Fatalf("open ones: %d %v", st, out)
	}
	if st, out := ticketCall(t, h, bob, http.MethodGet, FleetTicketsPath+"?label=ops", nil); st != 200 || len(out["tickets"].([]any)) != 1 {
		t.Fatalf("by label: %d %v", st, out)
	}
	// the operator's door sees everyone's
	op := func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+viewerToken) }
	if st, out := ticketCall(t, h, op, http.MethodGet, path, nil); st != 200 || out["ticket"] == nil {
		t.Fatalf("operator: %d %v", st, out)
	}

	for name, bad := range map[string]map[string]any{
		"repo":          {"repo": "notes", "title": "x"},
		"two lines":     {"repo": repo, "title": "x\ny"},
		"no title":      {"repo": repo},
		"priority":      {"repo": repo, "title": "x", "priority": "p9"},
		"label":         {"repo": repo, "title": "x", "labels": []string{`a"b`}},
		"parent":        {"repo": repo, "title": "x", "parent": "7"},
		"unknown field": {"repo": repo, "title": "x", "assignee": "me"},
	} {
		if st, out := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath, bad); st != 400 {
			t.Fatalf("%s: %d %v", name, st, out)
		}
	}
	if st, _ := ticketCall(t, h, asNode("nope"), http.MethodGet, FleetTicketsPath, nil); st != 401 {
		t.Fatalf("no credential: %d", st)
	}
}

// nextTicket wants a TypeTicket within two seconds, skipping anything else.
func nextTicket(t *testing.T, n *fleetNode, what string) control.Ticket {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		m, ok := readMsg(n.tnode, time.Until(deadline))
		if !ok {
			break
		}
		if m.Type == control.TypeTicket {
			var tk control.Ticket
			_ = json.Unmarshal(m.Payload, &tk)
			return tk
		}
	}
	t.Fatalf("%s: no ticket message", what)
	return control.Ticket{}
}

// noTicket wants no TypeTicket for a moment.
func noTicket(t *testing.T, n *fleetNode, what string) {
	t.Helper()
	deadline := time.Now().Add(400 * time.Millisecond)
	for time.Now().Before(deadline) {
		m, ok := readMsg(n.tnode, time.Until(deadline))
		if !ok {
			return
		}
		if m.Type == control.TypeTicket {
			t.Fatalf("%s: got ticket %s, want none", what, m.Payload)
		}
	}
}

// A comment, a close and a claim reach the owner's machines that follow
// tickets — at once, naming the ticket and never its words — and nobody else's.
func TestTicketPushOwnerOnly(t *testing.T) {
	h, n := ticketHarness(t, control.CapTicket)
	bob := asNode(n["bob4"].token)
	if st, out := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath, map[string]any{"repo": "verkyyi/notes", "title": "x"}); st != 201 {
		t.Fatalf("open: %d %v", st, out)
	}
	noTicket(t, n["bob4"], "opening is not a change to push")
	st, c := ticketCall(t, h, asSession(pBob), http.MethodPost, FleetTicketsPath+"/verkyyi/notes/1/comments", map[string]any{"body": "秘密的话"})
	if st != 201 {
		t.Fatalf("comment: %d %v", st, c)
	}
	ev := nextTicket(t, n["bob4"], "Bob's machine")
	if ev.Repo != "verkyyi/notes" || ev.Number != 1 || ev.Kind != "comment" || ev.CommentID != int64(c["id"].(float64)) {
		t.Fatalf("event %+v", ev)
	}
	noTicket(t, n["alice5"], "Alice's machine after Bob's comment")
	if st, _ := ticketCall(t, h, bob, http.MethodPatch, FleetTicketsPath+"/verkyyi/notes/1", map[string]any{"state": "closed"}); st != 200 {
		t.Fatalf("close: %d", st)
	}
	if ev := nextTicket(t, n["bob4"], "close"); ev.Kind != "state" {
		t.Fatalf("close event %+v", ev)
	}

	// Alice's are Alice's: her following machine hears, her other one never
	// said CapTicket, Bob's hears nothing.
	if st, out := ticketCall(t, h, asSession(pAlice), http.MethodPost, FleetTicketsPath, map[string]any{"repo": "alice/home", "title": "y"}); st != 201 {
		t.Fatalf("Alice opens: %d %v", st, out)
	}
	if st, _ := ticketCall(t, h, asNode(n["alice4"].token), http.MethodPost, FleetTicketsPath+"/alice/home/1/claim", map[string]any{"by": "issue-3"}); st != 200 {
		t.Fatalf("Alice claims: %d", st)
	}
	if ev := nextTicket(t, n["alice5"], "Alice's machine"); ev.Kind != "claim" || ev.Repo != "alice/home" {
		t.Fatalf("Alice's event %+v", ev)
	}
	noTicket(t, n["alice4"], "a machine without CapTicket")
	noTicket(t, n["bob4"], "Bob's machine after Alice's claim")
}

// Off: nobody uses tickets ⇒ nothing beyond the tables — no row, no number
// handed out, no message to any node, and the list answers empty.
func TestTicketsOffAddsNothing(t *testing.T) {
	h, n := ticketHarness(t, control.CapTicket)
	beat(t, n["bob4"].c, control.Proto, control.Heartbeat{Hostname: "macmini-m4", OSUser: "bob"})
	for k, node := range n {
		noTicket(t, node, k+" with no ticket anywhere")
	}
	if st, out := ticketCall(t, h, asSession(pBob), http.MethodGet, FleetTicketsPath, nil); st != 200 || len(out["tickets"].([]any)) != 0 {
		t.Fatalf("list: %d %v", st, out)
	}
	all, err := h.srv.Store.FleetTickets(store.TicketFilter{All: true})
	if err != nil || len(all) != 0 {
		t.Fatalf("rows: %v %v", all, err)
	}
	var seq int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_ticket_seq`).Scan(&seq); err != nil || seq != 0 {
		t.Fatalf("numbers handed out: %d %v", seq, err)
	}
}
