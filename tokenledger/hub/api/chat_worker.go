package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 会话合一 ② (task PQ41): the web talks to a SESSION, never to a conversation
// beside it. Every web conversation is a session on one of the person's
// machines, and every session — one opened from the web or from a terminal —
// takes the person's words the same way: the entry finds the session by its
// worker id and hands the words to the conversation service on the login it
// runs on, which gives them to the session (or queues / refuses them: its gate,
// task HHV0 ①).
//
//	browser ──POST /v1/chat/say|answer|stop?worker=<id> (X-Fleet-Webchat: 1)──▶ hub
//	hub: who (termPerson) · the worker theirs (termTarget: home or another of
//	     their own active logins, else 404 not_yours)
//	hub ──dialChatRelay──▶ that login's /api/say|answer|stop {"fid": <window>, …}
//
// say:    {text, images: [≤4 {media_type, data}]} → {delivery, state: sent |
//         queued | refused, reason?}
// answer: the question's fingerprint and the option's own words
// stop:   nothing — the session's current turn is stopped (Esc)
// ack:    {delivery} — a line the session's queue gave back, taken off it
//
// The browser names a worker id, never a window: the body's fid is the hub's.
// There is no relay lock any more — who may talk is the session gate's word
// (can_talk, the board's), so 接管 / 交回 and 在这里继续 are gone: with
// fleet.chat.unified on, /v1/chat/turn|new|take|takeover|giveback answer 410
// moved for one version (chatMovedRoutes); off, they still relay as before
// (compat-1v: 下一批删 — the last of HHV0 ① / Y01K ③ to land turns it on).

// chatWorkerRoutes is the worker road: the route, the service's path, how long
// one call may take (a say is handed over, never streamed).
var chatWorkerRoutes = map[string]struct {
	path string
	wait time.Duration
}{
	"say":    {"say", 30 * time.Second},
	"answer": {"answer", 30 * time.Second},
	"stop":   {"stop", 15 * time.Second},
	// a line the session's queue gave back, taken off it by the page
	"ack": {"ack", 15 * time.Second},
	// the old 接管 / 交回 (task VV8F): home only, while fleet.chat.unified is off
	"takeover": {"takeover", 45 * time.Second}, // compat-1v: 下一批删
	"giveback": {"giveback", 45 * time.Second}, // compat-1v: 下一批删
}

// chatSayImages is how many pictures one say carries (the service's PICS_PER_TURN).
const chatSayImages = 4

// ChatUnifiedKey switches the old conversation routes off (task PQ41).
const ChatUnifiedKey = "fleet.chat.unified"

// chatMovedRoutes answer 410 moved once fleet.chat.unified is on.
var chatMovedRoutes = map[string]bool{"turn": true, "new": true, "take": true, "takeover": true, "giveback": true}

func init() {
	hubSettings[ChatUnifiedKey] = hubSetting{def: "off",
		help:  "会话合一 (task PQ41): on — the web talks to sessions only (/v1/chat/say|answer|stop?worker=), the old /v1/chat/turn|new|take|takeover|giveback answer 410 moved; off — they still relay (until the home's session gate and the new page are out) · 网页只和会话说话，旧路由回「已移动」",
		check: onOff(ChatUnifiedKey, "off")}
}

func (s *Server) chatUnified() bool { return s.setting(ChatUnifiedKey) == "on" }

// chatMoved answers a retired route: 410, where it went.
func (s *Server) chatMoved(w http.ResponseWriter, r *http.Request, name string) {
	person, _, _, _ := s.chatPerson(r)
	if person == "" {
		person = "anonymous"
	}
	s.chatAudit(person, "chat_refused", "moved "+name)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusGone, map[string]string{"code": "moved",
		"error": "这条路已移动：网页现在直接和会话说话（POST /v1/chat/say?worker=<id>）· moved: talk to a session (POST /v1/chat/say?worker=<id>)",
		"to":    ChatPathPrefix + "say"})
}

// handleChatWorker serves the worker road (and the old 接管 / 交回 while it lasts).
func (s *Server) handleChatWorker(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	person, status, code, msg := s.termPerson(r)
	if code != "" {
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		}
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	if r.Header.Get("X-Fleet-Webchat") != "1" {
		s.chatRefuse(w, person, name, http.StatusForbidden, "forbidden", "X-Fleet-Webchat: 1 is required")
		return
	}
	_ = s.Store.TouchTrial(person, time.Now()) // a trial in use is not idle (claude-fleet#3590)
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		home = store.EntryHome{}
	}
	home.Person = person
	wid, target, dest, status, code, msg := s.termTarget(r.URL.Query(), home)
	if code == "" && wid == control.TermTargetPersonal {
		status, code, msg = http.StatusBadRequest, "bad_target", "a session's worker id"
	}
	if code != "" {
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	legacy := name == "takeover" || name == "giveback"
	// the old handover took a session into the home's own conversation: home only
	if legacy && (home.Machine == "" || dest.Machine != home.Machine || dest.Login != home.Login) {
		s.chatRefuse(w, person, name, http.StatusConflict, "not_home",
			"这个会话不在你的家机器上，网页接管不了；请到它的终端里说")
		return
	}
	// The body: the page's own, bounded and read whole here — a JSON object whose
	// fid the hub writes (the browser never names a window).
	in := map[string]any{}
	if !legacy {
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, chatBodyMax))
		if err != nil {
			s.chatRefuse(w, person, name, http.StatusRequestEntityTooLarge, "too_large", "图太大：一条消息连图带字最多 1 MB · at most 1 MB with the pictures")
			return
		}
		if len(bytes.TrimSpace(raw)) > 0 {
			if err := json.Unmarshal(raw, &in); err != nil {
				s.chatRefuse(w, person, name, http.StatusBadRequest, "bad_body", "a JSON object")
				return
			}
		}
		if name == "say" {
			text, _ := in["text"].(string)
			pics, _ := in["images"].([]any)
			if in["images"] != nil && pics == nil {
				s.chatRefuse(w, person, name, http.StatusBadRequest, "bad_body", "images is a list")
				return
			}
			if len(pics) > chatSayImages {
				s.chatRefuse(w, person, name, http.StatusBadRequest, "too_many_images", "一条消息最多 4 张图 · at most 4 pictures")
				return
			}
			if strings.TrimSpace(text) == "" && len(pics) == 0 {
				s.chatRefuse(w, person, name, http.StatusBadRequest, "empty", "nothing to say")
				return
			}
		}
	}
	in["fid"] = target[len(control.TermWorkerTarget("")):]
	where := dest.Machine + "/" + dest.Login
	s.awaitChatLink(r, dest.Machine, dest.Login, s.chatLinkWait()) // a reconnecting home: wait for its link (task PNWW)
	if peer, ok := s.chatRelayPeer(r, dest.Machine, dest.Login); ok {
		if !legacy {
			// the body was read here: the peer gets the same bytes back
			b, _ := json.Marshal(withoutFid(in))
			r.Body = io.NopCloser(bytes.NewReader(b))
			r.ContentLength = int64(len(b))
		}
		s.proxyRelay(w, r, peer, "a chat "+name+" to "+where)
		return
	}
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(dest.Machine, settings); flagged {
			s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器在维护中，现在连不上")
			return
		}
	}
	if _, _, err := s.chatRelayNode(dest.Machine, dest.Login); err != nil {
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "NO_CHAT" {
			s.chatRefuse(w, person, name+" "+where, http.StatusConflict, "old_agent",
				"这台机器的 fleet 还旧，网页里说不了；更新后就能，现在请用终端")
			return
		}
		if s.homeReconnecting(dest.Machine, dest.Login) {
			w.Header().Set("Retry-After", "3")
			s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_reconnecting", "正在重连这台机器，稍候")
			return
		}
		s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
		return
	}
	gateKey := person + "\x00worker"
	if why := s.chatGate.admit(gateKey, defaultChatPerPerson, defaultChatPerMinute, time.Now()); why != "" {
		s.chatRefuse(w, person, name, http.StatusTooManyRequests, why, "too many chat requests; wait a moment")
		return
	}
	defer s.chatGate.release(gateKey)
	// A trial's lines (claude-fleet#4059): a say is a line, given back when the
	// session does not take it.
	refund := func(string) {}
	if name == "say" {
		s.trialFirstLine(person, time.Now()) // a 试用二维码's 60 seconds end here (MRGB)
		code, msg, counted := s.trialTurn(w, person, time.Now())
		if code != "" {
			s.chatRefuse(w, person, name, http.StatusForbidden, code, msg)
			return
		}
		if counted {
			var once sync.Once
			refund = func(why string) { once.Do(func() { s.trialRefund(person, why) }) }
		}
	}

	one := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			c, err := s.dialChatRelay(ctx, person, dest.Machine, dest.Login)
			if err == nil {
				s.chatAudit(person, "chat_relay", "OPENED "+name+" "+wid+" "+where)
			}
			return c, err
		},
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	defer one.CloseIdleConnections()
	body, _ := json.Marshal(in)
	route := chatWorkerRoutes[name]
	ctx, cancel := context.WithTimeout(r.Context(), route.wait)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://webchat/api/"+route.path, bytes.NewReader(body))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Fleet-Webchat", "1")
	req.Header.Set(control.ChatPersonHeader, person)
	if c := s.chatClientHeader(r); c != "" {
		req.Header.Set(control.ChatClientHeader, c)
	}
	resp, err := one.RoundTrip(req)
	if err != nil {
		refund("the relay did not reach the service")
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "TOO_MANY" {
			s.chatRefuse(w, person, name+" "+where, http.StatusTooManyRequests, "too_many", re.msg)
			return
		}
		s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
		return
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	// a service from before this step has no such route: say so, as the view does
	if resp.StatusCode == http.StatusNotFound && !strings.Contains(string(out), `"code"`) {
		refund("the service has no " + name)
		s.chatRefuse(w, person, name+" "+where, http.StatusConflict, "old_service",
			"这台机器的网页对话服务还旧，网页里说不了；更新后就能，现在请用终端")
		return
	}
	if resp.StatusCode != http.StatusOK {
		refund("the service refused: " + resp.Status)
	} else if name == "say" {
		var a struct {
			State string `json:"state"`
		}
		if json.Unmarshal(out, &a) == nil {
			if a.State == "refused" {
				refund("the session refused the line")
			} else if a.State == "sent" || a.State == "queued" {
				s.trialNextDayLine(person, time.Now())
			}
		}
	}
	s.chatAudit(person, "chat_relay", strings.ToUpper(name)+" "+wid+" "+where+" "+resp.Status)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
}

// withoutFid is the page's body as it came: the fid is each replica's to write.
func withoutFid(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		if k != "fid" {
			out[k] = v
		}
	}
	return out
}

// SessionParkIdleKey is how long an unattended-to-human session may sit idle
// before its home parks it (task PQ41 / HHV0 ①: its agent let go, its
// credential kept, the next line takes it back) — handed to every node as
// FLEET_SESSION_PARK_IDLE (seconds; 0 = never) with the pool's settings.
// Every origin uses this path when its wrapper can hold a parked session.
const SessionParkIdleKey = "fleet.session.park_idle"

const (
	defaultSessionParkIdle = 5 * time.Minute
	maxSessionParkIdle     = 24 * time.Hour
)

func init() {
	for key, def := range map[string]string{
		"fleet.session.park_idle_unattended": "5m",
		"fleet.session.park_presence":        "15m",
	} {
		key := key
		hubSettings[key] = hubSetting{def: def,
			help: "idle parking: unattended grace (5m conservative default; 1m opt-in), or how long human presence stays recent",
			check: func(_ *Server, v string) (string, string) {
				d, err := time.ParseDuration(strings.TrimSpace(v))
				if err != nil || d < time.Minute || d > maxSessionParkIdle {
					return "", key + " must be a duration from 1m to 24h"
				}
				return d.String(), ""
			}}
	}
	hubSettings["fleet.session.wake_slots"] = hubSetting{def: "3",
		help: "simultaneous parked session starts per machine, shared by all logins (1–32)",
		check: func(_ *Server, v string) (string, string) {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil || n < 1 || n > 32 {
				return "", "fleet.session.wake_slots must be an integer from 1 to 32"
			}
			return strconv.Itoa(n), ""
		}}

	hubSettings["fleet.session.reap_parked"] = hubSetting{def: "3d",
		help: "close an inactive parked conversation after this long, after recording resumable history (1h–366d) · 停放多久后回收",
		check: func(_ *Server, v string) (string, string) {
			d, ok := sessionReapParkedDuration(v)
			if !ok {
				return "", "fleet.session.reap_parked must be a duration from 1h to 366d"
			}
			return d.String(), ""
		}}

	hubSettings[SessionParkIdleKey] = hubSetting{def: "5m",
		help: "an idle session with human presence parks after this long (1m–24h, or off); watched panes, drafts and background work stay running · 有人交互的会话空闲多久停放",
		check: func(_ *Server, v string) (string, string) {
			v = strings.ToLower(strings.TrimSpace(v))
			if v == "off" {
				return v, ""
			}
			d, err := time.ParseDuration(v)
			if err != nil || d < time.Minute || d > maxSessionParkIdle {
				return "", SessionParkIdleKey + ` is a duration 1m–24h (5m, 30m, 2h) or off, or "" for the default (5m)`
			}
			return d.String(), ""
		}}
}

// sessionParkIdle is the setting in seconds; 0 = never park.
func (s *Server) sessionParkIdle() int {
	v := strings.TrimSpace(s.setting(SessionParkIdleKey))
	if v == "off" {
		return 0
	}
	d, err := time.ParseDuration(v)
	if err != nil || d < time.Minute || d > maxSessionParkIdle {
		d = defaultSessionParkIdle
	}
	return int(d / time.Second)
}

func (s *Server) sessionParkDuration(key, fallback string) int {
	value := s.setting(key)
	d, err := time.ParseDuration(value)
	if err != nil || d < time.Minute || d > maxSessionParkIdle {
		d, _ = time.ParseDuration(fallback)
	}
	return int(d / time.Second)
}

func sessionReapParkedDuration(v string) (time.Duration, bool) {
	v = strings.TrimSpace(v)
	if strings.HasSuffix(v, "d") {
		n, err := strconv.Atoi(strings.TrimSuffix(v, "d"))
		if err != nil || n < 1 || n > 366 {
			return 0, false
		}
		return time.Duration(n) * 24 * time.Hour, true
	}
	d, err := time.ParseDuration(v)
	return d, err == nil && d >= time.Hour && d <= 366*24*time.Hour
}

func (s *Server) sessionReapParked() int {
	d, ok := sessionReapParkedDuration(s.setting("fleet.session.reap_parked"))
	if !ok {
		d = 72 * time.Hour
	}
	return int(d / time.Second)
}

// chatOpenWorker adds the new session's worker id (`worker`) to /api/open's answer (task
// PQ41): the home names its window (fid); the page talks to it by worker id,
// <the login's fleet>/<fid> — named only when the login runs exactly one fleet
// the hub has heard (else the page finds it on the board by its id, the fid).
func (s *Server) chatOpenWorker(resp *http.Response, machine, login string) {
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	resp.ContentLength = int64(len(raw))
	var out map[string]any
	if err != nil || json.Unmarshal(raw, &out) != nil {
		return
	}
	fid, _ := out["fid"].(string)
	if fid == "" || strings.Contains(fid, "/") {
		return
	}
	rows, err := s.Store.Fleets()
	if err != nil {
		return
	}
	fleet := ""
	for _, f := range rows {
		if f.Present && f.Hostname == machine && f.OSUser == login {
			if fleet != "" {
				return // two fleets on one login: the board says which
			}
			fleet = f.FleetID
		}
	}
	if fleet == "" {
		return
	}
	out["worker"] = fleet + "/" + fid
	b, err := json.Marshal(out)
	if err != nil {
		return
	}
	resp.Body = io.NopCloser(bytes.NewReader(b))
	resp.ContentLength = int64(len(b))
	resp.Header.Set("Content-Length", strconv.Itoa(len(b)))
}
