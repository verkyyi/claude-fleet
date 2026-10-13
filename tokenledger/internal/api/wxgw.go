package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The company service account, through the company's workbench
// (claude-fleet#4054, EPIC #4048 共同约定 3). The hub holds no secret of the
// service account 「二四网络科技」: its access token comes from workbench-api's
// in-cluster endpoint GET /internal/wx/token, and who scanned one of our codes
// from GET /internal/wx/fleet-scan-login — workbench receives every scan event
// of the account and hands ClaudeFleet's own range to us (monorepo #12138).
// The gate is one header, x-internal-token = CCQUOTA_WX_INTERNAL_TOKEN, the
// same value as workbench's WX_INTERNAL_TOKEN. It can mint the whole
// account's access token, so this file is the ONE place it is read: it never
// enters a log, an audit row, an error text or a page (BREAK-IT
// notify-leaks-secret).
//
// The token itself is used against api.weixin.qq.com for two calls —
// qrcode/create and user/info — and kept in memory until shortly before
// workbench says it expires.

// WxGateway is the service account's road: CCQUOTA_WX_INTERNAL_URL (e.g.
// http://workbench-backend.new-deploy.svc.cluster.local/internal/wx) and
// CCQUOTA_WX_INTERNAL_TOKEN. Both set, or the road is off — and with it off
// the sign-in page is what it was.
type WxGateway struct {
	URL   string
	Token string
	// AppID is the service account; empty means 「二四网络科技」.
	AppID string
	// APIBase is WeChat's API; empty means https://api.weixin.qq.com. Tests
	// point it at a fake.
	APIBase string
	// HTTP is the client; nil means one with a 10-second timeout.
	HTTP *http.Client

	// The web-authorisation relay (claude-fleet#4055, wx_relay.go):
	// RelayURL is workbench's GET /node_w/wx/oauth/relay (CCQUOTA_WX_RELAY_URL),
	// empty = off; RelayTarget our name in its WX_OAUTH_RELAY_TARGETS (empty
	// means "fleet"); ComponentAppID the third-party platform that authorises
	// for the account (empty means the company's); AuthorizeBase WeChat's
	// authorize host (empty means the real one; tests point it at a fake).
	RelayURL, RelayTarget, ComponentAppID, AuthorizeBase string

	mu      sync.Mutex
	tok     string
	tokExp  time.Time
	nowFunc func() time.Time
}

// wxServiceAppID is the service account 「二四网络科技」 (hosted by the company's
// third-party platform; space, 拓客 and 灵声 use it too).
const wxServiceAppID = "wxec2b6c9e4bc47af8"

// The scene_id range that is ClaudeFleet's (registered as kind fleet in
// workbench's wxSceneRanges.js): the hub draws codes only inside it, and asks
// workbench only about numbers inside it.
const (
	wxSceneMin = 3000000
	wxSceneMax = 4000000 // exclusive
)

func wxSceneInRange(n int64) bool { return n >= wxSceneMin && n < wxSceneMax }

func (g *WxGateway) ready() bool {
	return g != nil && strings.TrimSpace(g.URL) != "" && strings.TrimSpace(g.Token) != ""
}

func (g *WxGateway) appID() string { return orDefault(g.AppID, wxServiceAppID) }

func (g *WxGateway) apiBase() string {
	return strings.TrimRight(orDefault(g.APIBase, wechatAPIBase), "/")
}

func (g *WxGateway) client() *http.Client {
	if g.HTTP != nil {
		return g.HTTP
	}
	return &http.Client{Timeout: 10 * time.Second}
}

func (g *WxGateway) now() time.Time {
	if g.nowFunc != nil {
		return g.nowFunc()
	}
	return time.Now()
}

// errWxDown is every failure to reach the service account, said the same
// way: what the person sees is 「微信暂时不可用」, never why.
var errWxDown = errors.New("the service account cannot be reached")

// internal GETs path from workbench's /internal/wx with the gate header.
// status is the HTTP status; the body is decoded into out on a 200.
func (g *WxGateway) internal(ctx context.Context, path string, out any) (status int, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(g.URL, "/")+path, nil)
	if err != nil {
		return 0, errWxDown
	}
	req.Header.Set("x-internal-token", g.Token)
	resp, err := g.client().Do(req)
	if err != nil {
		return 0, errWxDown
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
		return resp.StatusCode, nil
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(out); err != nil {
		return resp.StatusCode, errWxDown
	}
	return resp.StatusCode, nil
}

// accessToken is the service account's current token, from workbench, kept
// until a minute before it expires. drop forgets the kept one first (WeChat
// said it is no longer good).
func (g *WxGateway) accessToken(ctx context.Context, drop bool) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if !drop && g.tok != "" && now.Before(g.tokExp) {
		return g.tok, nil
	}
	g.tok = ""
	var got struct {
		AccessToken string `json:"access_token"`
		ExpiresAt   int64  `json:"expires_at"`
	}
	st, err := g.internal(ctx, "/token?appid="+url.QueryEscape(g.appID()), &got)
	if err != nil || st != http.StatusOK || got.AccessToken == "" {
		return "", errWxDown
	}
	exp := time.Unix(got.ExpiresAt, 0).Add(-time.Minute)
	if got.ExpiresAt == 0 || exp.After(now.Add(time.Hour)) {
		exp = now.Add(5 * time.Minute)
	}
	g.tok, g.tokExp = got.AccessToken, exp
	return g.tok, nil
}

// wxTokenGone: WeChat's errcodes for a token that is no longer good.
func wxTokenGone(code int) bool { return code == 40001 || code == 40014 || code == 42001 }

// call does one api.weixin.qq.com call with the token (a POST when body is
// not nil), once more with a fresh token when WeChat says the kept one is
// gone. out must carry an `errcode` field; its errcode is returned.
func (g *WxGateway) call(ctx context.Context, path string, body any, out interface {
	code() int
	reset()
}) error {
	for attempt := 0; attempt < 2; attempt++ {
		tok, err := g.accessToken(ctx, attempt > 0)
		if err != nil {
			return err
		}
		sep := "?"
		if strings.Contains(path, "?") {
			sep = "&"
		}
		method, rd := http.MethodGet, io.Reader(nil)
		if body != nil {
			b, _ := json.Marshal(body)
			method, rd = http.MethodPost, bytes.NewReader(b)
		}
		req, err := http.NewRequestWithContext(ctx, method, g.apiBase()+path+sep+"access_token="+url.QueryEscape(tok), rd)
		if err != nil {
			return errWxDown
		}
		resp, err := g.client().Do(req)
		if err != nil {
			return errWxDown
		}
		out.reset()
		err = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(out)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || err != nil {
			return errWxDown
		}
		if wxTokenGone(out.code()) && attempt == 0 {
			continue
		}
		if c := out.code(); c != 0 {
			// The code only: WeChat's errmsg can echo the request, token included.
			return fmt.Errorf("%w (errcode %d)", errWxDown, c)
		}
		return nil
	}
	return errWxDown
}

type wxErr struct {
	ErrCode int `json:"errcode"`
}

func (e *wxErr) code() int { return e.ErrCode }
func (e *wxErr) reset()    { e.ErrCode = 0 }

// qrCreate draws a temporary follow-and-scan code for scene, good for ttl:
// what the code encodes (WeChat's own short link).
func (g *WxGateway) qrCreate(ctx context.Context, scene int64, ttl time.Duration) (string, error) {
	if !wxSceneInRange(scene) {
		return "", fmt.Errorf("scene %d is not ClaudeFleet's", scene)
	}
	var out struct {
		wxErr
		Ticket string `json:"ticket"`
		URL    string `json:"url"`
	}
	body := map[string]any{
		"expire_seconds": int(ttl.Seconds()),
		"action_name":    "QR_SCENE",
		"action_info":    map[string]any{"scene": map[string]any{"scene_id": scene}},
	}
	if err := g.call(ctx, "/cgi-bin/qrcode/create", body, &out); err != nil {
		return "", err
	}
	if out.URL == "" {
		return "", errWxDown
	}
	return out.URL, nil
}

// scanOpenid is who scanned code scene: the openid, "" while nobody has (or
// it expired — workbench cannot tell those apart). Only ClaudeFleet's range
// is ever asked about (BREAK-IT fleet-scene-cross).
func (g *WxGateway) scanOpenid(ctx context.Context, scene int64) (string, error) {
	if !wxSceneInRange(scene) {
		return "", fmt.Errorf("scene %d is not ClaudeFleet's", scene)
	}
	var out struct {
		OpenID string `json:"openid"`
	}
	st, err := g.internal(ctx, "/fleet-scan-login?scene="+strconv.FormatInt(scene, 10), &out)
	switch {
	case err != nil:
		return "", err
	case st == http.StatusNotFound:
		return "", nil
	case st != http.StatusOK || out.OpenID == "":
		return "", errWxDown
	}
	return out.OpenID, nil
}

// wxUser is what user/info says of a follower.
type wxUser struct {
	OpenID   string
	UnionID  string // "" when the account is not bound to the open platform, or they don't follow
	Followed bool
	Nickname string // WeChat no longer sends one; kept for a stand-in that does
}

// userInfo asks WeChat about openid.
func (g *WxGateway) userInfo(ctx context.Context, openid string) (wxUser, error) {
	var out struct {
		wxErr
		Subscribe int    `json:"subscribe"`
		UnionID   string `json:"unionid"`
		Nickname  string `json:"nickname"`
	}
	q := url.Values{"openid": {openid}, "lang": {"zh_CN"}}
	if err := g.call(ctx, "/cgi-bin/user/info?"+q.Encode(), nil, &out); err != nil {
		return wxUser{}, err
	}
	return wxUser{OpenID: openid, UnionID: strings.TrimSpace(out.UnionID), Followed: out.Subscribe == 1,
		Nickname: strings.TrimSpace(out.Nickname)}, nil
}
