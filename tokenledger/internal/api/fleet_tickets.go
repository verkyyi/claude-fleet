package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// FleetTicketRegisterPath is where a node registers a ticket it opened
// (claude-fleet#2676, EPIC #2668 C8): bin/fleet-ticket.sh new files a ticket on
// GitHub for a session with no code to change, then POSTs one row here with the
// node's own token. The hub keeps the registry row only — id · owner · title ·
// state · backend · url · origin session — never the body or the thread, which
// stay on GitHub. The owner is the person behind the calling login
// (principalOnNode); a login that is nobody's registers with no owner.
const FleetTicketRegisterPath = "/v1/fleet/tickets/register"

// The id grammar this batch reads: `gh:<owner>/<name>#<N>`. `hub:<N>` is
// reserved for the hub backend of the next batch and refused here.
var ticketIDRe = regexp.MustCompile(`^gh:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$`)

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
	t, msg := validTicket(req)
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
	row, err := s.Store.RegisterTicket(t, time.Now())
	if errors.Is(err, store.ErrTicketOwner) {
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
func validTicket(req FleetTicketRegisterRequest) (store.FleetTicket, string) {
	id := strings.TrimSpace(req.ID)
	if strings.HasPrefix(id, "hub:") {
		return store.FleetTicket{}, "hub:N tickets are reserved for the next batch; register gh:<owner>/<name>#<N>"
	}
	if !ticketIDRe.MatchString(id) {
		return store.FleetTicket{}, "id must be gh:<owner>/<name>#<N>"
	}
	backend := req.Backend
	if backend == "" {
		backend = "gh"
	}
	if backend != "gh" {
		return store.FleetTicket{}, "backend must be gh"
	}
	state := req.State
	if state == "" {
		state = "open"
	}
	if state != "open" && state != "closed" {
		return store.FleetTicket{}, "state must be open or closed"
	}
	title := strings.TrimSpace(req.Title)
	if title == "" || utf8.RuneCountInString(title) > 200 || strings.ContainsAny(title, "\r\n") {
		return store.FleetTicket{}, "title must be one line of 1–200 characters"
	}
	// The url is the ticket's own page on GitHub, nothing else.
	repoN := strings.TrimPrefix(id, "gh:")
	want := "https://github.com/" + strings.Replace(repoN, "#", "/issues/", 1)
	if req.URL != "" && !strings.EqualFold(req.URL, want) {
		return store.FleetTicket{}, "url must be " + want
	}
	origin := strings.TrimSpace(req.Origin)
	if utf8.RuneCountInString(origin) > 120 || strings.ContainsAny(origin, "\r\n\t") {
		return store.FleetTicket{}, "origin must be one short line"
	}
	return store.FleetTicket{ID: id, Title: title, State: state, Backend: backend, URL: want, Origin: origin}, ""
}
