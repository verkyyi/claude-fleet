package api

import (
	"context"
	"errors"
	"log"
	"net"
	"net/url"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// Signing in while GitHub is down (claude-fleet#4849, EPIC #4839 C10).
// GitHub is one way in among several: a GitHub that cannot be reached says
// which other way to use, a person whose one way in is GitHub is nudged once
// to add a second, the admins the deploy names stay pinned in the database
// (ResolveGitHubAdmins asks GitHub only for a name never pinned), and adding
// someone by GitHub name says to invite them by mail instead. GitHub
// reachable ⇒ nothing here changes a byte.

// githubDownFor is how long one unreachable GitHub keeps /signin saying so
// next to its button; any GitHub answer clears it at once.
const githubDownFor = 10 * time.Minute

// githubUnreachable: err never reached GitHub — no connection, no DNS, a
// timeout. An answer GitHub gave (a 404, a refused code) is not this.
func githubUnreachable(err error) bool {
	if err == nil {
		return false
	}
	var ue *url.Error
	var ne net.Error
	return errors.As(err, &ue) || errors.As(err, &ne) || errors.Is(err, context.DeadlineExceeded)
}

// githubSaw records how a call to GitHub went: unreachable marks GitHub down
// for githubDownFor, an answer clears the mark.
func (s *Server) githubSaw(err error, now time.Time) {
	if githubUnreachable(err) {
		if s.githubDownAt.Swap(now.UnixNano()) == 0 {
			log.Printf("github sign-in: GitHub unreachable (%v) — /signin points to the other ways", err)
		}
		return
	}
	if s.githubDownAt.Swap(0) != 0 {
		log.Printf("github sign-in: GitHub answers again")
	}
}

// githubDown: GitHub was unreachable within githubDownFor.
func (s *Server) githubDown(now time.Time) bool {
	at := s.githubDownAt.Load()
	return at != 0 && now.Sub(time.Unix(0, at)) < githubDownFor
}

// githubDownNote is the /signin?e= that names the other ways this hub has,
// "" when it has none (the page keeps its plain "github" note).
func (s *Server) githubDownNote() string {
	wx := s.WeChat.ready() || s.wxScanOn()
	switch {
	case wx && s.Email.ready():
		return "github-down"
	case s.Email.ready():
		return "github-down-email"
	case wx:
		return "github-down-wechat"
	}
	return ""
}

// addWayAction is the audit row that remembers the nudge was given.
const addWayAction = "signin.add-way"

// addWayNudge: pid just signed in with GitHub, GitHub is their only way in,
// the hub offers another, and they have not been told yet — tell them once
// (settings' 登录方式 card, ?e=add-way). Never a gate: the sign-in stands.
func (s *Server) addWayNudge(pid string, now time.Time) bool {
	if s.Store == nil || !s.otherWaysOn() {
		return false
	}
	ids, err := s.Store.HubIdentities(pid)
	if err != nil {
		return false
	}
	for _, i := range ids {
		if i.Kind != store.IdentityGitHub {
			return false
		}
	}
	if told, err := s.Store.HubAuditHas(pid, addWayAction); err != nil || told {
		return false
	}
	_ = s.Store.HubAudit(pid, addWayAction, pid, "ok", "GitHub is their only way in: asked once to add another", now)
	return true
}

// SignInCount is the hub's read of who a GitHub outage would lock out
// (/v1/node/self's signin, the doctor's hub row): the people whose one way in
// is GitHub, and the admin names the deploy gives that no sign-in or
// start-up has pinned to a GitHub ID yet.
type SignInCount struct {
	GitHubOnly     int `json:"github_only"`
	AdminsUnpinned int `json:"admins_unpinned"`
}

// signInCount is nil without GitHub sign-in: nobody depends on it.
func (s *Server) signInCount() *SignInCount {
	if !s.GitHub.ready() || s.Store == nil {
		return nil
	}
	n, err := s.Store.HubGitHubOnly()
	if err != nil {
		return nil
	}
	c := &SignInCount{GitHubOnly: n}
	for _, name := range s.githubAdmins() {
		if _, ok, err := s.Store.PinnedID(name); err == nil && !ok {
			c.AdminsUnpinned++
		}
	}
	return c
}

func init() {
	for k, v := range map[string]i18n.Text{
		"signin.note.github-down": {
			i18n.EN:   "GitHub sign-in isn't available right now — sign in with email or WeChat instead.",
			i18n.ZhCN: "GitHub 登录暂时不可用，用邮箱或微信登录。",
		},
		"signin.note.github-down-email": {
			i18n.EN:   "GitHub sign-in isn't available right now — sign in with email instead.",
			i18n.ZhCN: "GitHub 登录暂时不可用，用邮箱登录。",
		},
		"signin.note.github-down-wechat": {
			i18n.EN:   "GitHub sign-in isn't available right now — sign in with WeChat instead.",
			i18n.ZhCN: "GitHub 登录暂时不可用，用微信登录。",
		},
	} {
		pageText[k] = v
	}
}
