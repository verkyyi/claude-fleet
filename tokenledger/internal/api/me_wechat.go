package api

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A person already on the list hangs the service account's WeChat on
// themselves (claude-fleet#4057, EPIC #4048 C9): the console's home shows a
// band until they have, its dialog draws a bind code through C6's wxScene,
// polls it, and once they scanned the code is traded, once, for one more way
// to sign in and the openid the notices go to (hub_reach):
//
//	POST /v1/me/wechat/bind-qr   draw a bind code for this person in this
//	                             browser: {s, qr (an SVG), expires_at}
//	GET  /v1/me/wechat/bind-poll?s= wait | expired | down | bound | taken
//
// The rule is /auth/wechat/bind's 「挂到当前账号」: a WeChat that already signs
// someone else in is refused (taken), never moved. Off — the service
// account's road unconfigured — both answer 404 and /v1/me carries no reach.

const (
	meWxBindQRPath   = "/v1/me/wechat/bind-qr"
	meWxBindPollPath = "/v1/me/wechat/bind-poll"
)

// The states a bind code ends in, beside wxScenePoll's.
const (
	wxBound = "bound"
	wxTaken = "taken"
)

// MeReach is /v1/me's reach: whether the notices can find this person.
type MeReach struct {
	// WeChat: the person follows the service account and the hub holds
	// their openid.
	WeChat bool `json:"wechat"`
}

// meReach is pid's reach; nil when the service account's road is off.
func (s *Server) meReach(pid string) (*MeReach, error) {
	if !s.wxScanOn() || !isPerson(pid) {
		return nil, nil
	}
	rows, err := s.Store.HubReachOf(pid)
	if err != nil {
		return nil, err
	}
	out := &MeReach{}
	for _, r := range rows {
		out.WeChat = out.WeChat || (r.Channel == store.ReachWeChatMP && r.Followed)
	}
	return out, nil
}

// meWxBindGate answers for a request that may not bind: false when it wrote
// the refusal.
func (s *Server) meWxBindGate(w http.ResponseWriter, r *http.Request, method string) (string, bool) {
	if !s.wxScanOn() {
		http.NotFound(w, r)
		return "", false
	}
	if r.Method != method {
		w.Header().Set("Allow", method)
		httpError(w, http.StatusMethodNotAllowed, method+" only")
		return "", false
	}
	pid := principalOf(r.Context())
	if !isPerson(pid) {
		httpError(w, http.StatusForbidden, "a WeChat is bound to a signed-in person")
		return "", false
	}
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return "", false
	}
	w.Header().Set("Cache-Control", "no-store")
	return pid, true
}

// handleMeWxBindQR draws a bind code for the signed-in person.
func (s *Server) handleMeWxBindQR(w http.ResponseWriter, r *http.Request) {
	pid, ok := s.meWxBindGate(w, r, http.MethodPost)
	if !ok {
		return
	}
	c, err := s.wxScene(r.Context(), w, r, wxPurposeBind, pid, time.Now())
	if err != nil {
		if !errors.Is(err, errWxBusy) {
			log.Printf("wechat bind: no code: %v", err)
		}
		httpError(w, http.StatusServiceUnavailable, "WeChat is not available right now")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"s": c.Scene, "qr": string(qrSVG(c.QRURL)), "expires_at": c.ExpiresAt.Unix()})
}

// handleMeWxBindPoll answers where a bind code stands, and binds it once
// someone scanned it.
func (s *Server) handleMeWxBindPoll(w http.ResponseWriter, r *http.Request) {
	pid, ok := s.meWxBindGate(w, r, http.MethodGet)
	if !ok {
		return
	}
	now := time.Now()
	n, _ := strconv.ParseInt(r.URL.Query().Get("s"), 10, 64)
	state, c, openid := s.wxScenePoll(r.Context(), r, n, wxPurposeBind, now)
	if c != nil && c.Owner != pid {
		// Drawn in this browser for whoever was signed in then.
		state = wxExpired
	}
	if state == wxReady {
		state = s.wxBind(r, c, pid, openid, now)
	}
	writeJSON(w, http.StatusOK, map[string]string{"s": state})
}

// wxBind trades a scanned bind code, once: the scanner's WeChat becomes one
// more way pid signs in and where pid is reached — unless it already signs
// someone else in.
func (s *Server) wxBind(r *http.Request, c *store.WxScene, pid, openid string, now time.Time) string {
	u, err := s.WxGW.userInfo(r.Context(), openid)
	if err != nil {
		log.Printf("wechat bind: user/info: %v", err)
		return wxDown
	}
	if ok, err := s.Store.ConsumeWxScene(c.Scene, c.BrowserHash, now); err != nil || !ok {
		if err != nil {
			log.Printf("wechat bind: %v", err)
		}
		return wxExpired
	}
	// Every name this WeChat goes by: the unionid, and the openid it may
	// have signed someone in under before one was known.
	ids := []store.HubIdentity{{Kind: store.IdentityWeChatMP, Subject: u.OpenID}}
	if u.UnionID != "" {
		ids = []store.HubIdentity{{Kind: store.IdentityWeChat, Subject: u.UnionID}, ids[0]}
	}
	for _, id := range ids {
		owner, err := s.Store.IdentityPrincipal(id.Kind, id.Subject)
		if err != nil {
			log.Printf("wechat bind: %v", err)
			return wxDown
		}
		if owner != "" && owner != pid {
			_ = s.Store.HubAudit(pid, "identity.add", "(wechat)", "refused", "another person signs in with it", now)
			return wxTaken
		}
	}
	add := ids[0]
	add.PrincipalID, add.VerifiedAt, add.AddedBy = pid, now, "follow"
	if owner, _ := s.Store.IdentityPrincipal(add.Kind, add.Subject); owner == "" {
		err := s.Store.AddHubIdentity(add)
		if errors.Is(err, store.ErrIdentityTaken) {
			_ = s.Store.HubAudit(pid, "identity.add", "(wechat)", "refused", "another person signs in with it", now)
			return wxTaken
		}
		if err != nil {
			log.Printf("wechat bind: %v", err)
			return wxDown
		}
		_ = s.Store.HubAudit(pid, "identity.add", "(wechat)", "ok", "wechat, by following the service account", now)
	}
	if err := s.Store.SetHubReach(store.HubReach{Owner: pid, Channel: store.ReachWeChatMP, Addr: u.OpenID,
		Followed: u.Followed, UpdatedAt: now}); err != nil {
		log.Printf("wechat bind: reach: %v", err)
		return wxDown
	}
	return wxBound
}
