package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The personal configuration (claude-fleet#1856, EPIC #1855 C1).
//
// The team layer's twin, one per person (principal): what a member wants in
// every session on every computer they work from. Every computer composes
// default < team < personal < local (bin/fleet-agent-team.py); this file
// only keeps the layer.
//
//   GET  /v1/fleet/person-bundle[?version=N][&history=1]
//        the caller's OWN layer: a person's session, a node's enrollment
//        token (the person its login is bound to, PrincipalForLogin), or
//        POST {cert, sig, ts} by a connection certificate. The operator's
//        doors read anyone's with ?principal=<id>. ETag
//        "person-<pid8>-v<N>"; If-None-Match answers 304.
//   GET  /roles?merged=1   the same caller's layer merged into the stable
//        tree's role definitions and rule table (claude-fleet#2787) — what
//        `fleet role show --sources` prints; fleet_person_roles_view.go.
//   GET  ?all=1   the operator's alone (claude-fleet#1866): every person's
//        current version, updated time and item count — a summary, never a
//        body; reading one stays ?principal=<id>&version=N.
//   PUT  {bundle, base?, note?} | {restore: N, base?, note?}
//        the person's own — session, node token or the same signed body;
//        an admin's session on their own layer too (claude-fleet#2515).
//        Someone else's (?principal= naming another) is 403. The operator
//        may only {restore: N}: put one of the person's own versions back,
//        never new content, and the audit names the operator.
//
// A login bound to no person has no personal layer: 404 "no person for this
// login". The body rules are the team's (validateBundle), plus hook_scripts.

// personETag tags a person's version without spelling their id.
func personETag(principal string, v int) string {
	sum := sha256.Sum256([]byte(principal))
	return fmt.Sprintf(`"person-%s-v%d"`, hex.EncodeToString(sum[:])[:8], v)
}

// personCaller is who is asking and whose layer it is.
type personCaller struct {
	id sshRelayIdentity
	// person is the canonical principal whose layer the call is on.
	person string
}

// handleFleetPersonBundle serves control.PersonBundlePath. Like the team
// layer, it authenticates itself: a node and a client-only computer call it.
func (s *Server) handleFleetPersonBundle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	if strings.HasSuffix(r.URL.Path, "/roles") && r.Method != http.MethodGet {
		// The merged view is read-only: a change is a PUT of the layer itself.
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only — a change is a PUT of "+control.PersonBundlePath)
		return
	}
	var req TeamBundleRequest
	if r.Method == http.MethodPost || r.Method == http.MethodPut {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, teamBundleMax+4096)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "body must be JSON")
			return
		}
	}
	if r.Method != http.MethodGet && r.Method != http.MethodPost && r.Method != http.MethodPut {
		w.Header().Set("Allow", "GET, POST, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET, POST (certificate read) or PUT")
		return
	}
	// A signed body speaks for its certificate's person, whatever other
	// door the request also came through.
	var id sshRelayIdentity
	var self string // the caller's own principal, "" for the operator
	ok := false
	if req.Cert != "" && req.Sig != "" {
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		cid, err := s.verifySSHRelayCert(req.Cert, req.Sig, control.PersonBundleSigMessage(req.TS), control.PersonBundleSigNamespace, now)
		if err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		id, self, ok = sshRelayIdentity{Principal: cid.Principal, Actor: cid.Actor}, cid.Principal, true
	}
	if !ok {
		id, ok = s.sshRelayHTTPIdentity(r)
		self = id.Principal
	}
	if !ok {
		if tok := bearer(r); tok != "" {
			if ep, err := s.Store.EndpointByTokenHash(HashToken(tok)); err == nil {
				host, user := s.peerSelf(ep)
				id, ok = sshRelayIdentity{Actor: "node:" + user + "@" + host}, true
				owner, err := s.Store.PrincipalForLogin(host, user)
				switch {
				case errors.Is(err, store.ErrNoPrincipal) || (err == nil && owner == ""):
					httpError(w, http.StatusNotFound, "no person for this login")
					return
				case err != nil:
					httpError(w, http.StatusInternalServerError, err.Error())
					return
				}
				self = owner
			}
		}
	}
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a session, a viewer token, a node token or a connection certificate is required")
		return
	}

	if r.URL.Query().Get("all") != "" {
		if !id.Operator || r.Method != http.MethodGet {
			httpError(w, http.StatusForbidden, "every person's versions are the operator's view")
			return
		}
		s.writePersonBundlePeople(w)
		return
	}

	// Whose layer: the caller's own; the operator names one.
	want := strings.TrimSpace(r.URL.Query().Get("principal"))
	if id.Admin && (want == "" || strings.EqualFold(want, id.Actor)) {
		// An admin's own layer is theirs as anyone's is: read it, import into
		// it (claude-fleet#2515, #2521). Naming another person stays the
		// operator's restore-only reach.
		id.Operator, id.Principal, self = false, id.Actor, id.Actor
	}
	target := self
	if id.Operator {
		if want == "" {
			httpError(w, http.StatusBadRequest, "the operator names the person: ?principal=<id>")
			return
		}
		target = want
	}
	if target == "" {
		httpError(w, http.StatusNotFound, "no person for this login")
		return
	}
	p, err := s.Store.Principal(target)
	switch {
	case errors.Is(err, store.ErrNoPrincipal):
		if id.Operator {
			httpError(w, http.StatusNotFound, fmt.Sprintf("the hub knows no person %q", target))
		} else {
			httpError(w, http.StatusNotFound, "no person for this login")
		}
		return
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !id.Operator {
		// The caller's own spelling may differ in case; the row's is canonical.
		if want != "" {
			if q, err := s.Store.Principal(want); err != nil || q.ID != p.ID {
				s.personAudit(id.Actor, want, "FORBIDDEN", now)
				httpError(w, http.StatusForbidden, "a personal configuration is its owner's alone")
				return
			}
		}
	}
	c := personCaller{id: id, person: p.ID}

	if strings.HasSuffix(r.URL.Path, "/roles") {
		s.writePersonRoles(w, c.person)
		return
	}
	switch r.Method {
	case http.MethodGet, http.MethodPost:
		v, _ := strconv.Atoi(r.URL.Query().Get("version"))
		s.writePersonBundle(w, r, c.person, v, r.URL.Query().Get("history") != "")
	case http.MethodPut:
		if id.Operator && len(req.Bundle) > 0 {
			s.personAudit(id.Actor, c.person, "FORBIDDEN: operator write", now)
			httpError(w, http.StatusForbidden, "the operator only puts back one of the person's own versions ({\"restore\": N}), never new content")
			return
		}
		s.putPersonBundle(w, c, req, now)
	}
}

func (s *Server) personAudit(actor, person, outcome string, now time.Time) {
	if err := s.Store.FleetAudit(actor, "person_bundle_put", person, outcome, "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}

func (s *Server) putPersonBundle(w http.ResponseWriter, c personCaller, req TeamBundleRequest, now time.Time) {
	raw := req.Bundle
	note := strings.TrimSpace(req.Note)
	switch {
	case req.Restore > 0 && len(raw) > 0:
		httpError(w, http.StatusBadRequest, "send bundle or restore, not both")
		return
	case req.Restore > 0:
		old, err := s.Store.PersonBundle(c.person, req.Restore)
		if errors.Is(err, store.ErrNoTeamBundle) {
			httpError(w, http.StatusNotFound, fmt.Sprintf("no personal configuration version %d", req.Restore))
			return
		} else if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		raw = json.RawMessage(old.Bundle)
		if note == "" {
			note = fmt.Sprintf("restore v%d", req.Restore)
		}
	case len(raw) == 0:
		httpError(w, http.StatusBadRequest, `body must be {"bundle": {…}} or {"restore": <version>}`)
		return
	}
	if len(raw) > teamBundleMax {
		httpError(w, http.StatusRequestEntityTooLarge, "a personal configuration is at most 256 KiB")
		return
	}
	if len(note) > 200 {
		note = note[:200]
	}
	text, err := validateBundle(raw, true)
	if err != nil {
		s.personAudit(c.id.Actor, c.person, "REFUSED: "+err.Error(), now)
		httpError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	base := -1
	if req.Base != nil {
		base = *req.Base
	}
	b, err := s.Store.PutPersonBundle(c.person, text, c.id.Actor, note, base, now)
	if errors.Is(err, store.ErrTeamBundleBase) {
		httpError(w, http.StatusConflict, "your personal configuration changed since that version — read it again")
		return
	} else if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.personAudit(c.id.Actor, c.person, fmt.Sprintf("OK v%d", b.Version), now)
	// Every machine this person runs sessions on hears it now, not on its
	// next install-sync tick (claude-fleet#2784).
	s.broadcastPerson(c.person, b.Version)
	created := b.Created
	w.Header().Set("ETag", personETag(c.person, b.Version))
	writeJSON(w, http.StatusOK, TeamBundleResponse{Version: b.Version, Prev: b.Prev, Actor: b.Actor,
		Note: b.Note, Created: &created, Bundle: json.RawMessage(b.Bundle)})
}

func (s *Server) writePersonBundle(w http.ResponseWriter, r *http.Request, person string, v int, history bool) {
	b, err := s.Store.PersonBundle(person, v)
	out := TeamBundleResponse{Bundle: json.RawMessage(`{}`)}
	switch {
	case errors.Is(err, store.ErrNoTeamBundle) && v > 0:
		httpError(w, http.StatusNotFound, fmt.Sprintf("no personal configuration version %d", v))
		return
	case errors.Is(err, store.ErrNoTeamBundle):
		// nothing written yet: version 0, an empty layer
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	default:
		created := b.Created
		out = TeamBundleResponse{Version: b.Version, Prev: b.Prev, Actor: b.Actor, Note: b.Note,
			Created: &created, Bundle: json.RawMessage(b.Bundle)}
	}
	if history {
		if out.History, err = s.Store.PersonBundles(person, 50); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	tag := personETag(person, out.Version)
	w.Header().Set("ETag", tag)
	if v <= 0 && !history && r.Header.Get("If-None-Match") == tag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// PersonSummary is one person's line in ?all=1 — never the bundle.
type PersonSummary struct {
	Principal   string     `json:"principal"`
	Login       string     `json:"login,omitempty"`
	DisplayName string     `json:"display_name,omitempty"`
	Version     int        `json:"version"`
	Updated     *time.Time `json:"updated,omitempty"`
	Actor       string     `json:"actor,omitempty"`
	Items       int        `json:"items"`
}

// PersonSummaries is the ?all=1 answer.
type PersonSummaries struct {
	People []PersonSummary `json:"people"`
}

// bundleItems counts what a layer carries: one per MCP server, setting,
// codex key, skill, hook program, and one per hook entry under each event.
func bundleItems(raw string) int {
	var b map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &b) != nil {
		return 0
	}
	n := 0
	for k, v := range b {
		if k == "hooks" {
			var ev map[string][]json.RawMessage
			if json.Unmarshal(v, &ev) == nil {
				for _, l := range ev {
					n += len(l)
				}
			}
			continue
		}
		var m map[string]json.RawMessage
		if json.Unmarshal(v, &m) == nil {
			n += len(m)
		}
	}
	return n
}

// writePersonBundlePeople lists every known person (version 0 = never
// written) plus any layer whose person has since gone from the roster.
func (s *Server) writePersonBundlePeople(w http.ResponseWriter) {
	ps, err := s.Store.Principals()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	heads, err := s.Store.PersonBundleHeads()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	byID := map[string]store.PersonBundleHead{}
	for _, h := range heads {
		byID[h.Principal] = h
	}
	out := PersonSummaries{People: []PersonSummary{}}
	add := func(sum PersonSummary, h store.PersonBundleHead, ok bool) {
		if ok {
			created := h.Created
			sum.Version, sum.Updated, sum.Actor, sum.Items = h.Version, &created, h.Actor, bundleItems(h.Bundle)
		}
		out.People = append(out.People, sum)
	}
	for _, p := range ps {
		h, ok := byID[p.ID]
		delete(byID, p.ID)
		add(PersonSummary{Principal: p.ID, Login: p.Login, DisplayName: p.DisplayName}, h, ok)
	}
	for _, h := range heads {
		if _, left := byID[h.Principal]; left {
			add(PersonSummary{Principal: h.Principal}, h, true)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// nodePerson is the canonical person a node connection's login is bound to,
// "" when none (PrincipalForLogin, as the GET answers it).
func (s *Server) nodePerson(endpointID string) string {
	ep, err := s.Store.EndpointByID(endpointID)
	if err != nil || ep == nil {
		return ""
	}
	host, user := s.peerSelf(ep)
	owner, err := s.Store.PrincipalForLogin(host, user)
	if err != nil || owner == "" {
		return ""
	}
	if p, err := s.Store.Principal(owner); err == nil {
		return p.ID
	}
	return owner
}

// pushPerson tells one node's connection its person's version
// (claude-fleet#2784, EPIC #2781 C3) when it has not been told it yet — the
// team push's twin. person "" = the one its login is bound to; v 0 = read the
// current version. No person, or a person who never wrote → no message, so a
// hub where nobody keeps a layer sends byte for byte what it did. A failed
// write is not recorded: the next beat tries again.
func (s *Server) pushPerson(endpointID string, nc *nodeConn, person string, v int) {
	if !nc.canPerson {
		return
	}
	if person == "" {
		if person = s.nodePerson(endpointID); person == "" {
			return
		}
	}
	if v <= 0 {
		b, err := s.Store.PersonBundle(person, 0)
		if err != nil {
			if !errors.Is(err, store.ErrNoTeamBundle) {
				log.Printf("node %s: read the person's version: %v", endpointID, err)
			}
			return
		}
		v = b.Version
	}
	key := fmt.Sprintf("%s#%d", person, v)
	if v <= 0 || nc.personSent.Load() == key {
		return
	}
	msg, err := control.New(control.TypePerson, control.Person{Principal: person, Version: v})
	if err != nil {
		return
	}
	wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if s.nodes.get(endpointID) != nc {
		return // a newer link took over; it hears the version on its own first beat
	}
	if err := s.SendNodeWrite(wctx, endpointID, msg); err != nil {
		return
	}
	nc.personSent.Store(key)
}

// broadcastPerson pushes person's version v to every connected node whose
// login is bound to that person — and to no one else's.
func (s *Server) broadcastPerson(person string, v int) {
	s.nodes.each(func(id string, c *nodeConn) {
		if !c.canPerson {
			return
		}
		go func() {
			if s.nodePerson(id) == person {
				s.pushPerson(id, c, person, v)
			}
		}()
	})
}
