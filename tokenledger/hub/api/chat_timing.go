package api

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A new web session's wait (task PNWW). The console's 新会话 page starts a
// clock at the press and stops it at the first words of the reply on screen;
// POST ChatPathPrefix+"timing" keeps it with two stages inside it — open_ms
// (/v1/chat/open answered) and shown_ms (the session's page drawn) — the agent
// and the page's IANA time zone. Nothing names the person: the home's machine
// is read here, and a mainland start is one whose zone is China's. GET
// ChatTimingStatsPath (admin) is the p50 / p90 per stage, all and mainland.
const (
	chatTimingRoute     = "timing"
	ChatTimingStatsPath = "/v1/fleet/chat/timing"
	// chatTimingMaxMS: anything longer was not one sitting
	chatTimingMaxMS int64 = 600 * 1000
)

var chatTimingIDRe = regexp.MustCompile(`^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$`)

var chatTZRe = regexp.MustCompile(`^[A-Za-z0-9_+\-/]{1,64}$`)

// cnZones are the IANA zones a browser in mainland China reports.
var cnZones = map[string]bool{"Asia/Shanghai": true, "Asia/Chongqing": true, "Asia/Chungking": true, "Asia/Harbin": true,
	"Asia/Urumqi": true, "Asia/Kashgar": true, "PRC": true}

func (s *Server) handleChatTiming(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	person, status, code, msg := s.chatPerson(r)
	if code != "" {
		s.chatRefuse(w, person, chatTimingRoute, status, code, msg)
		return
	}
	if r.Header.Get("X-Fleet-Webchat") != "1" {
		s.chatRefuse(w, person, chatTimingRoute, http.StatusForbidden, "forbidden", "X-Fleet-Webchat: 1 is required")
		return
	}
	var in struct {
		ID      string `json:"id"`
		MS      int64  `json:"ms"`
		OpenMS  int64  `json:"open_ms"`
		ShownMS int64  `json:"shown_ms"`
		Agent   string `json:"agent"`
		TZ      string `json:"tz"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&in); err != nil ||
		in.MS <= 0 || in.MS > chatTimingMaxMS || in.OpenMS < 0 || in.OpenMS > in.MS || in.ShownMS < 0 || in.ShownMS > in.MS {
		httpError(w, http.StatusBadRequest, "ms: the press to the first reply on screen, at most 10 minutes; open_ms and shown_ms inside it")
		return
	}
	if in.Agent != "claude" && in.Agent != "codex" {
		in.Agent = ""
	}
	if !chatTZRe.MatchString(in.TZ) {
		in.TZ = ""
	}
	if in.ID != "" && !chatTimingIDRe.MatchString(in.ID) {
		httpError(w, 400, "invalid timing id")
		return
	}
	t := store.ChatTiming{ID: in.ID, At: time.Now(), MS: in.MS, OpenMS: in.OpenMS, ShownMS: in.ShownMS, Agent: in.Agent, TZ: in.TZ}
	if home, ok, err := s.Store.EntryHomeOf(person); err == nil && ok {
		t.Machine = home.Machine
	}
	if err := s.Store.RecordChatTiming(t); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"kept": true})
}

// chatTimingStats is the admin's read: each stage's spread, for every start
// and for the mainland's.
type chatTimingStats struct {
	Daily    map[string]map[string]chatTimingSpread `json:"daily"`
	Agents   map[string]chatTimingSpread            `json:"agents"`
	Days     int                                    `json:"days"`
	All      chatTimingSpread                       `json:"all"`
	Mainland chatTimingSpread                       `json:"mainland"`
	Machines map[string]chatTimingSpread            `json:"machines"`
}

type chatTimingSpread struct {
	Reply durStats `json:"reply"`
	Open  durStats `json:"open"`
	Shown durStats `json:"shown"`
}

func chatSpread(ts []store.ChatTiming) chatTimingSpread {
	var reply, open, shown []float64
	for _, t := range ts {
		reply = append(reply, float64(t.MS)/1000)
		if t.OpenMS > 0 {
			open = append(open, float64(t.OpenMS)/1000)
		}
		if t.ShownMS > 0 {
			shown = append(shown, float64(t.ShownMS)/1000)
		}
	}
	st := func(xs []float64) durStats {
		return durStats{N: len(xs), MedianSecs: percentile(xs, 0.5), P90Secs: percentile(xs, 0.9)}
	}
	return chatTimingSpread{Reply: st(reply), Open: st(open), Shown: st(shown)}
}

func (s *Server) handleChatTimingStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	days := 7
	if v := r.URL.Query().Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 90 {
			httpError(w, http.StatusBadRequest, "days: 1 to 90")
			return
		}
		days = n
	}
	ts, err := s.Store.ChatTimings(time.Now().Add(-time.Duration(days) * 24 * time.Hour))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, chatTimingStatsOf(days, ts))
}

func chatTimingStatsOf(days int, ts []store.ChatTiming) chatTimingStats {
	var cn []store.ChatTiming
	agents := map[string][]store.ChatTiming{}
	daily := map[string]map[string][]store.ChatTiming{}
	byMachine := map[string][]store.ChatTiming{}
	for _, t := range ts {
		agents[t.Agent] = append(agents[t.Agent], t)
		day := t.At.UTC().Format("2006-01-02")
		if daily[day] == nil {
			daily[day] = map[string][]store.ChatTiming{}
		}
		daily[day][t.Agent] = append(daily[day][t.Agent], t)
		if cnZones[t.TZ] {
			cn = append(cn, t)
		}
		m := strings.TrimSpace(t.Machine)
		if m == "" {
			m = "-"
		}
		byMachine[m] = append(byMachine[m], t)
	}
	out := chatTimingStats{Days: days, All: chatSpread(ts), Mainland: chatSpread(cn), Machines: map[string]chatTimingSpread{}}
	for m, xs := range byMachine {
		out.Machines[m] = chatSpread(xs)
	}
	out.Agents = map[string]chatTimingSpread{}
	out.Daily = map[string]map[string]chatTimingSpread{}
	for a, xs := range agents {
		out.Agents[a] = chatSpread(xs)
	}
	for d, as := range daily {
		out.Daily[d] = map[string]chatTimingSpread{}
		for a, xs := range as {
			out.Daily[d][a] = chatSpread(xs)
		}
	}
	return out
}
