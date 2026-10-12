package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Tickets whose home is the hub (claude-fleet#2677, EPIC #3570 C1): open one,
// read it, list them, comment, edit, claim, hang children on it — all without
// GitHub. A ticket is (repo, number), `hub:<repo>#<N>`; the hub numbers it.
//
//	POST  /v1/fleet/tickets                       {repo, title, body?, labels?, priority?,
//	                                               parent?, origin?, number? (an import)}
//	GET   /v1/fleet/tickets?repo=&state=&label=&parent=&since=&limit=
//	GET   /v1/fleet/tickets/<owner>/<name>/<N>    → {ticket, comments}
//	PATCH /v1/fleet/tickets/<owner>/<name>/<N>    {title?, body?, state?, state_reason?,
//	                                               labels?, priority?, parent?}
//	POST  /v1/fleet/tickets/<owner>/<name>/<N>/comments  {body, source?, marker?, author?}
//	POST  /v1/fleet/tickets/<owner>/<name>/<N>/claim     {by?, release?} — 409 + who
//	GET   /v1/fleet/tickets/<owner>/<name>/<N>/children
//	POST  /v1/fleet/tickets/<owner>/<name>/<N>/children  {child: owner/name#N, remove?}
//
// Who asks is a node's token (a session — its login's person owns what it
// opens, nodeTaskOwner as for task records) or a person's own sign-in (the
// web page); the operator's shared door sees every ticket, an admin's session
// too. Anyone else's ticket is 404, the same as no ticket (#2512's rule).
// Every comment, state change, claim and edit is pushed as a TypeTicket to the
// owner's connected nodes that listed CapTicket (pushTicket).
const (
	FleetTicketsPath = "/v1/fleet/tickets"
	// FleetTicketRegisterPath is #2676's registry road (bin/fleet-ticket.sh
	// new): a GitHub ticket a node opened, now written as a gh ticket here.
	// # compat-1v: 下一批删
	FleetTicketRegisterPath = "/v1/fleet/tickets/register"

	ticketBodyMax    = 64 << 10
	ticketTitleMax   = 200
	ticketLabelMax   = 50
	ticketLabelsMax  = 20
	ticketShortMax   = 200
	ticketRequestMax = ticketBodyMax + 16<<10
)

var (
	// The registry's id grammar: `gh:<owner>/<name>#<N>`.
	ticketIDRe       = regexp.MustCompile(`^gh:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$`)
	ticketRefRe      = regexp.MustCompile(`^([A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100})#([1-9][0-9]{0,9})$`)
	ticketPriorities = map[string]bool{"": true, "p0": true, "p1": true, "p2": true, "p3": true}
	ticketReasons    = map[string]bool{"": true, "completed": true, "not_planned": true, "duplicate": true, "reopened": true}
	ticketSources    = map[string]bool{"hub": true, "github": true, "fleet": true}
)

// ticketCaller is who is asking: whose tickets they own, whether they see
// everyone's, the name a comment of theirs carries.
type ticketCaller struct {
	owner, actor string
	all          bool
	node         bool
}

func (c ticketCaller) sees(t store.FleetTicket) bool {
	return c.all || (c.owner != "" && t.Owner == c.owner)
}

// ticketCallerOf resolves r: a node token first (a bearer that is one), then a
// person's session or the operator's door.
func (s *Server) ticketCallerOf(r *http.Request) (ticketCaller, bool) {
	if tok := bearer(r); tok != "" {
		if ep, err := s.Store.EndpointByTokenHash(HashToken(tok)); err == nil {
			host, user := s.peerSelf(ep)
			return ticketCaller{owner: s.nodeTaskOwner(ep), actor: "node:" + user + "@" + host, node: true}, true
		}
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	switch {
	case !ok:
		return ticketCaller{}, false
	case id.Admin:
		return ticketCaller{owner: id.Actor, actor: id.Actor, all: true}, true
	case id.Operator:
		return ticketCaller{owner: "operator", actor: "operator", all: true}, true
	}
	return ticketCaller{owner: id.Principal, actor: id.Principal}, true
}

// oneShort is s trimmed, refused ("", false) when it spans lines or is longer
// than n characters.
func oneShort(s string, n int) (string, bool) {
	s = strings.TrimSpace(s)
	return s, utf8.RuneCountInString(s) <= n && !strings.ContainsAny(s, "\r\n\t")
}

func checkTicketLabels(l []string) ([]string, string) {
	if len(l) > ticketLabelsMax {
		return nil, "at most 20 labels"
	}
	out := []string{}
	seen := map[string]bool{}
	for _, x := range l {
		x, ok := oneShort(x, ticketLabelMax)
		if !ok || x == "" || strings.ContainsAny(x, `"\,`) {
			return nil, "a label is one line of 1–50 characters, no quote, backslash or comma"
		}
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out, ""
}

// ticketParent normalizes a parent ref (owner/name#N, any hosted repo, on any
// backend), "" when it is not one.
func ticketParent(ref string) (string, bool) {
	m := ticketRefRe.FindStringSubmatch(strings.TrimSpace(ref))
	if m == nil {
		return "", false
	}
	return store.NormRepo(m[1]) + "#" + m[2], true
}

type ticketOpenReq struct {
	Repo     string   `json:"repo"`
	Title    string   `json:"title"`
	Body     string   `json:"body"`
	Labels   []string `json:"labels"`
	Priority string   `json:"priority"`
	Parent   string   `json:"parent"`
	Origin   string   `json:"origin"`
	Number   int64    `json:"number"`
}

type ticketPatch struct {
	Title       *string   `json:"title"`
	Body        *string   `json:"body"`
	State       *string   `json:"state"`
	StateReason *string   `json:"state_reason"`
	Labels      *[]string `json:"labels"`
	Priority    *string   `json:"priority"`
	Parent      *string   `json:"parent"`
}

func decodeTicket(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, ticketRequestMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object of the listed fields: "+err.Error())
		return false
	}
	return true
}

func (s *Server) handleFleetTickets(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.ticketCallerOf(r)
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a node token, a session or the viewer token is required")
		return
	}
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, FleetTicketsPath), "/")
	if rest == "" {
		switch r.Method {
		case http.MethodPost:
			s.ticketOpen(w, r, c)
		case http.MethodGet:
			s.ticketList(w, r, c)
		default:
			w.Header().Set("Allow", "GET, POST")
			httpError(w, http.StatusMethodNotAllowed, "GET (list) or POST (open)")
		}
		return
	}
	parts := strings.Split(rest, "/")
	if len(parts) < 3 || len(parts) > 4 || !leaseRepoRE.MatchString(parts[0]+"/"+parts[1]) {
		httpError(w, http.StatusNotFound, "a ticket is "+FleetTicketsPath+"/<owner>/<name>/<N>")
		return
	}
	n, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || n <= 0 || strconv.FormatInt(n, 10) != parts[2] {
		httpError(w, http.StatusNotFound, "a ticket number is a positive integer")
		return
	}
	t, err := s.Store.FleetTicketAt(parts[0]+"/"+parts[1], n)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !c.sees(t)) {
		httpError(w, http.StatusNotFound, "no such ticket of yours")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	sub := ""
	if len(parts) == 4 {
		sub = parts[3]
	}
	switch {
	case sub == "" && r.Method == http.MethodGet:
		cs, err := s.Store.TicketComments(t.Repo, t.Number)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ticket": t, "comments": cs})
	case sub == "" && r.Method == http.MethodPatch:
		s.ticketEdit(w, r, c, t)
	case sub == "comments" && r.Method == http.MethodPost:
		s.ticketComment(w, r, c, t)
	case sub == "comments" && r.Method == http.MethodGet:
		cs, err := s.Store.TicketComments(t.Repo, t.Number)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"comments": cs})
	case sub == "claim" && r.Method == http.MethodPost:
		s.ticketClaim(w, r, c, t)
	case sub == "children" && (r.Method == http.MethodGet || r.Method == http.MethodPost):
		s.ticketChildren(w, r, c, t)
	default:
		httpError(w, http.StatusMethodNotAllowed, "GET/PATCH a ticket; POST its comments or claim; GET/POST its children")
	}
}

func (s *Server) ticketOpen(w http.ResponseWriter, r *http.Request, c ticketCaller) {
	var in ticketOpenReq
	if !decodeTicket(w, r, &in) {
		return
	}
	if c.owner == "" {
		httpError(w, http.StatusForbidden, "this login belongs to no one, so a ticket it opened would be nobody's")
		return
	}
	title, ok := oneShort(in.Title, ticketTitleMax)
	origin, ok2 := oneShort(in.Origin, ticketShortMax/2)
	labels, why := checkTicketLabels(in.Labels)
	switch {
	case !leaseRepoRE.MatchString(in.Repo):
		why = "repo must be owner/name"
	case !ok || title == "":
		why = "title must be one line of 1–200 characters"
	case len(in.Body) > ticketBodyMax:
		why = "body is at most 64 KiB"
	case !ticketPriorities[in.Priority]:
		why = "priority must be p0, p1, p2 or p3"
	case !ok2:
		why = "origin must be one short line"
	case in.Number < 0:
		why = "number, when given, is a positive integer"
	}
	parent := ""
	if why == "" && in.Parent != "" {
		if parent, ok = ticketParent(in.Parent); !ok {
			why = "parent must be owner/name#N"
		}
	}
	if why != "" {
		httpError(w, http.StatusBadRequest, why)
		return
	}
	t, err := s.Store.CreateFleetTicket(store.FleetTicket{Repo: in.Repo, Owner: c.owner, Title: title, Body: in.Body,
		Labels: labels, Priority: in.Priority, Parent: parent, Origin: origin}, in.Number, time.Now())
	if errors.Is(err, store.ErrTicketTaken) {
		httpError(w, http.StatusConflict, err.Error())
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, t)
}

func (s *Server) ticketList(w http.ResponseWriter, r *http.Request, c ticketCaller) {
	q := r.URL.Query()
	f := store.TicketFilter{Owner: c.owner, Repo: q.Get("repo"), State: q.Get("state"), Label: q.Get("label")}
	if c.all {
		f.Owner, f.All = "", q.Get("mine") == ""
		if !f.All {
			f.Owner = c.owner
		}
	}
	f.Limit, _ = strconv.Atoi(q.Get("limit"))
	if f.Repo != "" && !leaseRepoRE.MatchString(f.Repo) {
		httpError(w, http.StatusBadRequest, "repo must be owner/name")
		return
	}
	if f.State != "" && f.State != "open" && f.State != "closed" {
		httpError(w, http.StatusBadRequest, "state must be open or closed")
		return
	}
	if p := q.Get("parent"); p != "" {
		var ok bool
		if f.Parent, ok = ticketParent(p); !ok {
			httpError(w, http.StatusBadRequest, "parent must be owner/name#N")
			return
		}
	}
	if v := q.Get("since"); v != "" {
		ts, err := time.Parse(time.RFC3339, v)
		if err != nil {
			httpError(w, http.StatusBadRequest, "since is an RFC 3339 time")
			return
		}
		f.Since = ts
	}
	ts, err := s.Store.FleetTickets(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tickets": ts, "observed_at": time.Now().UTC().Format(time.RFC3339)})
}

func (s *Server) ticketEdit(w http.ResponseWriter, r *http.Request, c ticketCaller, t store.FleetTicket) {
	var in ticketPatch
	if !decodeTicket(w, r, &in) {
		return
	}
	if t.Backend != store.TicketHub {
		httpError(w, http.StatusConflict, "a GitHub ticket is edited on GitHub")
		return
	}
	e := store.TicketEdit{Body: in.Body, Priority: in.Priority, StateReason: in.StateReason}
	why := ""
	if in.Title != nil {
		title, ok := oneShort(*in.Title, ticketTitleMax)
		if !ok || title == "" {
			why = "title must be one line of 1–200 characters"
		}
		e.Title = &title
	}
	switch {
	case in.Body != nil && len(*in.Body) > ticketBodyMax:
		why = "body is at most 64 KiB"
	case in.State != nil && *in.State != "open" && *in.State != "closed":
		why = "state must be open or closed"
	case in.StateReason != nil && !ticketReasons[*in.StateReason]:
		why = "state_reason must be completed, not_planned, duplicate or reopened"
	case in.Priority != nil && !ticketPriorities[*in.Priority]:
		why = "priority must be p0, p1, p2 or p3"
	}
	if in.Labels != nil {
		l, msg := checkTicketLabels(*in.Labels)
		if msg != "" {
			why = msg
		}
		e.Labels = &l
	}
	if in.Parent != nil {
		p := ""
		if strings.TrimSpace(*in.Parent) != "" {
			var ok bool
			if p, ok = ticketParent(*in.Parent); !ok {
				why = "parent must be owner/name#N, or empty to take it off"
			}
		}
		e.Parent = &p
	}
	if why != "" {
		httpError(w, http.StatusBadRequest, why)
		return
	}
	kind := "edit"
	if in.State != nil && *in.State != t.State {
		kind = "state"
		e.State = in.State
		if in.StateReason == nil {
			// a reopen or a close with no word: the old reason no longer says why
			reason := map[string]string{"open": "reopened", "closed": "completed"}[*in.State]
			e.StateReason = &reason
		}
	}
	out, err := s.Store.EditFleetTicket(t.Repo, t.Number, e, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.pushTicket(out.Owner, control.Ticket{Repo: out.Repo, Number: out.Number, Kind: kind})
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) ticketComment(w http.ResponseWriter, r *http.Request, c ticketCaller, t store.FleetTicket) {
	var in struct {
		Body   string `json:"body"`
		Source string `json:"source"`
		Marker string `json:"marker"`
		Author string `json:"author"`
	}
	if !decodeTicket(w, r, &in) {
		return
	}
	if t.Backend != store.TicketHub {
		httpError(w, http.StatusConflict, "a GitHub ticket's thread is on GitHub")
		return
	}
	marker, ok := oneShort(in.Marker, ticketShortMax)
	author, ok2 := oneShort(in.Author, ticketShortMax/2)
	switch {
	case strings.TrimSpace(in.Body) == "" || len(in.Body) > ticketBodyMax:
		httpError(w, http.StatusBadRequest, "body is 1 byte to 64 KiB")
		return
	case !ok || !ok2:
		httpError(w, http.StatusBadRequest, "marker and author are one short line each")
		return
	case in.Source != "" && !ticketSources[in.Source]:
		httpError(w, http.StatusBadRequest, "source must be hub, github or fleet")
		return
	}
	// A person writes as themself, from the page; a node names the session
	// it writes for (author) and where the words came from (source).
	src, who := "hub", c.actor
	if c.node {
		if in.Source != "" {
			src = in.Source
		}
		if author != "" {
			who = author + " (" + c.actor + ")"
		}
	}
	cm, err := s.addTicketComment(t, who, in.Body, src, marker)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, cm)
}

// addTicketComment writes one comment on hub ticket t and tells the owner's
// machines (the JSON road and the tickets page share it): the session doing
// the ticket reads it on its next turn.
func (s *Server) addTicketComment(t store.FleetTicket, author, body, source, marker string) (store.TicketComment, error) {
	cm, err := s.Store.AddTicketComment(store.TicketComment{Repo: t.Repo, Number: t.Number, Author: author, Body: body,
		Source: source, Marker: marker}, time.Now())
	if err != nil {
		return cm, err
	}
	s.pushTicket(t.Owner, control.Ticket{Repo: t.Repo, Number: t.Number, Kind: "comment", CommentID: cm.ID})
	return cm, nil
}

func (s *Server) ticketClaim(w http.ResponseWriter, r *http.Request, c ticketCaller, t store.FleetTicket) {
	var in struct {
		By      string `json:"by"`
		Release bool   `json:"release"`
	}
	if r.ContentLength != 0 && !decodeTicket(w, r, &in) {
		return
	}
	by, ok := oneShort(in.By, ticketShortMax)
	if !ok {
		httpError(w, http.StatusBadRequest, "by is one short line: the session or person taking it")
		return
	}
	if by == "" {
		by = c.actor
	}
	out, holder, err := s.Store.ClaimFleetTicket(t.Repo, t.Number, by, in.Release, time.Now())
	if errors.Is(err, store.ErrTicketClaimed) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error(), "assignee": holder,
			"claimed_at": out.ClaimedAt})
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if out.Assignee != t.Assignee {
		s.pushTicket(out.Owner, control.Ticket{Repo: out.Repo, Number: out.Number, Kind: "claim"})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) ticketChildren(w http.ResponseWriter, r *http.Request, c ticketCaller, t store.FleetTicket) {
	ref := t.Repo + "#" + strconv.FormatInt(t.Number, 10)
	if r.Method == http.MethodPost {
		var in struct {
			Child  string `json:"child"`
			Remove bool   `json:"remove"`
		}
		if !decodeTicket(w, r, &in) {
			return
		}
		m := ticketRefRe.FindStringSubmatch(strings.TrimSpace(in.Child))
		if m == nil {
			httpError(w, http.StatusBadRequest, "child must be owner/name#N")
			return
		}
		cn, _ := strconv.ParseInt(m[2], 10, 64)
		child, err := s.Store.FleetTicketAt(m[1], cn)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && !c.sees(child)) {
			httpError(w, http.StatusNotFound, "no such ticket of yours: "+in.Child)
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if child.Repo == t.Repo && child.Number == t.Number {
			httpError(w, http.StatusBadRequest, "a ticket is not its own child")
			return
		}
		p := ref
		if in.Remove {
			if child.Parent != ref {
				writeJSON(w, http.StatusOK, child)
				return
			}
			p = ""
		}
		out, err := s.Store.EditFleetTicket(child.Repo, child.Number, store.TicketEdit{Parent: &p}, time.Now())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.pushTicket(out.Owner, control.Ticket{Repo: out.Repo, Number: out.Number, Kind: "edit"})
		writeJSON(w, http.StatusOK, out)
		return
	}
	f := store.TicketFilter{Owner: c.owner, All: c.all, Parent: ref, Limit: 500}
	if c.all {
		f.Owner = ""
	}
	ts, err := s.Store.FleetTickets(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"parent": ref, "children": ts})
}

// pushTicket tells every connected node of owner that listed CapTicket that
// one of their tickets moved — and no one else's node. A ticket of nobody's
// (owner "") is pushed nowhere. A failed write is dropped: the node reads the
// ticket by number when it next looks.
func (s *Server) pushTicket(owner string, ev control.Ticket) {
	if owner == "" {
		return
	}
	msg, err := control.New(control.TypeTicket, ev)
	if err != nil {
		return
	}
	s.nodes.each(func(id string, nc *nodeConn) {
		if !nc.canTicket {
			return
		}
		go func() {
			ep, err := s.Store.EndpointByID(id)
			if err != nil || ep == nil || s.nodeTaskOwner(ep) != owner {
				return
			}
			wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if s.nodes.get(id) != nc {
				return
			}
			_ = s.SendNodeWrite(wctx, id, msg)
		}()
	})
}

// --- the registry of #2676, one version (# compat-1v: 下一批删) ------------

// FleetTicketRegisterRequest is the body: the registry fields, nothing else.
type FleetTicketRegisterRequest struct {
	ID      string `json:"id"`
	Backend string `json:"backend"`
	Title   string `json:"title"`
	State   string `json:"state"`
	URL     string `json:"url"`
	Origin  string `json:"origin"`
}

func (s *Server) handleFleetTicketRegister(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST {id, backend, title, state, url, origin}")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	var req FleetTicketRegisterRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	dec.DisallowUnknownFields() // the registry fields only — a body or a thread is refused
	if err := dec.Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "body must be {id, backend, title, state, url, origin}: "+err.Error())
		return
	}
	id, t, msg := validTicket(req)
	if msg != "" {
		httpError(w, http.StatusBadRequest, msg)
		return
	}
	host, user := s.nodeIdentity(ep)
	owner, err := s.principalOnNode(ep.ID, host, user)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	t.Owner, t.EndpointID = owner, ep.ID
	row, err := s.Store.RegisterTicket(id, t, time.Now())
	if errors.Is(err, store.ErrTicketOwner) || errors.Is(err, store.ErrTicketTaken) {
		httpError(w, http.StatusConflict, err.Error())
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, row)
}

// validTicket checks the registry fields; a non-empty message is the refusal.
func validTicket(req FleetTicketRegisterRequest) (string, store.FleetTicket, string) {
	id := strings.TrimSpace(req.ID)
	if strings.HasPrefix(id, "hub:") {
		return "", store.FleetTicket{}, "a hub ticket is opened with POST " + FleetTicketsPath + "; register gh:<owner>/<name>#<N>"
	}
	if !ticketIDRe.MatchString(id) {
		return "", store.FleetTicket{}, "id must be gh:<owner>/<name>#<N>"
	}
	backend := req.Backend
	if backend == "" {
		backend = "gh"
	}
	if backend != "gh" {
		return "", store.FleetTicket{}, "backend must be gh"
	}
	state := req.State
	if state == "" {
		state = "open"
	}
	if state != "open" && state != "closed" {
		return "", store.FleetTicket{}, "state must be open or closed"
	}
	title := strings.TrimSpace(req.Title)
	if title == "" || utf8.RuneCountInString(title) > 200 || strings.ContainsAny(title, "\r\n") {
		return "", store.FleetTicket{}, "title must be one line of 1–200 characters"
	}
	// The url is the ticket's own page on GitHub, nothing else.
	repoN := strings.TrimPrefix(id, "gh:")
	want := "https://github.com/" + strings.Replace(repoN, "#", "/issues/", 1)
	if req.URL != "" && !strings.EqualFold(req.URL, want) {
		return "", store.FleetTicket{}, "url must be " + want
	}
	origin := strings.TrimSpace(req.Origin)
	if utf8.RuneCountInString(origin) > 120 || strings.ContainsAny(origin, "\r\n\t") {
		return "", store.FleetTicket{}, "origin must be one short line"
	}
	return id, store.FleetTicket{Title: title, State: state, URL: want, Origin: origin}, ""
}
