package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Open ClaudeFleet inside WeChat and be in (claude-fleet#4055, EPIC #4048
// C7). A phone cannot scan its own screen, so inside WeChat's own browser
// /signin skips the code: /auth/wechat/start sends the browser to the
// service account's silent web authorisation (snsapi_base — no prompt, no
// follow needed), authorised by the company's third-party platform
// (component_appid). WeChat only returns to a host on that platform's list,
// so it returns to workbench's relay (GET /node_w/wx/oauth/relay, monorepo
// #7775), which trades the code for the openid and sends the browser back to
// the address registered under our name (WX_OAUTH_RELAY_TARGETS: fleet =
// …/auth/wechat/relay-cb, monorepo #12138) with
//
//	n   our nonce, echoed      o  the openid      t  the time (unix seconds)
//	sig hex HMAC-SHA256(WX_INTERNAL_TOKEN, "<target>.<n>.<o>.<t>")
//
// — or with err= and no openid when it could not. The key is the same gate
// token the hub already holds for /internal/wx (CCQUOTA_WX_INTERNAL_TOKEN);
// no new secret, no service-account secret. The callback takes it only when
// the nonce is the one this browser's flow cookie carries, the time is within
// five minutes, the signature holds and the nonce was never spent (on either
// replica); then the person is whoever the service account says the openid
// is, landed exactly as a scan is (wxLand): on the list ⇒ in, not ⇒ /apply.
//
// Every failure goes back to /signin with ?e=, which also stops the automatic
// hop, so a broken relay costs one page with the code, never a loop.
// CCQUOTA_WX_RELAY_URL unset ⇒ this road does not exist and WeChat's browser
// gets what it got before.

const (
	wxRelayCBPath      = "/auth/wechat/relay-cb"
	wechatRoadRelay    = "relay"
	wxRelayTargetDef   = "fleet"
	wxComponentAppID   = "wx66e7ebef9555d284" // the company's third-party platform
	wxRelaySkew        = 5 * time.Minute      // the relay's clock vs ours, and the hop's life
	wxRelayAuthorizeEP = "/connect/oauth2/authorize"
)

var (
	wxOpenidRE      = regexp.MustCompile(`^[\w-]{16,64}$`)
	wxRelayTargetRE = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	wxRelayErrRE    = regexp.MustCompile(`^[a-z_]{1,32}$`)
)

func (g *WxGateway) relayReady() bool { return g.ready() && strings.TrimSpace(g.RelayURL) != "" }

func (g *WxGateway) relayTarget() string {
	if t := strings.TrimSpace(g.RelayTarget); wxRelayTargetRE.MatchString(t) {
		return t
	}
	return wxRelayTargetDef
}

// wxRelayOn: inside WeChat, the relay's road is configured.
func (s *Server) wxRelayOn() bool { return s.WxGW.relayReady() && s.Store != nil }

// wxRelaySig is the relay's signature, the same bytes as workbench's
// routes/wxOauthRelay sign() and space's relaySignature.
func wxRelaySig(key, target, nonce, openid, ts string) string {
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(target + "." + nonce + "." + openid + "." + ts))
	return hex.EncodeToString(m.Sum(nil))
}

// wxRelayStart sends WeChat's browser to the silent authorisation, its
// nonce bound to this browser by the flow cookie.
func (s *Server) wxRelayStart(w http.ResponseWriter, r *http.Request) {
	nonce, err := randomToken(24)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not start sign-in")
		return
	}
	g := s.WxGW
	f := wechatFlow{State: nonce, Road: wechatRoadRelay, Exp: time.Now().Add(wxRelaySkew).Unix()}
	flow, _ := json.Marshal(f)
	http.SetCookie(w, &http.Cookie{
		Name: wechatFlowCookie, Value: signBlob(flow, s.sessionKey()), Path: wechatFlowPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(wxRelaySkew.Seconds()),
	})
	appid := g.appID()
	state := g.relayTarget() + "." + nonce + "." + appid
	w.Header().Set("Cache-Control", "no-store")
	// WeChat wants its parameters in this order and the fragment last.
	http.Redirect(w, r, strings.TrimRight(orDefault(g.AuthorizeBase, wechatAuthorizeBase), "/")+wxRelayAuthorizeEP+
		"?appid="+url.QueryEscape(appid)+"&redirect_uri="+url.QueryEscape(strings.TrimSpace(g.RelayURL))+
		"&response_type=code&scope=snsapi_base&state="+url.QueryEscape(state)+
		"&component_appid="+url.QueryEscape(orDefault(strings.TrimSpace(g.ComponentAppID), wxComponentAppID))+
		"#wechat_redirect", http.StatusFound)
}

// handleWxRelayCB is where the relay sends the browser back: check it, then
// land the person.
func (s *Server) handleWxRelayCB(w http.ResponseWriter, r *http.Request) {
	if !s.wxRelayOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var flow wechatFlow
	if c, err := r.Cookie(wechatFlowCookie); err == nil {
		if raw, ok := verifyBlob(c.Value, s.sessionKey()); ok {
			_ = json.Unmarshal(raw, &flow)
		}
	}
	clearCookie(w, r, wechatFlowCookie, wechatFlowPath)
	now := time.Now()
	q := r.URL.Query()
	nonce := q.Get("n")
	if flow.Road != wechatRoadRelay || flow.State == "" || flow.Exp < now.Unix() || nonce == "" ||
		!constantTimeEqual(nonce, flow.State) {
		// Not a hop this browser started (or it is too old): nobody is
		// signed in by a callback that arrives in another browser.
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	if e := q.Get("err"); e != "" || q.Get("o") == "" {
		if !wxRelayErrRE.MatchString(e) {
			e = "?"
		}
		log.Printf("wechat relay: came back without an openid (%s)", e)
		http.Redirect(w, r, appURL("/signin")+"?e=wechat", http.StatusFound)
		return
	}
	openid, ts, sig := q.Get("o"), q.Get("t"), q.Get("sig")
	t, terr := strconv.ParseInt(ts, 10, 64)
	if !wxOpenidRE.MatchString(openid) || terr != nil || strconv.FormatInt(t, 10) != ts ||
		now.Sub(time.Unix(t, 0)).Abs() > wxRelaySkew ||
		!hmac.Equal([]byte(sig), []byte(wxRelaySig(s.WxGW.Token, s.WxGW.relayTarget(), nonce, openid, ts))) {
		log.Printf("wechat relay: callback refused (signature or time)")
		http.Redirect(w, r, appURL("/signin")+"?e=wechat", http.StatusFound)
		return
	}
	// One use, on either replica: a replayed callback is refused here.
	if ok, err := s.Store.SpendSigninValue(spentHash("wx-relay", nonce), time.Unix(flow.Exp, 0), now); err != nil || !ok {
		if err != nil {
			log.Printf("wechat relay: %v", err)
		}
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	u, err := s.WxGW.userInfo(r.Context(), openid)
	if err != nil {
		log.Printf("wechat relay: user/info: %v", err)
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-down", http.StatusFound)
		return
	}
	s.wxLand(w, r, u, now)
}
