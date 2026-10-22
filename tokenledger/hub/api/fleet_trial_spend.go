package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// 试用花费日报与超线提醒 (claude-fleet WACK C6). Two things reach the admins
// through the hub's notifier (FLEET_NOTIFY_CMD — on the hub, `ccquota
// notify` down FLEET_NOTIFY_KF_*):
//
//   - every day at 09:00 Beijing, 「试用日报」: the day before — how many trial
//     identities (trialIdentity, WACK 共同约定 2) started, how many are in
//     their trial, their tokens split by where they were spent (C1's classes:
//     the pool's subscriptions and API keys, or their own), each machine's load
//     now and how many went over the line. A day nobody tried says so in one
//     line, so a silent morning means broken, never quiet.
//   - at once, 「试用用量超线」: a trial identity's pool tokens today (Beijing)
//     past person_day, or every trial identity's together past all_day — once
//     per person per day and once for everyone per day (a fleet_alerts row
//     trial_spend, subject "<pid>@<day>" / "all@<day>", cleared the next day);
//     a raise within trialSpendQuiet of the last push waits and goes out with
//     the next one (共同约定 4).
//
// The numbers are /v1/admin/usage's: each person's scan rows
// (personEventUsage) counted by store.PoolUsage.Tokens — input + cache write +
// output, a cache read not counted, as fleet.member_limits counts them
// (fleet_member_limits.go). The split by source is the share of the person's
// pool_usage rows (the proxies' reports, which name the subscription) in each
// class; a row naming no known subscription counts as the pool's. The
// real-time check reads pool_usage itself — the row just written — since the
// scan lags by up to an hour.
//
// fleet.trial.alert = "person_day=1000000,all_day=30000000" (发起人 10-21);
// either line 0 = not watched; "daily=off" keeps the morning report in;
// "off" = neither. GET TrialSpendPath is the console's 试用 view of 用量.

const (
	TrialAlertKey     = "fleet.trial.alert"
	trialAlertDefault = "person_day=1000000,all_day=30000000"
	// TrialSpendPath is one day's trial spend, the console's 试用 tab.
	TrialSpendPath = "/v1/admin/usage/trial"
	// trialDailyHour is when the morning report goes out, Beijing time.
	trialDailyHour = 9
	// trialSpendAllSubject names the everyone line's alert ("all@<day>").
	trialSpendAllSubject = "all"
	// trialDailyAction is the audit a sent report leaves (+ ".<day>"): the
	// once-a-day mark, read by HubAuditHas.
	trialDailyAction = "trial.daily"
)

var (
	// trialSpendQuiet: two trial_spend pushes are at least this far apart.
	trialSpendQuiet = 30 * time.Minute
	// trialSpendCheckEvery: one person's write checks the lines at most this
	// often (the proxies report per request).
	trialSpendCheckEvery = 20 * time.Second
	// trialSpendAsync: a write's check runs off the request; tests run it inline.
	trialSpendAsync = true
)

// trialAlertLine is fleet.trial.alert read.
type trialAlertLine struct {
	PersonDay int64 `json:"person_day"`
	AllDay    int64 `json:"all_day"`
	Daily     bool  `json:"daily"`
}

func parseTrialAlert(v string) (trialAlertLine, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		v = trialAlertDefault
	}
	if strings.EqualFold(v, "off") {
		return trialAlertLine{}, nil
	}
	l := trialAlertLine{Daily: true}
	def, _ := limitFields(trialAlertDefault)
	for _, f := range def {
		n, _ := parseTokens(f[1])
		if f[0] == "person_day" {
			l.PersonDay = n
		} else {
			l.AllDay = n
		}
	}
	fs, err := limitFields(v)
	if err != nil {
		return trialAlertLine{}, err
	}
	for _, f := range fs {
		switch f[0] {
		case "person_day", "all_day":
			n, err := parseTokens(f[1])
			if err != nil || n < 0 {
				return trialAlertLine{}, fmt.Errorf("%s is a token count (e.g. 1000000, 1M; 0 = not watched)", f[0])
			}
			if f[0] == "person_day" {
				l.PersonDay = n
			} else {
				l.AllDay = n
			}
		case "daily":
			switch strings.ToLower(f[1]) {
			case "on":
				l.Daily = true
			case "off":
				l.Daily = false
			default:
				return trialAlertLine{}, fmt.Errorf("daily is on | off")
			}
		default:
			return trialAlertLine{}, fmt.Errorf("%q: want person_day, all_day or daily", f[0])
		}
	}
	return l, nil
}

func checkTrialAlert(_ *Server, v string) (string, string) {
	v = strings.TrimSpace(v)
	if v == "" || strings.EqualFold(v, "off") {
		return strings.ToLower(v), ""
	}
	if _, err := parseTrialAlert(v); err != nil {
		return "", TrialAlertKey + ": " + err.Error() + ` — e.g. "person_day=1000000,all_day=30000000", "off"`
	}
	return v, ""
}

// trialAlert is the setting, the default when unreadable.
func (s *Server) trialAlert() trialAlertLine {
	l, err := parseTrialAlert(s.setting(TrialAlertKey))
	if err != nil {
		l, _ = parseTrialAlert("")
	}
	return l
}

// ── one day's spend ─────────────────────────────────────────────────────

// TrialSpendPerson is one trial identity's day.
type TrialSpendPerson struct {
	Principal string `json:"principal"`
	Name      string `json:"name"`
	// Kind is how they signed in (wechat · email · github), "" unknown.
	Kind string `json:"kind,omitempty"`
	// TrialDay is the day of their trial at the window's end (1 = its first).
	TrialDay int   `json:"trial_day"`
	Tokens   int64 `json:"tokens"`
	Pool     int64 `json:"pool"`
	BYO      int64 `json:"byo"`
	New      bool  `json:"new"`
	Active   bool  `json:"active"`
	Over     bool  `json:"over"`
}

// TrialSpendMachine is one machine's load as its last beat said it.
type TrialSpendMachine struct {
	Node    string `json:"node"`
	LoadPct int    `json:"load_pct"`
}

// TrialSpend is TrialSpendPath's answer: one Beijing day.
type TrialSpend struct {
	Day    string    `json:"day"`
	From   time.Time `json:"from"`
	To     time.Time `json:"to"`
	New    int       `json:"new"`
	Active int       `json:"active"`
	Tokens int64     `json:"tokens"`
	Pool   int64     `json:"pool"`
	BYO    int64     `json:"byo"`
	// BySource is Tokens by C1's class: subscription · api · byo.
	BySource map[string]int64    `json:"by_source"`
	Over     int                 `json:"over"`
	AllOver  bool                `json:"all_over"`
	Line     trialAlertLine      `json:"line"`
	Machines []TrialSpendMachine `json:"machines"`
	People   []TrialSpendPerson  `json:"people"`
}

// empty: nobody used anything and nobody started.
func (t TrialSpend) empty() bool { return t.Tokens == 0 && t.New == 0 }

// trialSpendDay is the Beijing day [from, from+24h) holding at.
func trialSpendDay(at time.Time) (from, to time.Time) {
	from = trialDayStart(at)
	return from, from.Add(24 * time.Hour)
}

// trialStartOf is when pid's trial began: the trial road's row, else the
// limits' since, else when they joined.
func trialStartOf(t *store.Trial, l MemberLimits, created time.Time) time.Time {
	switch {
	case t != nil && !t.StartedAt.IsZero():
		return t.StartedAt
	case !l.Since.IsZero():
		return l.Since
	}
	return created
}

// trialSourceOf is the class of the subscription a pool_usage row of pid's
// names: the row's "owner/account" or pid's own, else the pool's; a row
// naming none known is the pool's subscription.
func trialSourceOf(creds map[string]store.Credential, pid string, u store.PoolUsage) string {
	key := func(owner, acct string) string { return owner + "\x00" + u.Provider + "\x00" + acct }
	if owner, acct, ok := strings.Cut(u.Account, "/"); ok {
		if c, ok := creds[key(owner, acct)]; ok {
			return c.Source()
		}
	}
	for _, owner := range []string{pid, store.PoolPrincipal} {
		if c, ok := creds[key(owner, u.Account)]; ok {
			return c.Source()
		}
	}
	return store.SourceSubscription
}

// splitBySource shares total out by the classes' weights; what no weight
// names is the pool's subscription.
func splitBySource(total int64, w map[string]int64) map[string]int64 {
	out := map[string]int64{store.SourceSubscription: 0, store.SourceAPI: 0, store.SourceBYO: 0}
	var sum int64
	for _, n := range w {
		sum += n
	}
	if sum <= 0 {
		out[store.SourceSubscription] = total
		return out
	}
	left := total
	for _, k := range []string{store.SourceBYO, store.SourceAPI} {
		out[k] = int64(float64(total) * float64(w[k]) / float64(sum))
		left -= out[k]
	}
	out[store.SourceSubscription] = left
	return out
}

// trialSpend counts every trial identity's [from, to). now is when it is
// read: who is a trial identity, and the machines' load.
func (s *Server) trialSpend(from, to, now time.Time) (TrialSpend, error) {
	out := TrialSpend{Day: from.In(trialDay).Format("2006-01-02"), From: from, To: to, Line: s.trialAlert(),
		BySource: map[string]int64{store.SourceSubscription: 0, store.SourceAPI: 0, store.SourceBYO: 0},
		Machines: []TrialSpendMachine{}, People: []TrialSpendPerson{}}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return out, err
	}
	ps, err := s.Store.Principals()
	if err != nil {
		return out, err
	}
	credRows, err := s.Store.Credentials("")
	if err != nil {
		return out, err
	}
	creds := map[string]store.Credential{}
	for _, c := range credRows {
		creds[c.PrincipalID+"\x00"+c.Provider+"\x00"+c.Account] = c
	}
	alerted := map[string]bool{}
	if subs, err := s.Store.OpenFleetAlertSubjects(store.AlertTrialSpend, ""); err == nil {
		for _, sub := range subs {
			if pid, day, ok := strings.Cut(sub, "@"); ok && day == out.Day {
				alerted[pid] = true
			}
		}
	}
	for _, p := range ps {
		if !s.trialIdentity(settings, p.ID) {
			continue
		}
		t, err := s.Store.Trial(p.ID)
		if err != nil {
			return out, err
		}
		l, _ := memberLimitsOf(settings, p.ID)
		rows, err := s.personEventUsage(p.ID, from)
		if err != nil {
			return out, err
		}
		var tokens int64
		for _, u := range rows {
			if u.At.Before(to) {
				tokens += u.Tokens()
			}
		}
		pool, err := s.Store.PoolUsageFor(p.ID, from, to)
		if err != nil {
			return out, err
		}
		w := map[string]int64{}
		for _, u := range pool {
			w[trialSourceOf(creds, p.ID, u)] += u.Tokens()
		}
		split := splitBySource(tokens, w)
		start := trialStartOf(t, l, p.CreatedAt)
		end := to
		if now.Before(end) {
			end = now
		}
		r := TrialSpendPerson{Principal: p.ID, Name: p.DisplayName, Tokens: tokens,
			BYO: split[store.SourceBYO], Pool: split[store.SourceSubscription] + split[store.SourceAPI],
			New:    !start.IsZero() && !start.Before(from) && start.Before(to),
			Active: (t != nil && (t.State == store.TrialWaiting || t.State == store.TrialPlaced)) || l.Until.After(end),
		}
		if r.Name == "" {
			r.Name = p.Login
		}
		if t != nil {
			r.Kind = t.Kind
		}
		if !start.IsZero() && !end.Before(start) {
			r.TrialDay = int(end.Sub(start)/(24*time.Hour)) + 1
		}
		r.Over = alerted[p.ID] || (out.Line.PersonDay > 0 && tokens > out.Line.PersonDay)
		for k, n := range split {
			out.BySource[k] += n
		}
		out.Tokens += tokens
		out.Pool += r.Pool
		out.BYO += r.BYO
		if r.New {
			out.New++
		}
		if r.Active {
			out.Active++
		}
		if r.Over {
			out.Over++
		}
		if r.Tokens > 0 || r.New || r.Active {
			out.People = append(out.People, r)
		}
	}
	out.AllOver = alerted[trialSpendAllSubject] || (out.Line.AllDay > 0 && out.Tokens > out.Line.AllDay)
	sort.SliceStable(out.People, func(i, j int) bool {
		if out.People[i].Tokens != out.People[j].Tokens {
			return out.People[i].Tokens > out.People[j].Tokens
		}
		return out.People[i].Name < out.People[j].Name
	})
	out.Machines = s.trialMachineLoads(now)
	return out, nil
}

// trialMachineLoads is each online machine's load now: its CPU busy, else
// load per core — the busiest login's beat when a machine has several.
func (s *Server) trialMachineLoads(now time.Time) []TrialSpendMachine {
	out := []TrialSpendMachine{}
	nodes, err := s.Store.Nodes()
	if err != nil {
		return out
	}
	by := map[string]int{}
	for _, n := range nodes {
		if n.Hostname == "" || NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now) != "online" {
			continue
		}
		var hb control.Heartbeat
		if json.Unmarshal([]byte(n.StatusJSON), &hb) != nil {
			continue
		}
		pct := -1
		switch {
		case hb.CPUBusy != nil:
			pct = int(*hb.CPUBusy*100 + 0.5)
		case hb.NCPU > 0:
			pct = int(hb.Load1/float64(hb.NCPU)*100 + 0.5)
		}
		if pct < 0 {
			continue
		}
		if old, ok := by[n.Hostname]; !ok || pct > old {
			by[n.Hostname] = pct
		}
	}
	for h, pct := range by {
		out = append(out, TrialSpendMachine{Node: h, LoadPct: pct})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Node < out[j].Node })
	return out
}

// handleTrialSpend serves GET TrialSpendPath[?day=YYYY-MM-DD|today]: one
// Beijing day, yesterday by default.
func (s *Server) handleTrialSpend(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if s.Store == nil {
		httpError(w, http.StatusNotFound, "no store")
		return
	}
	now := s.budgetClock()
	from, to := trialSpendDay(now.Add(-24 * time.Hour))
	switch d := r.URL.Query().Get("day"); d {
	case "", "yesterday":
	case "today":
		from, to = trialSpendDay(now)
	default:
		t, err := time.ParseInLocation("2006-01-02", d, trialDay)
		if err != nil {
			httpError(w, http.StatusBadRequest, "day is YYYY-MM-DD (Beijing), today or yesterday")
			return
		}
		from, to = t, t.Add(24*time.Hour)
	}
	out, err := s.trialSpend(from, to, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// ── words ───────────────────────────────────────────────────────────────

// thousands writes n with commas.
func thousands(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}

// spendTokens says a token count: 1,820 万 / 18.2M.
func spendTokens(n int64, en bool) string {
	if en {
		f := float64(n)
		switch {
		case n < 1000:
			return strconv.FormatInt(n, 10)
		case n < 1_000_000:
			return strings.TrimSuffix(strconv.FormatFloat(f/1e3, 'f', 1, 64), ".0") + "k"
		case n < 1_000_000_000:
			return strings.TrimSuffix(strconv.FormatFloat(f/1e6, 'f', 1, 64), ".0") + "M"
		}
		return strings.TrimSuffix(strconv.FormatFloat(f/1e9, 'f', 1, 64), ".0") + "B"
	}
	if n < 10000 {
		return thousands(n)
	}
	return thousands((n+5000)/10000) + " 万"
}

func spendDate(t time.Time, en bool) string {
	t = t.In(trialDay)
	if en {
		return t.Format("Jan 2")
	}
	return fmt.Sprintf("%d 月 %d 日", int(t.Month()), t.Day())
}

func spendPeople(n int, en bool) string {
	if !en {
		return strconv.Itoa(n) + " 人"
	}
	if n == 1 {
		return "1 person"
	}
	return strconv.Itoa(n) + " people"
}

// spendWho says who: 微信用户「小林」（试用第 2 天）.
func spendWho(p TrialSpendPerson, en bool) string {
	name := clipRunes(oneLine(p.Name), 20)
	if name == "" {
		name = p.Principal
	}
	var kind string
	switch p.Kind {
	case store.IdentityWeChat:
		kind = ternary(en, "WeChat user ", "微信用户")
	case "email":
		kind = ternary(en, "Email user ", "邮箱用户")
	case "github":
		kind = ternary(en, "GitHub user ", "GitHub 用户")
	}
	if en {
		w := kind + "“" + name + "”"
		if p.TrialDay > 0 {
			w += fmt.Sprintf(" (trial day %d)", p.TrialDay)
		}
		return w
	}
	w := kind + "「" + name + "」"
	if p.TrialDay > 0 {
		w += fmt.Sprintf("（试用第 %d 天）", p.TrialDay)
	}
	return w
}

// trialSpendLink is the console's 试用 view, open on pid when one is named.
func (s *Server) trialSpendLink(day, pid string) string {
	base := strings.TrimRight(s.FleetPublicURL, "/")
	if base == "" {
		return ""
	}
	q := url.Values{"tab": {"trial"}}
	if day != "" {
		q.Set("day", day)
	}
	if pid != "" {
		q.Set("open", pid)
	}
	return base + AdminPrefix + "/usage?" + q.Encode()
}

// trialDailyMsg is the morning report: title line, then one line each.
func trialDailyMsg(t TrialSpend, sent time.Time, en bool, link string) string {
	var b strings.Builder
	b.WriteString(ternary(en, "ClaudeFleet trial daily · ", "ClaudeFleet 试用日报 · ") + spendDate(sent, en) + "\n")
	if t.empty() {
		b.WriteString(ternary(en, "Nobody tried it yesterday, and nobody new started.", "昨天没有人试用，也没有新开通。") + "\n")
	} else {
		b.WriteString(ternary(en, "New ", "新开通 ") + spendPeople(t.New, en) + "\n")
		b.WriteString(ternary(en, "Active ", "在试用 ") + spendPeople(t.Active, en) + "\n")
		if en {
			fmt.Fprintf(&b, "Trial usage %s tokens (pool %s · own subscriptions %s)\n",
				spendTokens(t.Tokens, true), spendTokens(t.Pool, true), spendTokens(t.BYO, true))
		} else {
			fmt.Fprintf(&b, "试用用量 %s tokens（池子 %s · 自带订阅 %s）\n",
				spendTokens(t.Tokens, false), spendTokens(t.Pool, false), spendTokens(t.BYO, false))
		}
		if len(t.Machines) > 0 {
			var ms []string
			for _, m := range t.Machines {
				ms = append(ms, m.Node+ternary(en, " load ", " 负载 ")+strconv.Itoa(m.LoadPct)+"%")
			}
			b.WriteString(ternary(en, "Machines ", "机器 ") + strings.Join(ms, " · ") + "\n")
		}
		var watch []string
		if t.Over > 0 {
			if en {
				watch = append(watch, fmt.Sprintf("%s over %s tokens in a day", spendPeople(t.Over, true), spendTokens(t.Line.PersonDay, true)))
			} else {
				watch = append(watch, fmt.Sprintf("%d 人单日超 %s tokens", t.Over, spendTokens(t.Line.PersonDay, false)))
			}
		}
		if t.AllOver {
			if en {
				watch = append(watch, "everyone together over "+spendTokens(t.Line.AllDay, true))
			} else {
				watch = append(watch, "全体超 "+spendTokens(t.Line.AllDay, false))
			}
		}
		if len(watch) == 0 {
			watch = append(watch, ternary(en, "nobody over the line", "没有人超线"))
		}
		b.WriteString(ternary(en, "Watch ", "需要看 ") + strings.Join(watch, ternary(en, "; ", "；")) + "\n")
	}
	if link != "" {
		b.WriteString(ternary(en, "View details ", "查看详情 ") + link + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// trialSpendPersonMsg: one trial identity past person_day today.
func trialSpendPersonMsg(p TrialSpendPerson, tokens, line int64, en bool, link string) string {
	var b strings.Builder
	if en {
		b.WriteString("⚠️ Trial usage over the line\n")
		b.WriteString("Who " + spendWho(p, true) + "\n")
		fmt.Fprintf(&b, "Today %s tokens, over the %s per person per day\n", spendTokens(tokens, true), spendTokens(line, true))
		b.WriteString("Advice Look at what they are doing; if needed, stop them from Emergency switches\n")
		if link != "" {
			b.WriteString("Open their record " + link + "\n")
		}
	} else {
		b.WriteString("⚠️ 试用用量超线\n")
		b.WriteString("谁 " + spendWho(p, false) + "\n")
		fmt.Fprintf(&b, "今天 %s tokens，超过单人单日 %s\n", spendTokens(tokens, false), spendTokens(line, false))
		b.WriteString("建议 看一眼 TA 在做什么；必要时到「紧急开关」停用\n")
		if link != "" {
			b.WriteString("打开 TA 的记录 " + link + "\n")
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

// trialSpendAllMsg: every trial identity together past all_day today.
func trialSpendAllMsg(people int, tokens, line int64, en bool, link string) string {
	var b strings.Builder
	if en {
		b.WriteString("⚠️ Trial usage over the line\n")
		b.WriteString("Who every trial (" + spendPeople(people, true) + ")\n")
		fmt.Fprintf(&b, "Today %s tokens, over the %s for everyone per day\n", spendTokens(tokens, true), spendTokens(line, true))
		b.WriteString("Advice See who is using the most; if needed, stop new trials from Emergency switches\n")
		if link != "" {
			b.WriteString("View details " + link + "\n")
		}
	} else {
		b.WriteString("⚠️ 试用用量超线\n")
		b.WriteString("谁 全体试用（" + spendPeople(people, false) + "）\n")
		fmt.Fprintf(&b, "今天 %s tokens，超过全体单日 %s\n", spendTokens(tokens, false), spendTokens(line, false))
		b.WriteString("建议 看看是谁用得多；必要时到「紧急开关」停止所有新试用\n")
		if link != "" {
			b.WriteString("查看详情 " + link + "\n")
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

// adminsEnglish: every admin reads English (their page language) — the
// notifier has one road, so it speaks Chinese unless all of them read English.
func (s *Server) adminsEnglish() bool {
	users, err := s.Store.HubUsers()
	if err != nil {
		return false
	}
	set, _ := s.Store.FleetSettings()
	n := 0
	for _, u := range users {
		if u.Role != roleAdmin {
			continue
		}
		n++
		if l := parseLang(set[langSettingKey(u.PrincipalID)]); l == "" || i18n.Normalize(l) != i18n.EN {
			return false
		}
	}
	return n > 0
}

// ── pushing ─────────────────────────────────────────────────────────────

// trialSpendPush paces trial_spend's pushes (共同约定 4): last is when one
// went out, held what waits for the quiet window to end.
type trialSpendPush struct {
	mu   sync.Mutex
	last time.Time
	held []string
}

var trialSpendPushes sync.Map // *Server → *trialSpendPush

func (s *Server) spendPush() *trialSpendPush {
	v, _ := trialSpendPushes.LoadOrStore(s, &trialSpendPush{})
	return v.(*trialSpendPush)
}

// pushTrialSpend sends msg now, or holds it while the last push is fresher
// than trialSpendQuiet.
func (s *Server) pushTrialSpend(msg string, now time.Time) {
	p := s.spendPush()
	p.mu.Lock()
	if !p.last.IsZero() && now.Sub(p.last) < trialSpendQuiet {
		p.held = append(p.held, msg)
		p.mu.Unlock()
		log.Printf("fleet alert: trial_spend held (last push %s ago)", now.Sub(p.last).Round(time.Second))
		return
	}
	p.last = now
	p.mu.Unlock()
	s.trialNotify("trial_spend", msg)
}

// flushTrialSpend sends what was held, as one message, once the window ends.
func (s *Server) flushTrialSpend(now time.Time) {
	p := s.spendPush()
	p.mu.Lock()
	if len(p.held) == 0 || now.Sub(p.last) < trialSpendQuiet {
		p.mu.Unlock()
		return
	}
	msg := strings.Join(p.held, "\n\n")
	p.held, p.last = nil, now
	p.mu.Unlock()
	s.trialNotify("trial_spend", msg)
}

// trialNotify hands msg to the notifier and says so in the hub's log.
func (s *Server) trialNotify(what, msg string) {
	title, _, _ := strings.Cut(msg, "\n")
	if s.Notify == nil && s.NotifyCmd == "" {
		log.Printf("fleet notify: %s not pushed (no FLEET_NOTIFY_CMD): %s", what, title)
		return
	}
	log.Printf("fleet notify: %s pushed: %s", what, title)
	s.notify(msg)
}

// ── the real-time line ──────────────────────────────────────────────────

var trialSpendChecks sync.Map // *Server/pid → time.Time of the last check

// trialSpendWrote is a pool_usage row written for pid at now: check the
// lines, off the request and at most every trialSpendCheckEvery per person.
func (s *Server) trialSpendWrote(pid string, now time.Time) {
	if s.Store == nil || pid == "" {
		return
	}
	k := fmt.Sprintf("%p/%s", s, pid)
	if v, ok := trialSpendChecks.Load(k); ok && now.Sub(v.(time.Time)) < trialSpendCheckEvery {
		return
	}
	trialSpendChecks.Store(k, now)
	if trialSpendAsync {
		go s.trialSpendCheck(pid, now)
		return
	}
	s.trialSpendCheck(pid, now)
}

// trialSpendCheck raises (and pushes) pid's and everyone's line for today.
func (s *Server) trialSpendCheck(pid string, now time.Time) {
	line := s.trialAlert()
	if line.PersonDay <= 0 && line.AllDay <= 0 {
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil || !s.trialIdentity(settings, pid) {
		return
	}
	from, _ := trialSpendDay(now)
	day := from.Format("2006-01-02")
	en := s.adminsEnglish()
	if line.PersonDay > 0 {
		n, err := s.memberTokens(pid, from)
		if err != nil {
			log.Printf("fleet alerts: trial_spend %s: %v", pid, err)
		} else if n > line.PersonDay {
			s.raiseTrialSpend(pid, day, n, line.PersonDay, now, func() string {
				p := s.trialSpendPersonOf(settings, pid, now)
				return trialSpendPersonMsg(p, n, line.PersonDay, en, s.trialSpendLink(day, pid))
			})
		}
	}
	if line.AllDay > 0 {
		ps, err := s.Store.Principals()
		if err != nil {
			return
		}
		var total int64
		people := 0
		for _, p := range ps {
			if !s.trialIdentity(settings, p.ID) {
				continue
			}
			n, err := s.memberTokens(p.ID, from)
			if err != nil {
				return
			}
			if n > 0 {
				people++
			}
			total += n
		}
		if total > line.AllDay {
			s.raiseTrialSpend(trialSpendAllSubject, day, total, line.AllDay, now, func() string {
				return trialSpendAllMsg(people, total, line.AllDay, en, s.trialSpendLink(day, ""))
			})
		}
	}
}

// raiseTrialSpend opens (who, day)'s trial_spend; the first raise pushes.
func (s *Server) raiseTrialSpend(who, day string, tokens, line int64, now time.Time, msg func() string) {
	detail, _ := json.Marshal(map[string]any{"who": who, "day": day, "tokens": tokens, "line": line})
	raised, err := s.Store.RaiseFleetAlert(store.AlertTrialSpend, who+"@"+day, string(detail), now)
	if err != nil {
		log.Printf("fleet alerts: raise trial_spend %s@%s: %v", who, day, err)
		return
	}
	if !raised {
		return
	}
	log.Printf("fleet alert: trial_spend %s@%s — %d tokens today, over %d", who, day, tokens, line)
	_ = s.Store.HubAudit("hub", "trial.alert", who, "raised",
		fmt.Sprintf("%s: %s@%s %d > %d tokens", store.AlertTrialSpend, who, day, tokens, line), now)
	s.pushTrialSpend(msg(), now)
}

// trialSpendPersonOf is the words' view of pid now.
func (s *Server) trialSpendPersonOf(settings map[string]string, pid string, now time.Time) TrialSpendPerson {
	p := TrialSpendPerson{Principal: pid, Name: pid}
	var created time.Time
	if ps, err := s.Store.Principals(); err == nil {
		for _, x := range ps {
			if x.ID == pid {
				p.Name, created = firstSet(x.DisplayName, x.Login, pid), x.CreatedAt
			}
		}
	}
	t, _ := s.Store.Trial(pid)
	if t != nil {
		p.Kind = t.Kind
	}
	l, _ := memberLimitsOf(settings, pid)
	if start := trialStartOf(t, l, created); !start.IsZero() && !now.Before(start) {
		p.TrialDay = int(now.Sub(start)/(24*time.Hour)) + 1
	}
	return p
}

// ── the morning report ──────────────────────────────────────────────────

// TrialSpendTick runs on the alert sweep (one replica): pushes what the quiet
// window held, closes the days gone by, and at 09:00 Beijing sends the day
// before's report once.
func (s *Server) TrialSpendTick(now time.Time) {
	if s.Store == nil {
		return
	}
	s.flushTrialSpend(now)
	today, _ := trialSpendDay(now)
	todayKey := today.Format("2006-01-02")
	if subs, err := s.Store.OpenFleetAlertSubjects(store.AlertTrialSpend, ""); err == nil {
		for _, sub := range subs {
			if _, day, ok := strings.Cut(sub, "@"); ok && day < todayKey {
				_, _ = s.Store.ClearFleetAlert(store.AlertTrialSpend, sub, now)
			}
		}
	}
	if now.In(trialDay).Hour() < trialDailyHour || !s.trialAlert().Daily {
		return
	}
	from, to := trialSpendDay(today.Add(-time.Hour))
	day := from.Format("2006-01-02")
	if sent, err := s.Store.HubAuditHas("hub", trialDailyAction+"."+day); err != nil || sent {
		return
	}
	sum, err := s.trialSpend(from, to, now)
	if err != nil {
		log.Printf("fleet trial daily %s: %v", day, err)
		return
	}
	// A hub that runs no trial says nothing: the trial road off and nobody on
	// trial terms.
	if !s.trialOn() && len(sum.People) == 0 && !s.anyTrialIdentity() {
		return
	}
	line := fmt.Sprintf("day=%s new=%d active=%d tokens=%d pool=%d byo=%d over=%d all_over=%t",
		day, sum.New, sum.Active, sum.Tokens, sum.Pool, sum.BYO, sum.Over, sum.AllOver)
	// The mark first: a report is sent at most once, never twice.
	if err := s.Store.HubAudit("hub", trialDailyAction+"."+day, day, "sent", line, now); err != nil {
		log.Printf("fleet trial daily %s: audit: %v", day, err)
		return
	}
	log.Printf("fleet trial daily: %s", line)
	s.trialNotify("trial_daily "+day, trialDailyMsg(sum, now, s.adminsEnglish(), s.trialSpendLink(day, "")))
}

// anyTrialIdentity: someone is a trial identity now.
func (s *Server) anyTrialIdentity() bool {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return false
	}
	ps, err := s.Store.Principals()
	if err != nil {
		return false
	}
	for _, p := range ps {
		if s.trialIdentity(settings, p.ID) {
			return true
		}
	}
	return false
}
