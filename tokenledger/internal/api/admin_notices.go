package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 管理侧「发通知」(claude-fleet#4063, EPIC #4048 R1): an admin tells every
// member, or a few of them, one plain sentence — 「周六 2 点维护 30 分钟」 — and
// the notice desk (notify.go) carries each copy down the same roads as a
// request's result: a template to one who follows the service account, a
// customer-service message, else a mail, else only the record. The console's
// /admin/notices page (extras/web-console) is the only reader; a member is
// answered the 404 an unknown address gets, as for the requests.
//
//	GET  /v1/admin/notices   the notices sent, newest first, each with how its
//	                         copies went; today's count and the limit; the
//	                         members a notice can go to and how each is reached
//	POST /v1/admin/notices   {body, link?, to: "all" | [principal, …]}
//
// A service notice only (共同约定「不发营销」): plain text, at most one link, at
// most noticeDayMax in any 24 hours (429 past it), every one audited
// (notice.send).

const (
	AdminNoticesPath = "/v1/admin/notices"

	// noticeDayMax is how many notices any 24 hours may carry.
	noticeDayMax = 3
	// noticeBodyMax bounds a notice's words (runes).
	noticeBodyMax = 300
	// noticeLinkMax bounds its link (bytes).
	noticeLinkMax = 500
	// noticeListMax is how many past notices the page shows.
	noticeListMax = 100
)

// noticeURLRe finds a link written into the words: the link has its own field.
var noticeURLRe = regexp.MustCompile(`(?i)(https?://|www\.)`)

// noticeMember is one member a notice can go to.
type noticeMember struct {
	PrincipalID string `json:"principal_id"`
	Login       string `json:"login"`
	Role        string `json:"role"`
	// Reach is the road their copy would take now: wechat (they follow the
	// service account) · email · none (only the record).
	Reach string `json:"reach"`
}

// noticeRow is one notice as the list shows it.
type noticeRow struct {
	store.ServiceNotice
	Delivery store.NoticeDelivery `json:"delivery"`
}

type adminNoticesView struct {
	Notices []noticeRow    `json:"notices"`
	Today   int            `json:"today"`
	Limit   int            `json:"limit"`
	Members []noticeMember `json:"members"`
}

func (s *Server) handleAdminNotices(w http.ResponseWriter, r *http.Request) {
	// adminOnly's gate, answered as a missing page instead of 403 (#3925)
	if memberRole(roleOf(r.Context())) {
		s.auditRoleDenied(r)
		http.NotFound(w, r)
		return
	}
	if s.Store == nil || r.URL.Path != AdminNoticesPath {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		s.adminNoticesList(w)
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		s.adminNoticeSend(w, r)
	default:
		w.Header().Set("Allow", "GET, HEAD, POST")
		httpError(w, http.StatusMethodNotAllowed, "not with "+r.Method)
	}
}

// noticeMembers is everyone on the list (a trial person is not a member yet),
// with the road a copy would take.
func (s *Server) noticeMembers() ([]noticeMember, error) {
	users, err := s.Store.HubUsers()
	if err != nil {
		return nil, err
	}
	out := []noticeMember{}
	for _, u := range users {
		if u.Role != roleUser && u.Role != roleAdmin {
			continue
		}
		reach, err := s.noticeReach(store.Notice{Owner: u.PrincipalID})
		if err != nil {
			return nil, err
		}
		m := noticeMember{PrincipalID: u.PrincipalID, Login: u.Login, Role: u.Role, Reach: "none"}
		switch {
		case reach.OpenID != "" && reach.Followed:
			m.Reach = "wechat"
		case reach.Email != "":
			m.Reach = "email"
		}
		out = append(out, m)
	}
	return out, nil
}

func (s *Server) adminNoticesList(w http.ResponseWriter) {
	now := time.Now()
	ns, err := s.Store.ServiceNotices(noticeListMax)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the notices")
		return
	}
	v := adminNoticesView{Notices: []noticeRow{}, Limit: noticeDayMax}
	for _, n := range ns {
		d, err := s.Store.ServiceNoticeDelivery(n.ID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not read how the notices went")
			return
		}
		v.Notices = append(v.Notices, noticeRow{ServiceNotice: n, Delivery: d})
	}
	if v.Today, err = s.Store.ServiceNoticesSince(now.Add(-24 * time.Hour)); err != nil {
		httpError(w, http.StatusInternalServerError, "could not count the notices")
		return
	}
	if v.Members, err = s.noticeMembers(); err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the members")
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// checkNoticeBody: plain words, one paragraph or a few lines, no link inside.
func checkNoticeBody(body string) (string, error) {
	body = strings.TrimSpace(strings.ReplaceAll(body, "\r\n", "\n"))
	switch {
	case body == "":
		return "", errors.New("a notice says something")
	case utf8.RuneCountInString(body) > noticeBodyMax:
		return "", fmt.Errorf("a notice is at most %d characters", noticeBodyMax)
	case noticeURLRe.MatchString(body):
		return "", errors.New("put the link in its own field, not in the words")
	}
	for _, c := range body {
		if c != '\n' && unicode.IsControl(c) {
			return "", errors.New("a notice is plain text")
		}
	}
	return body, nil
}

// checkNoticeLink: one https address, or none.
func checkNoticeLink(link string) (string, error) {
	link = strings.TrimSpace(link)
	if link == "" {
		return "", nil
	}
	u, err := url.Parse(link)
	if err != nil || u.Scheme != "https" || u.Host == "" || len(link) > noticeLinkMax || strings.ContainsAny(link, " \n\t") {
		return "", fmt.Errorf("the link is one https:// address, at most %d characters", noticeLinkMax)
	}
	return link, nil
}

func (s *Server) adminNoticeSend(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Body string          `json:"body"`
		Link string          `json:"link"`
		To   json.RawMessage `json:"to"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, `the body must be {"body": "...", "link": "https://...", "to": "all" | ["principal", ...]}`)
		return
	}
	words, err := checkNoticeBody(body.Body)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	link, err := checkNoticeLink(body.Link)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	members, err := s.noticeMembers()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the members")
		return
	}
	var all string
	var some []string
	switch {
	case json.Unmarshal(body.To, &all) == nil && all == store.NoticeAll:
	case json.Unmarshal(body.To, &some) == nil && len(some) > 0:
		all = ""
	default:
		httpError(w, http.StatusBadRequest, `to is "all" or a list of members`)
		return
	}
	on := map[string]bool{}
	for _, m := range members {
		on[m.PrincipalID] = true
	}
	var to []string
	if all == store.NoticeAll {
		for _, m := range members {
			to = append(to, m.PrincipalID)
		}
		if len(to) == 0 {
			httpError(w, http.StatusConflict, "there is no member to tell")
			return
		}
	} else {
		seen := map[string]bool{}
		for _, p := range some {
			p = strings.TrimSpace(p)
			if !on[p] {
				httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not a member", p))
				return
			}
			if !seen[p] {
				seen[p] = true
				to = append(to, p)
			}
		}
	}
	tok, err := randomToken(9)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not name the notice")
		return
	}
	now := time.Now()
	by := principalOf(r.Context())
	n := store.ServiceNotice{ID: "nc-" + tok, Body: words, Link: link, Audience: store.NoticeAll,
		Recipients: to, CreatedBy: by, CreatedAt: now}
	target := fmt.Sprintf("all (%d)", len(to))
	if all == "" {
		n.Audience = "some"
		target = fmt.Sprintf("%d member(s)", len(to))
	}
	set, _ := s.Store.FleetSettings()
	langOf := func(p string) string { return parseLang(set[langSettingKey(p)]) }
	err = s.Store.CreateServiceNotice(n, langOf, noticeDayMax, now.Add(-24*time.Hour), now)
	if errors.Is(err, store.ErrNoticeLimit) {
		_ = s.Store.HubAudit(by, "notice.send", target, "denied", fmt.Sprintf("over %d in 24 hours", noticeDayMax), now)
		httpError(w, http.StatusTooManyRequests, fmt.Sprintf("at most %d notices in 24 hours — the next one can go when the oldest of them is a day old", noticeDayMax))
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not record the notice")
		return
	}
	_ = s.Store.HubAudit(by, "notice.send", target, "ok", n.ID+" · "+clipRunes(oneLine(words), 80), now)
	s.notifyKick()
	writeJSON(w, http.StatusCreated, noticeRow{ServiceNotice: n, Delivery: store.NoticeDelivery{Pending: len(to), Via: map[string]int{}}})
}
