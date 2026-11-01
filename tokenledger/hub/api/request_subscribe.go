package api

import (
	"context"
	"crypto/sha1" // WeChat JS-SDK's required signature algorithm.
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

const applySubscribePath = "/apply/subscribe"
const applySubscribeJSPath = "/apply/subscribe.js"

type wxSDKConfig struct {
	AppID     string `json:"appId"`
	Timestamp int64  `json:"timestamp"`
	Nonce     string `json:"nonceStr"`
	Signature string `json:"signature"`
}

func (g *WxGateway) sdkConfig(ctx context.Context, pageURL string) (wxSDKConfig, error) {
	g.jsMu.Lock()
	defer g.jsMu.Unlock()
	now := g.now()
	if g.jsTicket == "" || !now.Before(g.jsTicketExp) {
		var out struct {
			wxErr
			Ticket  string `json:"ticket"`
			Expires int    `json:"expires_in"`
		}
		if err := g.call(ctx, "/cgi-bin/ticket/getticket?type=jsapi", nil, &out); err != nil {
			return wxSDKConfig{}, err
		}
		if out.Ticket == "" || out.Expires <= 60 {
			return wxSDKConfig{}, errWxDown
		}
		g.jsTicket, g.jsTicketExp = out.Ticket, now.Add(time.Duration(out.Expires-60)*time.Second)
	}
	nonce, err := randomToken(18)
	if err != nil {
		return wxSDKConfig{}, err
	}
	c := wxSDKConfig{AppID: g.appID(), Timestamp: now.Unix(), Nonce: nonce}
	raw := fmt.Sprintf("jsapi_ticket=%s&noncestr=%s&timestamp=%d&url=%s", g.jsTicket, c.Nonce, c.Timestamp, pageURL)
	c.Signature = fmt.Sprintf("%x", sha1.Sum([]byte(raw)))
	return c, nil
}

// The button belongs to the pending application, after submission. Only the
// authenticated applicant's service-account openid can receive its result.
func (s *Server) applySubscribeView(r *http.Request, v *applyView) {
	if !s.WxGW.ready() || s.WxGW.SubReview == "" || v.Screen != "pending" || v.R == nil ||
		v.R.NotifyChannel != store.NotifyWeChat || !strings.Contains(strings.ToLower(r.UserAgent()), "micromessenger") {
		return
	}
	reach, err := s.noticeReach(store.Notice{Owner: store.ApplicantReachOwner(v.R.Kind, v.R.Subject)})
	if err != nil || reach.OpenID == "" {
		return
	}
	base := s.publicHostURL(r)
	if base == "" {
		base = s.humanURL(r)
	}
	u, err := url.Parse(base)
	if err != nil || !strings.EqualFold(u.Host, r.Host) {
		return
	}
	c, err := s.WxGW.sdkConfig(r.Context(), strings.TrimRight(base, "/")+r.URL.RequestURI())
	if err != nil {
		return
	}
	b, err := json.Marshal(c)
	if err != nil {
		return
	}
	v.SubscribeTemplate, v.SubscribeConfig = s.WxGW.SubReview, string(b)
}

func (s *Server) handleApplySubscribe(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, 405, "POST only")
		return
	}
	if !sameOrigin(r) {
		httpError(w, 403, "cross-site request refused")
		return
	}
	if s.Store == nil || !s.WxGW.ready() || s.WxGW.SubReview == "" {
		http.NotFound(w, r)
		return
	}
	a, _, to := s.applyWho(r)
	if to != "" {
		httpError(w, 401, "sign in first")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	if err := r.ParseForm(); err != nil {
		httpError(w, 400, "bad form")
		return
	}
	req, err := s.Store.Requests().Get(r.PostForm.Get("id"))
	if err != nil {
		httpError(w, 503, "try again")
		return
	}
	if req == nil || req.Kind != a.Kind || req.Subject != a.Subject {
		http.NotFound(w, r)
		return
	}
	if req.State != store.RequestPending || req.NotifyChannel != store.NotifyWeChat {
		httpError(w, 409, "request no longer waiting for a WeChat result")
		return
	}
	if r.PostForm.Get("template") != s.WxGW.SubReview {
		httpError(w, 400, "template changed; reload the page")
		return
	}
	reach, err := s.noticeReach(store.Notice{Owner: store.ApplicantReachOwner(a.Kind, a.Subject)})
	if err != nil || reach.OpenID == "" {
		httpError(w, 503, "WeChat unavailable")
		return
	}
	if granted, err := s.Store.GrantRequestSubscribe(req.ID, a.Kind, a.Subject, reach.OpenID, s.WxGW.SubReview); err != nil {
		httpError(w, 503, "try again")
		return
	} else if !granted {
		httpError(w, 409, "request already decided or notification already attempted")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (g *WxGateway) subscribeSend(ctx context.Context, openid, tpl, link string, data map[string]string) error {
	d := map[string]wxTplField{}
	for k, v := range data {
		d[k] = wxTplField{v}
	}
	var out wxErr
	return g.call(ctx, "/cgi-bin/message/subscribe/bizsend", map[string]any{"touser": openid, "template_id": tpl, "page": link, "data": d}, &out)
}

func (s *Server) handleApplySubscribeJS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		httpError(w, 405, "GET only")
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodHead {
		_, _ = w.Write([]byte(applySubscribeJS))
	}
}

const applySubscribeJS = `(function(){
var box=document.getElementById('review-subscribe'),tag=document.getElementById('review-subscribe-tag');
if(!box||!tag||!window.wx)return;
var cfg=JSON.parse(box.dataset.config), status=document.getElementById('review-subscribe-status');
function hide(){box.hidden=true;}
tag.addEventListener('error',hide);
document.addEventListener('WeixinOpenTagsError',hide);
tag.addEventListener('success',async function(e){
 var details;try{details=JSON.parse(e.detail.subscribeDetails);}catch(_){return;}
 var accepted=details[tag.getAttribute('template')];
 if(typeof accepted==='string'){try{accepted=JSON.parse(accepted);}catch(_){}}
 if(accepted!=='accept'&&(!accepted||accepted.status!=='accept'))return;
 var body=new URLSearchParams({id:box.dataset.request,template:tag.getAttribute('template')});
 try{var res=await fetch('/apply/subscribe',{method:'POST',body:body,credentials:'same-origin'});
 if(!res.ok)throw Error();status.textContent=box.dataset.ok;tag.hidden=true;
 }catch(_){status.textContent=box.dataset.failed;}
});
wx.ready(function(){box.hidden=false;});wx.error(hide);
cfg.jsApiList=['updateAppMessageShareData'];cfg.openTagList=['wx-open-subscribe'];wx.config(cfg);
})();`

// The new-request template is also used by existing administrator alerts.
// Keep their semantic values and adapt the field keys at the gateway boundary.
func (s *Server) newReqTemplateFields(old map[string]string) map[string]string {
	if s.WxGW.NewReqFields == "" {
		return old
	}
	values := map[string]string{"platform": old["thing1"], "person": old["thing2"], "time": old["time6"], "count": old["character_string10"]}
	out := map[string]string{}
	for _, field := range strings.Split(s.WxGW.NewReqFields, ",") {
		key, value, ok := strings.Cut(strings.TrimSpace(field), "=")
		if ok && key != "" && values[value] != "" {
			out[key] = values[value]
		}
	}
	return out
}
