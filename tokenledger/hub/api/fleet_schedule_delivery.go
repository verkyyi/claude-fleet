package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func (s *Server) scheduleLivePageConsent(owner string) bool {
	rows, e := s.Store.Schedules(owner)
	if e != nil {
		return false
	}
	for _, r := range rows {
		if r.Spec.Delivery.LivePage {
			return true
		}
	}
	return false
}
func (s *Server) scheduleMember(owner string) bool {
	u, e := s.personRow(owner)
	return e == nil && u != nil && (u.Role == roleUser || u.Role == roleAdmin)
}

// Same partner, person seal, lock and credential book as the interactive live
// page path. A full member opts in by saving delivery.livepage; trial expiry is
// still authoritative. No workspace token is returned to a browser/session.
func (s *Server) schedulePageKey(ctx context.Context, owner string, consentAt int64) (string, error) {
	if !s.scheduleLivePageConsent(owner) {
		return "", errors.New("live page delivery was disabled")
	}
	if !s.LivePage.ready() || s.Vault == nil {
		return "", errors.New("live page connection is temporarily unavailable")
	}
	now := time.Now()
	settings, e := s.Store.FleetSettings()
	if e != nil {
		return "", e
	}
	if s.livePageEnd(settings, owner, now) != "" {
		return "", errors.New("account is not eligible")
	}
	openid := s.livePageOpenID(owner)
	if openid == "" {
		return "", errors.New("bind your WeChat in My account to publish a private page")
	}
	mu := livePageLock(owner)
	mu.Lock()
	defer mu.Unlock()
	c, e := s.Store.PartnerCred(owner, store.PartnerLivePage)
	if e != nil {
		return "", e
	}
	if c.Live(now) {
		var key string
		if s.Vault.OpenPerson(c.Sealed, &key, owner, livePagePurpose) == nil && key != "" {
			return key, nil
		}
	}
	until := livePageUntil(settings, owner, now)
	token, _, e := s.LivePage.Provision(ctx, livePageProvision{OpenID: openid, UnionID: s.livePageUnionID(owner), Source: "tokenman-schedule", ConsentTerms: "tokenman-schedule-private-page-v1", ConsentAt: time.Unix(consentAt, 0).UTC().Format(time.RFC3339), Until: until.UTC().Format(time.RFC3339)})
	if e != nil {
		return "", errors.New("private page account could not be prepared")
	}
	sealed, e := s.Vault.SealPerson(token, owner, livePagePurpose)
	if e != nil {
		return "", e
	}
	if e = s.Store.PutPartnerCred(owner, store.PartnerLivePage, openid, sealed, until, now); e != nil {
		return "", e
	}
	return token, nil
}

type scheduleSpace struct {
	server         *Server
	token, session string
	seq            int
}

func (m *scheduleSpace) rpc(ctx context.Context, method string, params any) (map[string]any, error) {
	m.seq++
	envelope := map[string]any{"jsonrpc": "2.0", "id": m.seq, "method": method, "params": params}
	notification := strings.HasPrefix(method, "notifications/")
	if notification {
		delete(envelope, "id")
	}
	body, _ := json.Marshal(envelope)
	req, e := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(m.server.LivePage.URL, "/")+"/mcp", bytes.NewReader(body))
	if e != nil {
		return nil, e
	}
	req.Header.Set("Authorization", "Bearer "+m.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("MCP-Protocol-Version", "2025-03-26")
	if m.session != "" {
		req.Header.Set("Mcp-Session-Id", m.session)
	}
	resp, e := m.server.LivePage.client().Do(req)
	if e != nil {
		return nil, errors.New("live page request not confirmed")
	}
	defer resp.Body.Close()
	if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" {
		m.session = sid
	}
	raw, e := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if e != nil {
		return nil, e
	}
	if notification && (resp.StatusCode == 200 || resp.StatusCode == 202 || resp.StatusCode == 204) {
		return nil, nil
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("live page refused (%d)", resp.StatusCode)
	}
	messages := [][]byte{raw}
	if strings.Contains(resp.Header.Get("Content-Type"), "text/event-stream") {
		messages = nil
		for _, line := range bytes.Split(raw, []byte("\n")) {
			if bytes.HasPrefix(line, []byte("data:")) {
				messages = append(messages, bytes.TrimSpace(line[5:]))
			}
		}
	}
	for _, raw := range messages {
		var msg struct {
			ID     int             `json:"id"`
			Result map[string]any  `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if json.Unmarshal(raw, &msg) != nil || msg.ID != m.seq {
			continue
		}
		if len(msg.Error) > 0 {
			return nil, errors.New("live page tool refused")
		}
		return msg.Result, nil
	}
	return nil, errors.New("live page response was not confirmed")
}
func (m *scheduleSpace) tool(ctx context.Context, name string, args any) (map[string]any, error) {
	r, e := m.rpc(ctx, "tools/call", map[string]any{"name": name, "arguments": args})
	if e != nil {
		return nil, e
	}
	if r["isError"] == true {
		return nil, errors.New("live page tool could not publish")
	}
	if structured, ok := r["structuredContent"].(map[string]any); ok {
		return structured, nil
	}
	if blocks, ok := r["content"].([]any); ok {
		for _, block := range blocks {
			b, _ := block.(map[string]any)
			var data map[string]any
			if json.Unmarshal([]byte(asString(b["text"])), &data) == nil {
				return data, nil
			}
		}
	}
	return r, nil
}
func (s *Server) schedulePageDelivery(ctx context.Context, n store.Notice, now time.Time) {
	fail := func(why string) { s.retryNotice(n, now, "schedule page", []string{why}) }
	if len(n.Refs) != 1 {
		_ = s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "", now)
		return
	}
	run, e := s.Store.ScheduleRun(n.Owner, n.Refs[0])
	if e != nil {
		fail("result unavailable")
		return
	}
	row, e := s.Store.Schedule(n.Owner, run.ScheduleID)
	if e != nil {
		fail("task unavailable")
		return
	}
	var delivery map[string]any
	_ = json.Unmarshal(run.Delivery, &delivery)
	if delivery == nil {
		delivery = map[string]any{}
	}
	save := func(state string) {
		delivery["livepage"] = state
		b, _ := json.Marshal(delivery)
		_ = s.Store.ScheduleDelivery(n.Owner, run.ID, b)
	}
	if asString(delivery["livepage"]) == "sent" {
		_ = s.Store.FinishNotice(n.ID, store.NoticeSent, "livepage", now)
		return
	}
	// After an ambiguous publish, never blindly publish the same run twice.
	// Its conclusion remains in Tokenman and the UI says delivery is unconfirmed.
	if state := asString(delivery["livepage"]); state == "publishing" || state == "unconfirmed" {
		save("unconfirmed")
		_ = s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "livepage", now)
		return
	}
	var snapshot struct {
		Consent struct {
			LivePage bool `json:"livepage"`
		} `json:"consent"`
		At int64 `json:"consent_at"`
	}
	_ = json.Unmarshal(run.Delivery, &snapshot)
	if !snapshot.Consent.LivePage || !row.Spec.Delivery.LivePage || row.Spec.Deleted {
		save("cancelled")
		_ = s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "livepage", now)
		return
	}
	key, e := s.schedulePageKey(ctx, n.Owner, snapshot.At)
	if e != nil {
		save("pending")
		fail(e.Error())
		return
	}
	page, _, e := s.Store.SchedulePage(n.Owner, row.Spec.ID)
	if e != nil {
		fail("page identity unavailable")
		return
	}
	m := &scheduleSpace{server: s, token: key}
	if _, e = m.rpc(ctx, "initialize", map[string]any{"protocolVersion": "2025-03-26", "capabilities": map[string]any{}, "clientInfo": map[string]string{"name": "tokenman-schedule", "version": "1"}}); e != nil {
		fail("live page connection unavailable")
		return
	}
	if _, e = m.rpc(ctx, "notifications/initialized", map[string]any{}); e != nil {
		fail("live page initialization unavailable")
		return
	}
	// Once a receipt exists, poll that version; never publish this run twice.
	if version := asString(delivery["version_id"]); version != "" {
		out, err := m.tool(ctx, "get_version", map[string]any{"version_id": version})
		if err != nil {
			fail("version status unavailable")
			return
		}
		if asString(out["status"]) == "published" {
			save("sent")
			_ = s.Store.FinishNotice(n.ID, store.NoticeSent, "livepage", now)
		} else {
			save("processing")
			fail("page is still processing or awaiting review")
		}
		return
	}
	if page != "" {
		// Explicit private delivery also applies to an existing page. Do not
		// append a confidential conclusion unless privacy is acknowledged.
		out, err := m.tool(ctx, "set_visibility", map[string]any{"proposal_id": page, "visibility": "private"})
		if err != nil || asString(out["visibility"]) != "private" {
			fail("private visibility not confirmed")
			return
		}
	}
	content := "<!doctype html><html lang=\"zh\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" + html.EscapeString(row.Spec.Name) + "</title><body style=\"max-width:48rem;margin:auto;padding:24px;font:16px/1.8 system-ui\"><h1>" + html.EscapeString(row.Spec.Name) + "</h1><p>" + time.Unix(run.Started, 0).UTC().Format(time.RFC3339) + "</p><div style=\"white-space:pre-wrap;overflow-wrap:anywhere\">" + html.EscapeString(run.Summary) + "</div></body></html>"
	args := map[string]any{"filename": "index.html", "content": content, "quiet": true, "note": "定时任务结果"}
	if page != "" {
		args["proposal_id"] = page
	} else {
		args["title"] = row.Spec.Name
	}
	save("publishing")
	out, e := m.tool(ctx, "publish_file", args)
	if e != nil {
		save("unconfirmed")
		_ = s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "livepage", now)
		return
	}
	if id := asString(out["proposal_id"]); id != "" {
		page = id
	}
	url := asString(out["url"])
	if page == "" || !strings.HasPrefix(url, "https://") {
		save("unconfirmed")
		_ = s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "livepage", now)
		return
	}
	if e = s.Store.SaveSchedulePage(n.Owner, row.Spec.ID, page, url); e != nil {
		save("unconfirmed")
		return
	}
	delivery["url"] = url
	version := asString(out["version_id"])
	if v, ok := out["version"].(map[string]any); ok && version == "" {
		version = asString(v["id"])
	}
	if version != "" {
		delivery["version_id"] = version
	}
	if asString(out["status"]) == "published" {
		save("sent")
		_ = s.Store.FinishNotice(n.ID, store.NoticeSent, "livepage", now)
	} else if version != "" {
		save("processing")
		fail("page is processing or awaiting review")
	} else {
		save("unconfirmed")
		_ = s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "livepage", now)
	}
}
