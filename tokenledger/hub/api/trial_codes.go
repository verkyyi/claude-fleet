package api

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"rsc.io/qr"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 管理侧「试用二维码」(claude-fleet MRGB): an admin draws a code on the service
// account that starts a trial for whoever scans it (wx_trial_scan.go), reads
// what each code did, and stops it. The console's /admin/trial-codes page
// (extras/web-console) is the only reader; a member is answered the 404 an
// unknown address gets, as for the requests.
//
//	GET  /v1/admin/trial-codes            every code with its funnel; the
//	                                      last 7 days' totals and the defaults
//	POST /v1/admin/trial-codes            {channel, terms?, cap?, until?,
//	                                      approval?, kind?: limit|temp, days?}
//	GET  /v1/admin/trial-codes/<id>       one code and the people it reached
//	GET  /v1/admin/trial-codes/<id>/qr.png  the code to print
//	POST /v1/admin/trial-codes/<id>/stop | /resume
//
// Every create, stop and resume is audited (trialcode.*).

const (
	AdminTrialCodesPath   = "/v1/admin/trial-codes"
	adminTrialCodesPrefix = AdminTrialCodesPath + "/"

	// trialCodeCapDefault is how many trials a new code gives unless the
	// admin says otherwise.
	trialCodeCapDefault = 200
	trialCodeCapMax     = 100000
	trialChannelMax     = 40 // runes
	// trialCodeTotalsDays is the KPI cards' window.
	trialCodeTotalsDays = 7
	// trialQRScale is the printed code's pixels per module.
	trialQRScale = 12
)

// trialFunnel is a code's (or every code's) way from scan to member.
type trialFunnel struct {
	Scans     int `json:"scans"`
	Follows   int `json:"follows"`
	Granted   int `json:"granted"`
	Queued    int `json:"queued"`
	Pending   int `json:"pending"`
	First     int `json:"first"`
	NextDay   int `json:"next_day"`
	Converted int `json:"converted"`
	// P50Secs is the median time from the scan to the first line in the
	// chat, over those who sent one (0 = none yet).
	P50Secs int `json:"p50_secs"`
}

type trialCodeRow struct {
	store.TrialCode
	TermsWords   string      `json:"terms_words"`
	TermsWordsEN string      `json:"terms_words_en"`
	Image        string      `json:"image"`
	Funnel       trialFunnel `json:"funnel"`
}

type trialCodePerson struct {
	Principal string    `json:"principal"`
	Login     string    `json:"login"`
	State     string    `json:"state"`
	Member    bool      `json:"member"`
	ScannedAt time.Time `json:"scanned_at"`
	GrantedAt time.Time `json:"granted_at"`
	FirstAt   time.Time `json:"first_at"`
}

type adminTrialCodesView struct {
	Codes  []trialCodeRow `json:"codes"`
	Totals trialFunnel    `json:"totals"`
	Days   int            `json:"days"`
	// Ready: the service account's road is set up — a code can be drawn.
	Ready    bool   `json:"ready"`
	Terms    string `json:"terms"` // fleet.apply.trial, a new code's default
	TermsEN  string `json:"terms_words_en"`
	TermsZH  string `json:"terms_words"`
	Cap      int    `json:"cap"`
	Daily    int    `json:"daily"`
	Today    int    `json:"today"`
	Burst    int    `json:"burst"`
	TempDays int    `json:"temp_days_max"`
}

type adminTrialCodeDetail struct {
	trialCodeRow
	People []trialCodePerson `json:"people"`
}

func (s *Server) handleAdminTrialCodes(w http.ResponseWriter, r *http.Request) {
	if memberRole(roleOf(r.Context())) {
		s.auditRoleDenied(r)
		http.NotFound(w, r)
		return
	}
	if s.Store == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, AdminTrialCodesPath), "/")
	if r.Method == http.MethodPost && !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	parts := strings.Split(rest, "/")
	switch {
	case rest == "" && (r.Method == http.MethodGet || r.Method == http.MethodHead):
		s.adminTrialCodesList(w)
	case rest == "" && r.Method == http.MethodPost:
		s.adminTrialCodeCreate(w, r)
	case len(parts) == 1 && r.Method == http.MethodGet:
		s.adminTrialCodeDetail(w, parts[0])
	case len(parts) == 2 && parts[1] == "qr.png" && r.Method == http.MethodGet:
		s.adminTrialCodePNG(w, parts[0])
	case len(parts) == 2 && (parts[1] == "stop" || parts[1] == "resume") && r.Method == http.MethodPost:
		s.adminTrialCodeState(w, r, parts[0], parts[1])
	default:
		httpError(w, http.StatusNotFound, "no such trial-code route")
	}
}

func (s *Server) adminTrialCodesList(w http.ResponseWriter) {
	now := time.Now()
	codes, err := s.Store.TrialCodes()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the trial codes")
		return
	}
	set, _ := s.Store.FleetSettings()
	users := s.userRoles()
	v := adminTrialCodesView{Codes: []trialCodeRow{}, Days: trialCodeTotalsDays, Ready: s.WxGW.ready(),
		Cap: trialCodeCapDefault, Daily: s.qrDaily(), Burst: s.qrBurst(), TempDays: int(wxTempMax / (24 * time.Hour))}
	v.Terms = s.setting(ApplyTrialKey)
	if t, err := parseTrialTerms(v.Terms); err == nil {
		v.TermsZH, v.TermsEN = termsWords(t, false), termsWords(t, true)
	}
	v.Today, _ = s.Store.TrialGrantedSince("", trialDayStart(now))
	since := now.Add(-trialCodeTotalsDays * 24 * time.Hour)
	var firsts []int
	for i := range codes {
		row, err := s.trialCodeRow(&codes[i], set, users, time.Time{}, nil)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not read a trial code's funnel")
			return
		}
		v.Codes = append(v.Codes, row)
		recent, err := s.trialCodeRow(&codes[i], set, users, since, &firsts)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not read a trial code's funnel")
			return
		}
		f := recent.Funnel
		v.Totals.Scans += f.Scans
		v.Totals.Follows += f.Follows
		v.Totals.Granted += f.Granted
		v.Totals.Queued += f.Queued
		v.Totals.Pending += f.Pending
		v.Totals.First += f.First
		v.Totals.NextDay += f.NextDay
		v.Totals.Converted += f.Converted
	}
	v.Totals.P50Secs = median(firsts)
	writeJSON(w, http.StatusOK, v)
}

// userRoles is every person on the list and their role.
func (s *Server) userRoles() map[string]store.HubUser {
	out := map[string]store.HubUser{}
	if us, err := s.Store.HubUsers(); err == nil {
		for _, u := range us {
			out[u.PrincipalID] = u
		}
	}
	return out
}

// trialCodeRow is code with its funnel since since (zero = ever); the scan →
// first-line seconds are appended to firsts when it is not nil.
func (s *Server) trialCodeRow(code *store.TrialCode, set map[string]string, users map[string]store.HubUser,
	since time.Time, firsts *[]int) (trialCodeRow, error) {
	row := trialCodeRow{TrialCode: *code, Image: AdminTrialCodesPath + "/" + code.ID + "/qr.png"}
	t := s.codeTerms(code)
	row.TermsWords, row.TermsWordsEN = termsWords(t, false), termsWords(t, true)
	var err error
	if row.Funnel.Scans, row.Funnel.Follows, err = s.Store.TrialScanCounts(code.ID, since); err != nil {
		return row, err
	}
	gs, err := s.Store.TrialGrantsOfCode(code.ID)
	if err != nil {
		return row, err
	}
	var mine []int
	for _, g := range gs {
		if g.ScannedAt.Before(since) {
			continue
		}
		switch g.State {
		case store.GrantQueued:
			row.Funnel.Queued++
			continue
		case store.GrantPending:
			row.Funnel.Pending++
			continue
		}
		row.Funnel.Granted++
		if !g.FirstAt.IsZero() {
			row.Funnel.First++
			mine = append(mine, int(g.FirstAt.Sub(g.ScannedAt).Seconds()))
		}
		if !g.NextDayAt.IsZero() {
			row.Funnel.NextDay++
		}
		if trialConverted(g.Principal, set, users) {
			row.Funnel.Converted++
		}
	}
	row.Funnel.P50Secs = median(mine)
	if firsts != nil {
		*firsts = append(*firsts, mine...)
	}
	return row, nil
}

// trialConverted: the person a code let in is a member now — on the list
// with no trial limits left.
func trialConverted(pid string, set map[string]string, users map[string]store.HubUser) bool {
	u, ok := users[pid]
	if !ok || (u.Role != roleUser && u.Role != roleAdmin) {
		return false
	}
	_, limited := memberLimitsOf(set, pid)
	return !limited
}

func median(v []int) int {
	if len(v) == 0 {
		return 0
	}
	c := append([]int(nil), v...)
	sort.Ints(c)
	if len(c)%2 == 1 {
		return c[len(c)/2]
	}
	return (c[len(c)/2-1] + c[len(c)/2]) / 2
}

func (s *Server) adminTrialCodeDetail(w http.ResponseWriter, id string) {
	code, err := s.Store.TrialCode(id)
	switch {
	case err != nil:
		httpError(w, http.StatusInternalServerError, "could not read the trial code")
		return
	case code == nil:
		httpError(w, http.StatusNotFound, "no such trial code")
		return
	}
	set, _ := s.Store.FleetSettings()
	users := s.userRoles()
	row, err := s.trialCodeRow(code, set, users, time.Time{}, nil)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the trial code's funnel")
		return
	}
	d := adminTrialCodeDetail{trialCodeRow: row, People: []trialCodePerson{}}
	gs, err := s.Store.TrialGrantsOfCode(code.ID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read who the code reached")
		return
	}
	for _, g := range gs {
		p := trialCodePerson{Principal: g.Principal, State: g.State, ScannedAt: g.ScannedAt,
			GrantedAt: g.GrantedAt, FirstAt: g.FirstAt, Member: trialConverted(g.Principal, set, users)}
		if u, ok := users[g.Principal]; ok {
			p.Login = u.Login
		}
		d.People = append(d.People, p)
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) adminTrialCodePNG(w http.ResponseWriter, id string) {
	code, err := s.Store.TrialCode(id)
	if err != nil || code == nil || code.URL == "" {
		httpError(w, http.StatusNotFound, "no such trial code")
		return
	}
	c, err := qr.Encode(code.URL, qr.M)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not draw the code")
		return
	}
	c.Scale = trialQRScale
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Content-Disposition", `inline; filename="trial-`+code.ID+`.png"`)
	_, _ = w.Write(c.PNG())
}

type trialCodeIn struct {
	Channel  string `json:"channel"`
	Terms    string `json:"terms"`
	Cap      *int   `json:"cap"`
	Until    string `json:"until"` // YYYY-MM-DD, the last day it gives (Beijing)
	Approval bool   `json:"approval"`
	Kind     string `json:"kind"` // limit | temp
	Days     int    `json:"days"` // temp: how long the code lives (1..30)
}

func (s *Server) adminTrialCodeCreate(w http.ResponseWriter, r *http.Request) {
	if !s.WxGW.ready() {
		httpError(w, http.StatusServiceUnavailable, "the service account's road is not set up (CCQUOTA_WX_INTERNAL_URL / _TOKEN)")
		return
	}
	var in trialCodeIn
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&in); err != nil && !errors.Is(err, io.EOF) {
		httpError(w, http.StatusBadRequest, `want {"channel", "terms"?, "cap"?, "until"?, "approval"?, "kind"?, "days"?}`)
		return
	}
	now := time.Now()
	c := store.TrialCode{Channel: strings.Join(strings.Fields(in.Channel), " "), Approval: in.Approval,
		Kind: store.TrialCodeLimit, Cap: trialCodeCapDefault, CreatedBy: principalOf(r.Context()), CreatedAt: now}
	if c.Channel == "" || utf8.RuneCountInString(c.Channel) > trialChannelMax {
		httpError(w, http.StatusBadRequest, "channel: 1–"+strconv.Itoa(trialChannelMax)+" characters")
		return
	}
	if t := strings.TrimSpace(in.Terms); t != "" {
		if _, err := parseTrialTerms(t); err != nil {
			httpError(w, http.StatusBadRequest, "terms: "+err.Error())
			return
		}
		c.Terms = t
	}
	if in.Cap != nil {
		if *in.Cap < 0 || *in.Cap > trialCodeCapMax {
			httpError(w, http.StatusBadRequest, "cap: 0 (no cap) … "+strconv.Itoa(trialCodeCapMax))
			return
		}
		c.Cap = *in.Cap
	}
	if u := strings.TrimSpace(in.Until); u != "" {
		d, err := time.ParseInLocation("2006-01-02", u, trialDay)
		if err != nil || !d.After(now.Add(-24*time.Hour)) {
			httpError(w, http.StatusBadRequest, "until: a date from today on, YYYY-MM-DD")
			return
		}
		c.Until = d.Add(24*time.Hour - time.Second) // the end of that day
	}
	var ttl time.Duration
	switch in.Kind {
	case "", store.TrialCodeLimit:
	case store.TrialCodeTemp:
		max := int(wxTempMax / (24 * time.Hour))
		if in.Days < 1 || in.Days > max {
			httpError(w, http.StatusBadRequest, "days: a temporary code lives 1–"+strconv.Itoa(max)+" days")
			return
		}
		c.Kind, ttl = store.TrialCodeTemp, time.Duration(in.Days)*24*time.Hour
		if end := now.Add(ttl); c.Until.IsZero() || c.Until.After(end) {
			c.Until = end
		}
	default:
		httpError(w, http.StatusBadRequest, "kind: limit or temp")
		return
	}
	rid, err := randomToken(9)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	c.ID = "tc-" + rid
	for try := 0; ; try++ {
		top, err := s.Store.MaxTrialScene()
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not read the codes")
			return
		}
		c.Scene = max(top, wxTrialSceneMin) + 1
		if !wxTrialSceneInRange(c.Scene) {
			httpError(w, http.StatusConflict, "every trial scene is taken")
			return
		}
		c.URL, c.Ticket, err = s.WxGW.qrCreateTrial(r.Context(), c.Scene, ttl)
		if err != nil {
			log.Printf("trial code: draw scene %d: %s", c.Scene, wxWhy(wxCode(err)))
			httpError(w, http.StatusBadGateway, "微信暂时不可用 · WeChat cannot be reached right now")
			return
		}
		err = s.Store.CreateTrialCode(c)
		if errors.Is(err, store.ErrTrialSceneTaken) && try < 3 {
			continue // another admin drew the same number a moment ago
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not record the code")
			return
		}
		break
	}
	_ = s.Store.HubAudit(c.CreatedBy, "trialcode.create", c.Channel+" ("+c.ID+")", "ok",
		"scene "+strconv.FormatInt(c.Scene, 10)+" · "+c.Kind+" · cap "+strconv.Itoa(c.Cap)+" · terms "+orDefault(c.Terms, "fleet.apply.trial"), now)
	s.adminTrialCodeDetail(w, c.ID)
}

func (s *Server) adminTrialCodeState(w http.ResponseWriter, r *http.Request, id, verb string) {
	code, err := s.Store.TrialCode(id)
	switch {
	case err != nil:
		httpError(w, http.StatusInternalServerError, "could not read the trial code")
		return
	case code == nil:
		httpError(w, http.StatusNotFound, "no such trial code")
		return
	}
	now := time.Now()
	state := store.TrialCodeStopped
	if verb == "resume" {
		state = store.TrialCodeLive
	}
	changed, err := s.Store.SetTrialCodeState(id, state, "", now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not change the code")
		return
	}
	if changed {
		_ = s.Store.HubAudit(principalOf(r.Context()), "trialcode."+verb, code.Channel+" ("+code.ID+")", "ok", code.State+" → "+state, now)
	}
	if state == store.TrialCodeLive {
		_, _ = s.Store.ClearFleetAlert(store.AlertTrialCodeBurst, id, now)
	}
	s.adminTrialCodeDetail(w, id)
}
