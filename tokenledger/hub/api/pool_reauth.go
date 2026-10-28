package api

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A pool credential that went bad is found, told and shown (claude-fleet
// FKS6). Until now a setup token the upstream refused on every quota read
// (Charlie_20X: «HTTP 401 from the messages endpoint» for a week) kept an
// empty refresh_error and no reauth mark: the page could not tell it was
// dead, nothing told an admin, and only the missing plan gave it away.
//
// The hub's own quota reader is the witness. poolReloginAfter refused reads
// in a row (401 / 403 from the upstream — never the relay's own refusal, a
// 429 or a 5xx) spanning at least poolReloginSpan mark the credential
// reauth_required (refresh_error = credvault.QuotaReauthPrefix + why), raise
// pool_relogin and tell every admin on WeChat — at most once a credential in
// poolReauthNoticeEvery. A mark stops the session binder from picking it
// (sessionBindChoices). The reader keeps probing it (Vault.LeaseProbe): the
// first good read lifts the mark and the alert and tells the admins it is
// back. Storing a new credential through 更新凭据 lifts the mark as well (a
// put clears it), and its read right after says it is back.

const (
	// poolReloginSpan is how long the refused reads must span.
	poolReloginSpan = 10 * time.Minute
	// poolReauthNoticeEvery: one credential tells the admins at most once in it.
	poolReauthNoticeEvery = 24 * time.Hour
	// AdminSubsReauthPath lists the pool credentials that need a new login.
	AdminSubsReauthPath = "/v1/admin/subscriptions/reauth"
)

// poolReauthWhy is the mark's refresh_error.
func poolReauthWhy(r HubQuotaRead, n int, since time.Time) string {
	return credvault.QuotaReauthPrefix + fmt.Sprintf("%d in a row since %s (%s)", n, since.UTC().Format(time.RFC3339), truncate(r.Error, 160))
}

// poolReauthMark marks r's credential reauth_required unless it is already;
// true when this call marked it.
func (s *Server) poolReauthMark(r HubQuotaRead, n int, since, at time.Time) bool {
	c, err := s.Store.Credential(r.Owner, r.Provider, r.Account)
	if err != nil || c == nil || c.ReauthRequired || s.Vault == nil || s.Vault.CredentialID(*c) != r.CredentialID {
		return false
	}
	why := poolReauthWhy(r, n, since)
	// An OAuth credential's cached access is what was refused: dropped, so
	// the next probe refreshes instead of reading with it again.
	if err := s.Store.MarkReauthRequired(r.Owner, r.Provider, r.Account, why, c.Kind != credvault.KindSetupToken && c.Kind != credvault.KindAPIKey, at); err != nil {
		log.Printf("pool reauth: mark %s: %v", poolReloginSubject(r), err)
		return false
	}
	_ = s.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredReauth, PrincipalID: r.Owner, Provider: r.Provider,
		Account: r.Account, EndpointID: HubQuotaEndpoint, Detail: why})
	log.Printf("pool reauth: %s marked reauth_required — %d quota reads refused since %s", poolReloginSubject(r), n, since.UTC().Format(time.RFC3339))
	s.BroadcastCreds("pool credential needs a new login")
	return true
}

// poolReauthLift lifts a mark a good read proved wrong: a setup token's (the
// read used the stored token itself) or one the quota reader set. A refresh
// token the provider refused stays marked until a new login is stored.
func (s *Server) poolReauthLift(r HubQuotaRead, at time.Time) bool {
	c, err := s.Store.Credential(r.Owner, r.Provider, r.Account)
	if err != nil || c == nil || !c.ReauthRequired {
		return false
	}
	if c.Kind != credvault.KindSetupToken && c.Kind != credvault.KindAPIKey && !strings.HasPrefix(c.RefreshError, credvault.QuotaReauthPrefix) {
		return false
	}
	cleared, err := s.Store.ClearReauthRequired(r.Owner, r.Provider, r.Account, at)
	if err != nil || !cleared {
		return false
	}
	_ = s.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredReauth, PrincipalID: r.Owner, Provider: r.Provider,
		Account: r.Account, EndpointID: HubQuotaEndpoint, Detail: "cleared: a quota read succeeded"})
	log.Printf("pool reauth: %s works again — mark lifted", poolReloginSubject(r))
	s.BroadcastCreds("pool credential works again")
	return true
}

// adminPrincipals are the hub's admins.
func (s *Server) adminPrincipals() []string {
	users, err := s.Store.HubUsers()
	if err != nil {
		log.Printf("pool reauth: admins: %v", err)
		return nil
	}
	var out []string
	for _, u := range users {
		if u.Role == roleAdmin {
			out = append(out, u.PrincipalID)
		}
	}
	return out
}

// lastPoolNotice is when admin was last told kind about credential id.
func (s *Server) lastPoolNotice(admin, kind, id string) time.Time {
	ns, err := s.Store.NoticesOf(admin, kind)
	if err != nil {
		return time.Time{}
	}
	for _, n := range ns {
		if len(n.Refs) > 0 && n.Refs[0] == id {
			return n.Created
		}
	}
	return time.Time{}
}

// tellPoolReauth tells every admin r's credential needs a new login (once in
// poolReauthNoticeEvery per admin), or — back — that it works again (only
// to an admin told it went bad and not yet told it came back).
func (s *Server) tellPoolReauth(r HubQuotaRead, back bool, at time.Time) {
	if s.Store == nil || r.CredentialID == "" {
		return
	}
	set, _ := s.Store.FleetSettings()
	kind := store.NotifyKindPoolReauth
	if back {
		kind = store.NotifyKindPoolBack
	}
	sent := 0
	for _, admin := range s.adminPrincipals() {
		bad := s.lastPoolNotice(admin, store.NotifyKindPoolReauth, r.CredentialID)
		if back {
			if bad.IsZero() || !s.lastPoolNotice(admin, store.NotifyKindPoolBack, r.CredentialID).Before(bad) {
				continue
			}
		} else if !bad.IsZero() && at.Sub(bad) < poolReauthNoticeEvery {
			continue
		}
		n := store.Notice{ID: fmt.Sprintf("nt-%s-%s-%d-%s", kind, r.CredentialID, at.Unix(), admin), Kind: kind, Owner: admin,
			Lang: parseLang(set[langSettingKey(admin)]), Refs: []string{r.CredentialID, r.Owner, r.Provider, r.Account}}
		if err := s.Store.EnqueueNotice(n, at); err != nil {
			if !isDupNotice(s, n.ID) {
				log.Printf("pool reauth: notice %s: %v", n.ID, err)
			}
			continue
		}
		sent++
	}
	if sent > 0 {
		log.Printf("pool reauth: %s told to %d admin(s): %s", kind, sent, poolReloginSubject(r))
		s.notifyKick()
	}
}

// poolReauthNoticeMsg puts a pool_reauth / pool_back notice into words;
// nothing to say once what it says is no longer so (a mark lifted before a
// bad notice went, marked again before a back notice went).
func (s *Server) poolReauthNoticeMsg(n store.Notice, en bool, base string) (noticeMsg, bool, error) {
	if len(n.Refs) < 4 {
		return noticeMsg{}, false, nil
	}
	id, owner, provider, account := n.Refs[0], n.Refs[1], n.Refs[2], n.Refs[3]
	c, err := s.Store.Credential(owner, provider, account)
	if err != nil {
		return noticeMsg{}, false, nil // deleted since: nothing to fix
	}
	if c == nil || (s.Vault != nil && s.Vault.CredentialID(*c) != id && n.Kind == store.NotifyKindPoolReauth) {
		return noticeMsg{}, false, nil
	}
	back := n.Kind == store.NotifyKindPoolBack
	if c.ReauthRequired == back {
		return noticeMsg{}, false, nil
	}
	return poolReauthMsg(provider, account, poolReauthReason(c.RefreshError, en), back, n.Created, en, base, id), true, nil
}

// poolReauthReason is a mark's why in one sentence.
func poolReauthReason(why string, en bool) string {
	switch {
	case strings.HasPrefix(why, credvault.QuotaReauthPrefix):
		rest := strings.TrimPrefix(why, credvault.QuotaReauthPrefix)
		code := "401/403"
		for _, c := range []string{"401", "403"} {
			if strings.Contains(rest, "HTTP "+c) {
				code = c
			}
		}
		n, _, _ := strings.Cut(rest, " ")
		if en {
			return "the provider refused its last " + n + " quota reads (HTTP " + code + ")"
		}
		return "上游连续 " + n + " 次拒绝读取额度（HTTP " + code + "）"
	case strings.HasPrefix(why, "upstream rejected the setup token"):
		return ternary(en, "the provider refused the token in a session", "会话里上游拒绝了这个凭据")
	case why != "":
		return ternary(en, "the provider refused its refresh token", "上游拒绝了它的刷新令牌")
	}
	return ternary(en, "the provider refused it", "上游拒绝了这个凭据")
}

func poolReauthMsg(provider, account, reason string, back bool, at time.Time, en bool, base, id string) noticeMsg {
	m := noticeMsg{}
	if base != "" {
		m.Link = base + AdminPrefix + "/pool/" + url.PathEscape(id)
	}
	name := clipRunes(oneLine(account), 20)
	svc := ternary(provider == credvault.Codex, "Codex", "Claude")
	var head, advice, short string
	switch {
	case back && en:
		head, advice, short = Brand+": subscription "+name+" works again", "It is back in the pool; nothing to do", " · back"
	case back:
		head, advice, short = Brand+"：订阅「"+name+"」已恢复", "已重新进入调度，无需操作", " · 已恢复"
	case en:
		head, advice, short = Brand+": subscription "+name+" needs a new login", "Sessions no longer use it. Open the pool page and press Update credential to sign in again", " · new login"
	default:
		head, advice, short = Brand+"：订阅「"+name+"」需要重新授权", "已停止派给会话。打开订阅池，点「更新凭据」网页授权即可", " · 需重新授权"
	}
	m.Tpl = map[string]string{
		"thing1":             Brand,
		"thing2":             clipRunes(name+short, 20),
		"time6":              noticeTime(at, false),
		"character_string10": "1",
	}
	m.Subject = head
	line := svc + " · " + account
	if !back {
		line += " · " + reason
	}
	m.Body = head + "\n\n" + line + "\n" + advice + "\n"
	if m.Link != "" {
		m.Body += "\n" + ternary(en, "Open: ", "去处理：") + m.Link + "\n"
	}
	m.Text = head + "\n" + line + "\n" + advice
	if m.Link != "" {
		m.Text += "\n" + m.Link
	}
	return m
}

// PoolReauthItem is one credential AdminSubsReauthPath lists.
type PoolReauthItem struct {
	CredentialID string     `json:"credential_id"`
	Owner        string     `json:"owner"`
	Provider     string     `json:"provider"`
	Account      string     `json:"account"`
	Since        *time.Time `json:"since,omitempty"`
	Reason       string     `json:"reason"`
	ReasonEN     string     `json:"reason_en"`
}

// handleAdminSubsReauth is GET AdminSubsReauthPath: {pending, items} — the
// console's banner and the pool item's count.
func (s *Server) handleAdminSubsReauth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		httpError(w, 405, "GET only")
		return
	}
	items := []PoolReauthItem{}
	if s.Store != nil && s.Vault != nil {
		creds, err := s.Store.Credentials("")
		if err != nil {
			httpError(w, 500, "无法读取订阅")
			return
		}
		for _, c := range creds {
			if c.Provider == credvault.GitHub || !c.ReauthRequired {
				continue
			}
			items = append(items, PoolReauthItem{CredentialID: s.Vault.CredentialID(c), Owner: c.PrincipalID, Provider: c.Provider,
				Account: c.Account, Since: c.ReauthRequiredAt, Reason: poolReauthReason(c.RefreshError, false), ReasonEN: poolReauthReason(c.RefreshError, true)})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Account < items[j].Account })
	writeJSON(w, 200, map[string]any{"pending": len(items), "items": items})
}
