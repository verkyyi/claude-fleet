package api

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A person is an account, not a GitHub account (claude-fleet#3603, EPIC #3570
// C10). Every person has ONE principal, kept forever: gh:<GitHub ID> for
// everyone who came in through GitHub before (their key never changed), and
// p:<uuid> for anyone since who came in another way. How a person signs in —
// GitHub, an address, WeChat — is a row of hub_identities hung on that
// principal; a way of signing in is one more row, never another person.
//
// isPerson is the ONE test of "is this principal a person" (the operator's
// doors, machine logins, enterprise-WeChat ids and the pool are not), and
// personRow / personRole are the one reading of what the list says about
// one. Nothing tests a principal's "gh:" prefix to mean "a person": the only
// place that spelling is made or parsed is the GitHub identity
// (githubPrincipal / githubIDOf in github_auth.go), which TestNoGHPrefixOutsideIdentity
// holds.

// personPrincipalPrefix starts the principal of a person who did not come in
// through GitHub: p:<uuid>, lower-case — one spelling per person, and a
// LoginBase of it is a login a node accepts.
const personPrincipalPrefix = "p:"

var personPrincipalRE = regexp.MustCompile(`^p:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// isPerson reports whether principal is a person's: gh:<GitHub ID> or p:<uuid>.
func isPerson(principal string) bool {
	if _, ok := githubIDOf(principal); ok {
		return true
	}
	return personPrincipalRE.MatchString(principal)
}

// newPersonPrincipal mints a new person's principal: p:<random uuid v4>.
func newPersonPrincipal() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%s%x-%x-%x-%x-%x", personPrincipalPrefix, b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

// personWord names what kind of person pid is, for a refusal: "GitHub
// person" for a GitHub one — the words every such refusal said before
// claude-fleet#3603 — else "person".
func personWord(pid string) string {
	if _, ok := githubIDOf(pid); ok {
		return "GitHub person"
	}
	return "person"
}

// validEmail is a plausible address: one @, something on each side, a dot
// in the domain, no spaces or angle brackets, at most 254 bytes. The proof is
// the sign-in through it, never this shape.
func validEmail(e string) bool {
	local, domain, ok := strings.Cut(e, "@")
	return ok && len(e) <= 254 && local != "" && strings.Contains(domain, ".") &&
		!strings.HasPrefix(domain, ".") && !strings.HasSuffix(domain, ".") &&
		!strings.ContainsAny(e, " \t\r\n<>,;\"") && !strings.Contains(domain, "@")
}

// personRow is the list's row for a person, nil when principal is not a
// person or has no row.
func (s *Server) personRow(principal string) (*store.HubUser, error) {
	if s.Store == nil || !isPerson(principal) {
		return nil, nil
	}
	return s.Store.HubUserByPrincipal(principal)
}

// personLogin is a person's name on the list ("" when none): the GitHub
// username for a GitHub person, the name they came in with for anyone else.
func (s *Server) personLogin(principal string) string {
	if u, err := s.personRow(principal); err == nil && u != nil {
		return u.Login
	}
	return ""
}

// githubPersonOf is the person a GitHub ID signs in as: the one whose github
// identity it is, else gh:<id> — a GitHub person from before identities, or
// one signing in for the first time.
func (s *Server) githubPersonOf(id int64) (string, error) {
	if s.Store != nil {
		pid, err := s.Store.IdentityPrincipal(store.IdentityGitHub, fmt.Sprint(id))
		if err != nil || pid != "" {
			return pid, err
		}
	}
	return githubPrincipal(id), nil
}

// isAdminPrincipal reports whether CCQUOTA_ADMINS names pid or one of the
// addresses it signs in with.
func (s *Server) isAdminPrincipal(pid string, ids []store.HubIdentity) bool {
	for _, a := range s.Admins {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		if strings.EqualFold(a, pid) {
			return true
		}
		for _, i := range ids {
			if i.Kind == store.IdentityEmail && strings.EqualFold(a, i.Subject) {
				return true
			}
		}
	}
	return false
}

// personRole is what the list says about a person RIGHT NOW: admin when the
// deploy names them — CCQUOTA_ADMINS (the principal, or an address they sign
// in with), or CCQUOTA_GITHUB_ADMINS (a username pinned to a GitHub ID they
// sign in with) — user when they have a user row, "" when neither: refused.
// A hub_users row saying admin for someone the deploy no longer names grants
// nothing: the deploy decides who is admin.
func (s *Server) personRole(pid string) (string, error) {
	if s.Store == nil || !isPerson(pid) {
		return "", nil
	}
	var ids []store.HubIdentity
	gids := map[int64]bool{}
	if id, ok := githubIDOf(pid); ok {
		gids[id] = true
	}
	if _, isGH := githubIDOf(pid); len(s.Admins) > 0 || !isGH {
		var err error
		if ids, err = s.Store.HubIdentities(pid); err != nil {
			return "", err
		}
		for _, i := range ids {
			if i.Kind == store.IdentityGitHub {
				var n int64
				if _, err := fmt.Sscan(i.Subject, &n); err == nil && n > 0 {
					gids[n] = true
				}
			}
		}
	}
	if s.isAdminPrincipal(pid, ids) {
		return roleAdmin, nil
	}
	if len(gids) > 0 {
		for _, name := range s.githubAdmins() {
			pinned, ok, err := s.Store.PinnedID(name)
			if err != nil {
				return "", err
			}
			if ok && gids[pinned] {
				return roleAdmin, nil
			}
		}
	}
	u, err := s.Store.HubUserByPrincipal(pid)
	if err != nil {
		return "", err
	}
	if u != nil && u.Role == roleUser {
		return roleUser, nil
	}
	return "", nil
}

// admitPerson decides a sign-in through a way that is not GitHub — an
// address, WeChat (claude-fleet#3603; C11 brings the ways): kind + subject
// is the way, name what the person is called by it. The person is whoever
// that way already lets in; a way nobody has yet lets someone in only with
// an invite — the invite's person is then a NEW p:<uuid> with this way hung
// on it. Never a new account without an invite (EPIC #3570 共同约定 11). role
// "" is a refusal, named by refusal.
func (s *Server) admitPerson(kind, subject, name, invite string, now time.Time) (pid, role, refusal string, err error) {
	if s.Store == nil {
		return "", "", "", errors.New("no database")
	}
	if !store.KnownIdentityKind(kind) || kind == store.IdentityGitHub || strings.TrimSpace(subject) == "" {
		return "", "", "", fmt.Errorf("admitPerson: %q is not a way this door signs in", kind)
	}
	subject = store.NormIdentitySubject(kind, subject)
	if name = strings.TrimSpace(name); name == "" {
		name = subject
	}
	target := name + " (" + kind + ")"
	pid, err = s.Store.IdentityPrincipal(kind, subject)
	if err != nil {
		return "", "", "", err
	}
	if pid != "" {
		if role, err = s.personRole(pid); err != nil {
			return "", "", "", err
		}
	}
	if role == "" && invite != "" {
		if pid == "" {
			if pid, err = newPersonPrincipal(); err != nil {
				return "", "", "", err
			}
		}
		if refusal, err := s.admitInviteAs(pid, kind, subject, name, invite, now); err != nil || refusal != "" {
			return "", "", refusal, err
		}
		role = roleUser
	}
	actor := pid
	if actor == "" {
		actor = kind + ":?"
	}
	if role == "" {
		_ = s.Store.HubAudit(actor, "signin", target, "refused", "not on the list", now)
		return "", "", denyNotListed, nil
	}
	if err := s.Store.AddHubIdentity(store.HubIdentity{Kind: kind, Subject: subject, PrincipalID: pid,
		VerifiedAt: now, AddedBy: "signin"}); err != nil {
		return "", "", "", err
	}
	if err := s.Store.TouchHubPrincipal(pid, "", now); err != nil {
		return "", "", "", err
	}
	_ = s.Store.HubAudit(pid, "signin", target, "ok", "as "+role, now)
	return pid, role, "", nil
}

// ── 登录方式: a person's ways of signing in, on their settings page ─────────
//
//	GET    /v1/me/identities                       the ways, and which may be added
//	POST   /v1/me/identities {kind:"email", subject}  hang an address on yourself —
//	                                               an admin vouches for their own;
//	                                               anyone else proves it by signing
//	                                               in through it (C11's mail)
//	DELETE /v1/me/identities?kind=&subject=        take one off; the last one stays
//
// GitHub is added by signing in with it: /auth/github/start?link=1 from a
// signed-in browser hangs the GitHub account it comes back with on the
// person (githubLink).

// IdentitiesView is GET /v1/me/identities.
type IdentitiesView struct {
	Person     string         `json:"person"`
	Identities []identityView `json:"identities"`
	// CanAdd are the kinds this person may add from the page right now.
	CanAdd []string `json:"can_add"`
}

// identityView is one way of signing in as the page shows it: Label is the
// GitHub username for a github one, the subject otherwise.
type identityView struct {
	store.HubIdentity
	Label string `json:"label"`
}

func (s *Server) handleMeIdentities(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	pid := principalOf(r.Context())
	if s.Store == nil || !isPerson(pid) {
		httpError(w, http.StatusForbidden, "ways of signing in belong to a signed-in person")
		return
	}
	now := time.Now()
	switch r.Method {
	case http.MethodGet, http.MethodHead:
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		var req struct {
			Kind    string `json:"kind"`
			Subject string `json:"subject"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, `the body must be {"kind": "email", "subject": "<address>"}`)
			return
		}
		if req.Kind != store.IdentityEmail {
			httpError(w, http.StatusBadRequest, "only an address is added here — GitHub is added by signing in with it")
			return
		}
		addr := store.NormIdentitySubject(store.IdentityEmail, req.Subject)
		if !validEmail(addr) {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not an email address", req.Subject))
			return
		}
		if roleOf(r.Context()) != roleAdmin {
			if !s.Email.ready() {
				httpError(w, http.StatusForbidden, "an address is added by signing in with it")
				return
			}
			// Anyone else proves it (claude-fleet#3604): a mail to it, whose
			// link — opened in this browser — hangs it on them (emailFinish).
			// The answer is the same whoever the address belongs to.
			switch err := s.emailStart(w, r, addr, now); {
			case errors.Is(err, errEmailSlow):
				httpError(w, http.StatusTooManyRequests, "a mail went to this address a moment ago — wait a minute")
			case err != nil:
				httpError(w, http.StatusInternalServerError, "could not send the mail")
			default:
				writeJSON(w, http.StatusAccepted, map[string]any{"mail_sent": true})
			}
			return
		}
		err := s.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: addr, PrincipalID: pid,
			VerifiedAt: now, AddedBy: "admin " + actorOf(r)})
		if errors.Is(err, store.ErrIdentityTaken) {
			_ = s.Store.HubAudit(actorOf(r), "identity.add", addr, "refused", "another person signs in with it", now)
			httpError(w, http.StatusConflict, addr+" already lets another person in")
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		_ = s.Store.HubAudit(actorOf(r), "identity.add", addr, "ok", "email, vouched by an admin", now)
	case http.MethodDelete:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		kind, subject := r.URL.Query().Get("kind"), r.URL.Query().Get("subject")
		ok, err := s.Store.RemoveHubIdentity(pid, kind, subject)
		switch {
		case errors.Is(err, store.ErrLastIdentity):
			httpError(w, http.StatusConflict, "this is your only way of signing in — add another first")
			return
		case err != nil:
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		case !ok:
			httpError(w, http.StatusNotFound, "you have no such way of signing in")
			return
		}
		_ = s.Store.HubAudit(actorOf(r), "identity.remove", kind+" "+store.NormIdentitySubject(kind, subject), "ok", "", now)
	default:
		w.Header().Set("Allow", "GET, POST, DELETE")
		httpError(w, http.StatusMethodNotAllowed, "GET, POST or DELETE")
		return
	}
	ids, err := s.Store.HubIdentities(pid)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := IdentitiesView{Person: pid, Identities: []identityView{}, CanAdd: []string{}}
	hasGH := false
	for _, i := range ids {
		hasGH = hasGH || i.Kind == store.IdentityGitHub
		v := identityView{HubIdentity: i, Label: i.Subject}
		if i.Kind == store.IdentityGitHub {
			var n int64
			if _, err := fmt.Sscan(i.Subject, &n); err == nil {
				if l, _ := s.Store.PinnedLogin(n); l != "" {
					v.Label = l
				}
			}
		}
		out.Identities = append(out.Identities, v)
	}
	if !hasGH && s.GitHub.ready() {
		out.CanAdd = append(out.CanAdd, store.IdentityGitHub)
	}
	hasWX := false
	for _, i := range ids {
		hasWX = hasWX || i.Kind == store.IdentityWeChat
	}
	if !hasWX && s.WeChat.ready() {
		out.CanAdd = append([]string{store.IdentityWeChat}, out.CanAdd...)
	}
	if roleOf(r.Context()) == roleAdmin || s.Email.ready() {
		out.CanAdd = append(out.CanAdd, store.IdentityEmail)
	}
	writeJSON(w, http.StatusOK, out)
}

// githubLink finishes /auth/github/start?link=1 (claude-fleet#3603): the
// GitHub account the browser came back with becomes one more way pid signs
// in, unless it already lets someone else in. Where the browser goes next.
func (s *Server) githubLink(pid string, id int64, login string, now time.Time) string {
	err := s.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityGitHub, Subject: fmt.Sprint(id),
		PrincipalID: pid, VerifiedAt: now, AddedBy: "link"})
	target := login + " (github " + fmt.Sprint(id) + ")"
	if errors.Is(err, store.ErrIdentityTaken) {
		_ = s.Store.HubAudit(pid, "identity.add", target, "refused", "another person signs in with it", now)
		return AppPrefix + "/config?e=taken#logins"
	}
	if err != nil {
		log.Printf("github link for %s: %v", pid, err)
		return AppPrefix + "/config?e=github#logins"
	}
	// Their username is pinned to the ID like any GitHub sign-in's.
	if err := s.pinName(login, id, pid, now); err != nil && !errors.Is(err, store.ErrPinConflict) {
		log.Printf("github link for %s: pin %s: %v", pid, login, err)
	}
	_ = s.Store.HubAudit(pid, "identity.add", target, "ok", "github, by signing in with it", now)
	return AppPrefix + "/config#logins"
}
