package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Invites (claude-fleet#2261, EPIC #2259 共同约定 4): an admin sends a
// newcomer one install command, and their GitHub sign-in lets them in — on
// the list, the invite spent, their login opened — with no admin at hand.
//
//	POST   /v1/fleet/invites {github_login?}   an admin mints one; the code is
//	                                          in this answer and nowhere else
//	GET    /v1/fleet/invites                   the admin's list (no codes)
//	DELETE /v1/fleet/invites?id=<id>           revoke an unused one
//	GET    /i/<code>                           the installer with the code in it
//
// How the code reaches the sign-in. The installer exports FLEET_INVITE and
// `fleet login` sends it with its start (`invite`); the pending login keeps
// it. When the browser opens that login's confirmation page signed out,
// rememberLoginCode hands the code to a ten-minute cookie scoped to
// /auth/github/ — the GitHub callback reads it on whichever replica it lands.
// A browser that opens /i/<code> itself gets the same cookie and /signin.
//
// What the sign-in does with it (githubAdmitSignIn → admitInvite): a person
// the list already names never spends it; anyone else spends it once —
// unexpired, unrevoked, by the GitHub username it is bound to if any — and is
// put on the list as a user, audited 「邀请已使用」. Their login is then opened
// as if fleet.auto_assign were on (placePrincipal, invitedPrincipal), whatever
// the setting says. An invite that cannot be used is refused with its reason,
// on the page and in the waiting terminal (loginRefusedHop); a person with no
// invite who is not on the list is told the one line to send an admin.
//
// The code itself never enters a log, an audit row, an issue or a page other
// than the admin's answer: the store keeps its SHA-256 only.

const (
	// InvitePath is the installer an invite command fetches: /i/<code>.
	InvitePath = "/i/"
	// LoginRefusedPath tells a waiting `fleet login` why its person was
	// refused at the sign-in (claude-fleet#2261).
	LoginRefusedPath = "/fleet/login/refused"

	inviteCookie    = "ccq_invite"
	inviteCookieTTL = 10 * time.Minute
	// codeInviteRefused is the poll's code for a login refused at the
	// sign-in: nobody invited the person, or their invite cannot be used.
	codeInviteRefused = "not_invited"
)

// validInviteCode: the shape randomToken mints (base64url), and nothing else
// ever reaches a lookup, a cookie or a script.
func validInviteCode(c string) bool {
	if len(c) < 16 || len(c) > 64 {
		return false
	}
	for _, r := range c {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

func inviteHash(code string) string {
	sum := sha256.Sum256([]byte(code))
	return hex.EncodeToString(sum[:])
}

func setInviteCookie(w http.ResponseWriter, r *http.Request, code string) {
	http.SetCookie(w, &http.Cookie{
		Name: inviteCookie, Value: code, Path: githubFlowPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(inviteCookieTTL.Seconds()),
	})
}

// takeInviteCookie is the invite this sign-in carries, "" for none; the
// cookie is spent either way.
func takeInviteCookie(w http.ResponseWriter, r *http.Request) string {
	c, err := r.Cookie(inviteCookie)
	if err != nil {
		return ""
	}
	clearCookie(w, r, inviteCookie, githubFlowPath)
	if !validInviteCode(c.Value) {
		return ""
	}
	return c.Value
}

// admitInvite spends invite for a person the list does not name and puts
// them on it. refusal is denyInvitePrefix + the reason when it cannot be used.
func (s *Server) admitInvite(id int64, login, invite string, now time.Time) (refusal string, err error) {
	actor := githubPrincipal(id)
	target := login + " (" + actor + ")"
	hash := inviteHash(invite)
	inv, err := s.Store.UseInvite(hash, login, actor, now)
	if reason := store.InviteReason(err); reason != "" {
		detail := "invite " + reason
		if old, _ := s.Store.InviteByHash(hash); old != nil {
			detail += " (" + old.ID + ")"
		}
		_ = s.Store.HubAudit(actor, "invite", target, "refused", detail, now)
		return denyInvitePrefix + reason, nil
	}
	if err != nil {
		return "", err
	}
	if err := s.Store.UpsertHubUser(store.HubUser{GitHubID: id, Login: login, Role: roleUser,
		AddedBy: "invite " + inv.ID + " by " + orDefault(inv.CreatedBy, "?"), AddedAt: now}); err != nil {
		_ = s.Store.UnuseInvite(hash)
		return "", err
	}
	_ = s.Store.HubAudit(actor, "invite", target, "ok", "邀请已使用 · invite used ("+inv.ID+", made by "+orDefault(inv.CreatedBy, "?")+")", now)
	return "", nil
}

// invitedPrincipal says whether pid came in on an invite: their login is
// opened whatever fleet.auto_assign says (claude-fleet#2261).
func (s *Server) invitedPrincipal(pid string) bool {
	if s.Store == nil {
		return false
	}
	ok, err := s.Store.InvitedPrincipal(pid)
	return err == nil && ok
}

// ── the waiting terminal hears a refusal ─────────────────────────────────

// loginRefused is the signed hop's body: which pending login, why, who.
type loginRefused struct {
	Code  string `json:"c"`
	Why   string `json:"w"`
	Login string `json:"l"`
	Exp   int64  `json:"e"`
}

// loginRefusedHop is where a refused sign-in goes when a `fleet login` is
// waiting on this browser: LoginRefusedPath, carrying a signed note, so the
// replica holding the pending login marks it refused and shows the page. ""
// when no login is waiting (the plain refusal page).
func (s *Server) loginRefusedHop(w http.ResponseWriter, r *http.Request, why, login string, now time.Time) string {
	if !s.Fleet || s.SSHCA == nil {
		return ""
	}
	c, err := r.Cookie(loginCookie)
	if err != nil {
		return ""
	}
	code := strings.ToUpper(c.Value)
	if !validUserCode(code) {
		return ""
	}
	http.SetCookie(w, &http.Cookie{Name: loginCookie, Value: "", Path: "/", MaxAge: -1})
	body, _ := json.Marshal(loginRefused{Code: code, Why: why, Login: login, Exp: now.Add(2 * time.Minute).Unix()})
	return LoginRefusedPath + "?r=" + signBlob(body, s.GitHub.sessionKey())
}

// handleLoginRefused marks the pending login refused — its terminal prints
// the same sentence the page shows and stops — and answers with the page.
func (s *Server) handleLoginRefused(w http.ResponseWriter, r *http.Request) {
	if !s.GitHub.ready() || s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var note loginRefused
	if raw, ok := verifyBlob(r.URL.Query().Get("r"), s.GitHub.sessionKey()); ok {
		_ = json.Unmarshal(raw, &note)
	}
	now := time.Now()
	if note.Exp < now.Unix() || !validUserCode(note.Code) {
		http.Redirect(w, r, "/signin?e=expired", http.StatusFound)
		return
	}
	loc := s.pageLocale(w, r)
	why := denyText(loc, note.Why, note.Login)
	s.devices.withUser(note.Code, now, func(l *deviceLogin) {
		if l.state == devicePending {
			l.state, l.err, l.code = deviceDenied, why, codeInviteRefused
		}
	})
	s.githubDeny(w, r, note.Why, note.Login)
}

// ── the admin's endpoint ─────────────────────────────────────────────────

// inviteView is one row of GET /v1/fleet/invites.
type inviteView struct {
	store.Invite
	State string `json:"state"`
}

// InviteCreated is POST /v1/fleet/invites's answer: the only place the code
// is ever shown.
type InviteCreated struct {
	inviteView
	Code    string `json:"code"`
	URL     string `json:"url"`
	Command string `json:"command"`
}

func (s *Server) handleFleetInvites(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if s.Store == nil {
		httpError(w, http.StatusServiceUnavailable, "no database")
		return
	}
	now := time.Now()
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		invs, err := s.Store.Invites()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := make([]inviteView, 0, len(invs))
		for _, i := range invs {
			out = append(out, inviteView{Invite: i, State: i.State(now)})
		}
		writeJSON(w, http.StatusOK, map[string]any{"invites": out})
	case http.MethodPost:
		s.createInvite(w, r, now)
	case http.MethodDelete:
		id := strings.TrimSpace(r.URL.Query().Get("id"))
		if id == "" {
			httpError(w, http.StatusBadRequest, "which invite: ?id=<id>")
			return
		}
		ok, err := s.Store.RevokeInvite(id, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !ok {
			httpError(w, http.StatusNotFound, "no unused invite "+id)
			return
		}
		_ = s.Store.HubAudit(actorOf(r), "invite", id, "revoked", "", now)
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "state": store.InviteRevoked})
	default:
		w.Header().Set("Allow", "GET, POST, DELETE")
		httpError(w, http.StatusMethodNotAllowed, "GET, POST or DELETE")
	}
}

func (s *Server) createInvite(w http.ResponseWriter, r *http.Request, now time.Time) {
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	var req struct {
		GitHubLogin string `json:"github_login"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			httpError(w, http.StatusBadRequest, "the body must be {\"github_login\": \"<optional GitHub username>\"}")
			return
		}
	}
	gl := strings.TrimPrefix(strings.TrimSpace(req.GitHubLogin), "@")
	if gl != "" && !githubLoginRE.MatchString(gl) {
		httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not a GitHub username", gl))
		return
	}
	code, err1 := randomToken(18)
	id, err2 := randomToken(6)
	if err1 != nil || err2 != nil {
		httpError(w, http.StatusInternalServerError, "no randomness")
		return
	}
	inv := store.Invite{ID: "inv_" + id, CodeHash: inviteHash(code), GitHubLogin: gl, CreatedBy: actorOf(r),
		CreatedAt: now, ExpiresAt: now.Add(store.InviteTTL)}
	if err := s.Store.CreateInvite(inv); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	detail := "for anyone, until " + inv.ExpiresAt.Format(time.RFC3339)
	if gl != "" {
		detail = "for GitHub user " + gl + ", until " + inv.ExpiresAt.Format(time.RFC3339)
	}
	_ = s.Store.HubAudit(inv.CreatedBy, "invite", inv.ID, "created", detail, now)
	u := s.hubURL(r) + InvitePath + code
	writeJSON(w, http.StatusCreated, InviteCreated{
		inviteView: inviteView{Invite: inv, State: inv.State(now)},
		Code:       code, URL: u, Command: "curl -fsSL " + u + " | sh",
	})
}

// ── /i/<code>: the installer, with the code in it ────────────────────────

// handleInviteInstall answers an invite command: the hub's installer with
// FLEET_INVITE exported at its top, so the `fleet login` it ends in carries
// the code. An invite that cannot be used is a script that says why and
// stops — `curl | sh` shows it — and a browser is sent to sign in with it.
func (s *Server) handleInviteInstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if !s.GitHub.ready() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	code := strings.TrimPrefix(r.URL.Path, InvitePath)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	now := time.Now()
	reason := store.InviteUnknown
	if validInviteCode(code) {
		inv, err := s.Store.InviteByHash(inviteHash(code))
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if inv != nil {
			reason = inv.State(now)
		}
	}
	if wantsHTML(r) {
		if reason == "active" {
			setInviteCookie(w, r, code)
			http.Redirect(w, r, "/signin", http.StatusFound)
			return
		}
		s.githubDeny(w, r, denyInvitePrefix+reason, "")
		return
	}
	if reason != "active" {
		loc := s.pageLocale(w, r)
		w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.WriteHeader(http.StatusOK) // a 4xx would make `curl -f` print nothing
		_, _ = w.Write([]byte("#!/bin/sh\necho " + shellQuote("✗ "+denyText(loc, denyInvitePrefix+reason, "")) + " >&2\nexit 1\n"))
		return
	}
	if !s.installReady() {
		http.NotFound(w, r)
		return
	}
	body, ok := s.installerScript(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write([]byte(withInvite(body, code)))
}

// withInvite puts `FLEET_INVITE=<code>; export FLEET_INVITE` right under the
// script's shebang (code is validInviteCode's shape: nothing to quote).
func withInvite(script, code string) string {
	line := "FLEET_INVITE='" + code + "'; export FLEET_INVITE  # invite (claude-fleet#2261): sent once by fleet login\n"
	if strings.HasPrefix(script, "#!") {
		if i := strings.IndexByte(script, '\n'); i >= 0 {
			return script[:i+1] + line + script[i+1:]
		}
	}
	return line + script
}

// shellQuote is s as one single-quoted sh word.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
