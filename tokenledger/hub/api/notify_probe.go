package api

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// WxNotifyProbe is the redacted receipt of an operator's deployment check.
// No openid, credential, request content or gateway response text leaves it.
type WxNotifyProbe struct {
	Template     string            `json:"template_id"`
	Subscription string            `json:"subscription_id"`
	Fields       map[string]string `json:"data"`
	Sent         bool              `json:"sent"`
	ErrCode      int               `json:"errcode"`
}

// ProbeWxNewRequest is CLI-only: use the running pod's environment and the
// desk's gateway/field builders. A dry run reads the registry and JS-SDK ticket;
// a real run sends exactly one labelled test to one explicitly named admin.
func (s *Server) ProbeWxNewRequest(ctx context.Context, login string, dryRun bool) (WxNotifyProbe, error) {
	out := WxNotifyProbe{}
	if s.Store == nil || !s.WxGW.ready() || s.WxGW.TplNewReq == "" || s.WxGW.SubReview == "" || s.WxGW.NewReqFields == "" {
		return out, errors.New("WeChat gateway, new-request mapping and review subscription must be configured")
	}
	reach, err := s.probeWxAdmin(login)
	if err != nil {
		return out, err
	}
	m := newReqMsg([]store.AccessRequest{{ID: "template-probe", Display: "【测试】申请提醒", CreatedAt: time.Now()}}, false, s.humanURL(nil))
	out.Template, out.Subscription = s.WxGW.TplNewReq, s.WxGW.SubReview
	out.Fields = s.newReqTemplateFields(m.Tpl)
	var templates struct {
		wxErr
		List []struct {
			ID      string `json:"template_id"`
			Title   string `json:"title"`
			Content string `json:"content"`
		} `json:"template_list"`
	}
	if err := s.WxGW.call(ctx, "/cgi-bin/template/get_all_private_template", nil, &templates); err != nil {
		return out, err
	}
	registered := false
	for _, tpl := range templates.List {
		if tpl.ID != out.Template || tpl.Title != "软件注册申请待审核通知" {
			continue
		}
		registered = len(out.Fields) > 0
		for field := range out.Fields {
			if !strings.Contains(tpl.Content, "{{"+field+".DATA}}") {
				registered = false
			}
		}
		for _, line := range strings.Split(tpl.Content, "{{")[1:] {
			field, _, ok := strings.Cut(line, ".DATA}}")
			if ok && out.Fields[field] == "" {
				registered = false
			}
		}
	}
	if !registered {
		return out, errors.New("new-request template is not registered with the expected title and fields")
	}
	var subs struct {
		wxErr
		List []struct {
			ID      string `json:"priTmplId"`
			Type    int    `json:"type"`
			Content string `json:"content"`
		} `json:"data"`
	}
	if err := s.WxGW.call(ctx, "/wxaapi/newtmpl/gettemplate", nil, &subs); err != nil {
		return out, err
	}
	registered = false
	for _, tpl := range subs.List {
		if tpl.ID != out.Subscription || tpl.Type != 2 {
			continue
		}
		registered = true
		for _, field := range []string{"thing1", "phrase5", "time24", "character_string19"} {
			if !strings.Contains(tpl.Content, "{{"+field+".DATA}}") {
				registered = false
			}
		}
	}
	if !registered {
		return out, errors.New("review subscription is not registered as one-time with the expected fields")
	}
	// A valid ticket proves the gateway/SDK credential road, not the public
	// platform's JS domain allowlist. A real WeChat browser must check that.
	if _, err := s.WxGW.sdkConfig(ctx, s.wechatNotice(s.humanURL(nil)+ApplyPath)); err != nil {
		return out, err
	}
	if dryRun {
		return out, nil
	}
	err = s.WxGW.templateSend(ctx, reach.OpenID, out.Template, s.wechatNotice(s.humanURL(nil)+AdminPrefix+"/requests"), out.Fields)
	if err != nil {
		out.ErrCode = wxCode(err)
		return out, err
	}
	out.Sent = true
	return out, nil
}

// probeWxAdmin restricts deployment tests to an explicitly named, followed admin.
func (s *Server) probeWxAdmin(login string) (reachOf, error) {
	users, err := s.Store.HubUsers()
	if err != nil {
		return reachOf{}, errors.New("could not read administrators")
	}
	var owner string
	for _, u := range users {
		if strings.EqualFold(u.Login, login) && u.Role == roleAdmin {
			if owner != "" {
				return reachOf{}, errors.New("administrator is ambiguous")
			}
			owner = u.PrincipalID
		}
	}
	if owner == "" {
		return reachOf{}, errors.New("named administrator not found")
	}
	reach, err := s.noticeReach(store.Notice{Owner: owner})
	if err != nil || reach.OpenID == "" || !reach.Followed {
		return reachOf{}, errors.New("administrator has no followed service-account identity")
	}
	return reach, nil
}

// ProbeWxReview verifies the existing approval-result template road without
// creating or approving an application, recording consent, or requiring JS-SDK.
func (s *Server) ProbeWxReview(ctx context.Context, login string, dryRun bool) (WxNotifyProbe, error) {
	out := WxNotifyProbe{}
	if s.Store == nil || !s.WxGW.ready() || s.WxGW.TplReview == "" {
		return out, errors.New("WeChat gateway and review template must be configured")
	}
	reach, err := s.probeWxAdmin(login)
	if err != nil {
		return out, err
	}
	m := reviewMsg(&store.AccessRequest{ID: "review-probe", State: store.RequestApproved, DecidedAt: time.Now()}, false, s.humanURL(nil))
	m.Tpl["thing3"] = "【测试】审批结果通知"
	out.Template, out.Fields = s.wxTemplate(store.NotifyKindReview), m.Tpl
	if dryRun {
		return out, nil
	}
	if err := s.WxGW.templateSend(ctx, reach.OpenID, out.Template, s.wechatNotice(m.Link), out.Fields); err != nil {
		out.ErrCode = wxCode(err)
		return out, err
	}
	out.Sent = true
	return out, nil
}
