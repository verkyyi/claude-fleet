package api

import (
	"context"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
)

// 以他的视角看 (claude-fleet#3944, EPIC #3923 R4): an admin opens a member's
// 我的 read-only, to help them without trading screenshots.
//
// The page is /app/*?as=<principal>; its reads carry the same principal in
// ViewAsHeader (an EventSource, which cannot set a header, the ?as= query).
// The gate (personAdmit) honours it on an ADMIN's own session only — a member
// or the operator's shared door carrying it is answered as if it were absent
// — and then:
//
//   - the request is the person's: principal, a session in their name, a
//     member's role (never an admin's, so no whole-hub read and no admin page),
//     so every read answers through their FleetScope exactly as it would them;
//   - nothing changes: every method but GET/HEAD, a websocket upgrade and the
//     conversation's relay (the person's own talk, /v1/chat/* bar home) are a
//     403 whatever the route — viewAsGuard, outside the router, so a door that
//     admits on its own (a connection certificate's, sshRelayHTTPIdentity) is
//     held to it too, and those doors read as the person
//     (viewAsRelayIdentity);
//   - opening a page is one audit row, view_as (actor the admin, target the
//     person, detail the page) — a read of the API under it is not, or every
//     poll would be one.
//
// The admin side (/admin) never takes it: there it is ignored, as for a member.
const (
	ViewAsParam  = "as"
	ViewAsHeader = "X-Fleet-View-As"
)

// ViewAs is who is looking through whose eyes, carried on the context.
type ViewAs struct {
	Admin     string // the admin's principal
	AdminName string
	Person    string // the person looked at
	Name      string
}

type viewAsKey struct{}

// viewAsOf is r's ViewAs, nil when it is an ordinary request.
func viewAsOf(ctx context.Context) *ViewAs {
	v, _ := ctx.Value(viewAsKey{}).(*ViewAs)
	return v
}

// viewAsAsked is the principal r asks to look through: the header, else the
// query; "" on the admin side, which never takes it.
func viewAsAsked(r *http.Request) string {
	if p := r.URL.Path; p == AdminPrefix || strings.HasPrefix(p, AdminPrefix+"/") {
		return ""
	}
	if v := strings.TrimSpace(r.Header.Get(ViewAsHeader)); v != "" {
		return v
	}
	return strings.TrimSpace(r.URL.Query().Get(ViewAsParam))
}

// viewAsReadable is whether r may run under a view: a plain read, never a
// write, an upgrade or the person's conversation.
func viewAsReadable(r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	if r.Header.Get("Upgrade") != "" {
		return false
	}
	if p := r.URL.Path; strings.HasPrefix(p, ChatPathPrefix) && p != ChatPathPrefix+chatHomeRoute {
		return false
	}
	return true
}

// viewAsGuard refuses anything but a read to an admin's session asking for a
// view, before any route sees it. Nothing asked ⇒ nothing read, byte for byte.
func (s *Server) viewAsGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !viewAsReadable(r) && s.consoleTicketCookie(r) {
			// A read-only console ticket's session (task T844): reads only,
			// whatever the route — the same rule as a view.
			httpError(w, http.StatusForbidden, consoleTicketRefusal)
			return
		}
		if target := viewAsAsked(r); target != "" && !viewAsReadable(r) {
			if _, pid, ok := s.personSession(r); ok && pid != target {
				if role, err := s.personRole(pid); err == nil && role == roleAdmin {
					httpError(w, http.StatusForbidden, viewAsRefusal)
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

const viewAsRefusal = "只读预览，不能改动（read-only preview: nothing can be changed）"

// viewAsRelayIdentity is sshRelayHTTPIdentity's answer for an admin looking
// through target: target, as a member, or nobody when there is no such person.
func (s *Server) viewAsRelayIdentity(r *http.Request, target string) (sshRelayIdentity, bool) {
	role, err := s.personRole(target)
	if err != nil || role == "" || (role == roleTrial && !trialRoute(r.URL.Path)) {
		return sshRelayIdentity{}, false
	}
	return sshRelayIdentity{Principal: target, Actor: target}, true
}

// viewAsAdmit is personAdmit's branch for an admin asking to look through
// target: ok=false when there is nothing to look through (target is the admin
// themself), handled=true when it answered r itself.
func (s *Server) viewAsAdmit(w http.ResponseWriter, r *http.Request, sess *authz.Session, target string) (ctx context.Context, ok, handled bool) {
	admin := sess.Principal()
	if target == admin {
		return nil, false, false
	}
	role, err := s.personRole(target)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return nil, true, true
	}
	if role == "" {
		httpError(w, http.StatusNotFound, "没有这个人（no such person）")
		return nil, true, true
	}
	if !viewAsReadable(r) {
		httpError(w, http.StatusForbidden, viewAsRefusal)
		return nil, true, true
	}
	if role != roleTrial {
		role = roleUser // an admin looked at is seen as on their own pages
	}
	if role == roleTrial && !trialRoute(r.URL.Path) {
		s.notFoundPage(w, r)
		return nil, true, true
	}
	v := &ViewAs{Admin: admin, AdminName: sess.Name, Person: target, Name: s.viewAsName(target)}
	if !strings.HasPrefix(r.URL.Path, "/v1/") {
		s.auditViewAs(v, r.URL.Path)
	}
	as := &authz.Session{Sub: sess.Sub, Aud: sess.Aud, Exp: sess.Exp, Iat: sess.Iat, Sid: sess.Sid, UID: target, Name: v.Name, Role: role}
	ctx = context.WithValue(withViewer(r.Context(), admin+" as "+target), principalKey{}, target)
	ctx = context.WithValue(ctx, viewAsKey{}, v)
	return withRole(withDoor(withSession(ctx, as), doorGitHub), role), true, false
}

// viewAsName is the person's name as the people list shows it: their sign-in
// name, else the name the fleet recorded, else the principal.
func (s *Server) viewAsName(pid string) string {
	if u, err := s.Store.HubUserByPrincipal(pid); err == nil && u != nil && u.Login != "" {
		return u.Login
	}
	if s.Fleet {
		if p, err := s.Store.Principal(pid); err == nil && p != nil && p.DisplayName != "" {
			return p.DisplayName
		}
	}
	return pid
}

// auditViewAs is one row per page opened through someone's eyes.
func (s *Server) auditViewAs(v *ViewAs, page string) {
	actor := v.Admin
	if v.AdminName != "" {
		actor += " (" + v.AdminName + ")"
	}
	target, now := "person:"+v.Person, time.Now()
	var err error
	if s.Fleet {
		err = s.Store.FleetAudit(actor, "view_as", target, "OK", page, now)
	} else {
		err = s.Store.HubAudit(actor, "view_as", target, "ok", page, now)
	}
	if err != nil {
		log.Printf("view_as audit: %v", err)
	}
}
