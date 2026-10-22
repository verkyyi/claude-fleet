package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A trial person's machine share (claude-fleet WACK C4): every trial login on
// a machine is held to fleet.trial.limits — 4 cores, 8 GB, 20 GB of home by
// default — and a trial login that keeps the CPU pinned, mines or scans is
// renice'd, then paused, and the admins hear it. The hub only says WHO is on
// trial and records what the machine did; the machine measures and acts
// (bin/fleet-trial-guard.py, the root daemon's trial-guard task, through the
// root core's `trial` op). Two machine doors, the machine program's token:
//
//	GET  /v1/node/trial-limits  the limits + every trial login on this machine
//	POST /v1/node/trial-alert   {login, kind, what, action, detail, clear?}
//
// kind runaway (cpu · mem · disk over its line) raises trial_runaway, kind
// abuse (a miner, a pool port, a burst of new connections) trial_abuse; the
// subject is "<machine>/<login>". Each (kind, subject) tells the admins at
// most once in trialAlertQuiet (共同约定 4). fleet.trial.limits "off" = the
// list says off and the machine does nothing.

const (
	TrialLimitsKey      = "fleet.trial.limits"
	trialLimitsDefault  = "cpu=4,mem=8G,disk=20G"
	TrialLimitsNodePath = "/v1/node/trial-limits"
	TrialAlertNodePath  = "/v1/node/trial-alert"
	trialAlertQuiet     = 30 * time.Minute
)

func init() {
	hubSettings[TrialLimitsKey] = hubSetting{def: trialLimitsDefault,
		help: "每位试用者在机器上的份额：cpu=核数,mem=内存,disk=家目录（K/M/G/T）；持续满载先降优先级再暂停，内存超线停最大的进程，" +
			"磁盘超线提醒、超 120% 停会话；off = 不限 · a trial login's share of its machine: cpu=cores,mem=…,disk=home size " +
			"(K/M/G/T); sustained full load is renice'd then paused, memory over the line stops its largest process, disk over " +
			"the line warns and past 120% pauses its sessions; off = no limits (claude-fleet WACK C4)",
		check: checkTrialLimits}
}

// TrialLimits is fleet.trial.limits read: Off, or the three lines.
type TrialLimits struct {
	Off       bool
	CPU       float64
	MemBytes  int64
	DiskBytes int64
}

func (l TrialLimits) String() string {
	if l.Off {
		return "off"
	}
	return "cpu=" + strconv.FormatFloat(l.CPU, 'f', -1, 64) + ",mem=" + fmtBytes(l.MemBytes) + ",disk=" + fmtBytes(l.DiskBytes)
}

// fmtBytes is a size in the largest whole unit (8G, 1536M).
func fmtBytes(n int64) string {
	for _, u := range []struct {
		s string
		b int64
	}{{"T", 1 << 40}, {"G", 1 << 30}, {"M", 1 << 20}, {"K", 1 << 10}} {
		if n >= u.b && n%u.b == 0 {
			return strconv.FormatInt(n/u.b, 10) + u.s
		}
	}
	return strconv.FormatInt(n, 10)
}

// parseSize reads 8G / 512M / 20480K / a byte count.
func parseSize(v string) (int64, error) {
	v = strings.ToUpper(strings.TrimSuffix(strings.TrimSpace(v), "B"))
	mul := int64(1)
	if n := len(v); n > 0 {
		switch v[n-1] {
		case 'K':
			mul = 1 << 10
		case 'M':
			mul = 1 << 20
		case 'G':
			mul = 1 << 30
		case 'T':
			mul = 1 << 40
		}
		if mul > 1 {
			v = v[:n-1]
		}
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || f <= 0 || f*float64(mul) > float64(int64(1)<<50) {
		return 0, fmt.Errorf("%q is not a size (8G, 512M)", v)
	}
	return int64(f * float64(mul)), nil
}

// parseTrialLimits reads a stored value; "" is the default.
func parseTrialLimits(v string) (TrialLimits, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		v = trialLimitsDefault
	}
	if strings.EqualFold(v, "off") {
		return TrialLimits{Off: true}, nil
	}
	l := TrialLimits{CPU: 4, MemBytes: 8 << 30, DiskBytes: 20 << 30} // a part left out keeps the default's
	fs, err := limitFields(v)
	if err != nil {
		return l, err
	}
	for _, f := range fs {
		switch f[0] {
		case "cpu":
			c, err := strconv.ParseFloat(f[1], 64)
			if err != nil || c <= 0 || c > 1024 {
				return l, fmt.Errorf("cpu is cores, 0..1024")
			}
			l.CPU = c
		case "mem":
			if l.MemBytes, err = parseSize(f[1]); err != nil {
				return l, fmt.Errorf("mem: %v", err)
			}
		case "disk":
			if l.DiskBytes, err = parseSize(f[1]); err != nil {
				return l, fmt.Errorf("disk: %v", err)
			}
		default:
			return l, fmt.Errorf("%q: the parts are cpu, mem, disk", f[0])
		}
	}
	return l, nil
}

func checkTrialLimits(_ *Server, v string) (string, string) {
	l, err := parseTrialLimits(v)
	if err != nil {
		return "", TrialLimitsKey + ": " + err.Error() + ` — e.g. "cpu=4,mem=8G,disk=20G", or "off"`
	}
	return l.String(), ""
}

func (s *Server) trialLimits() TrialLimits {
	l, err := parseTrialLimits(s.setting(TrialLimitsKey))
	if err != nil {
		log.Printf("fleet: %s: %v — the default holds", TrialLimitsKey, err)
		l, _ = parseTrialLimits("")
	}
	return l
}

// TrialGuardList is GET TrialLimitsNodePath's answer.
type TrialGuardList struct {
	On        bool              `json:"on"`
	Limits    string            `json:"limits"`
	CPU       float64           `json:"cpu"`
	MemBytes  int64             `json:"mem_bytes"`
	DiskBytes int64             `json:"disk_bytes"`
	Logins    map[string]string `json:"logins"` // login → person
}

func (s *Server) trialGuardMachine(w http.ResponseWriter, r *http.Request) string {
	w.Header().Set("Cache-Control", "no-store")
	if !nodeAuthHeld(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
	}
	ep, _, ok := s.nodeEndpointOr(w, r, "the machine's node token is required", "unrecognised node token")
	if !ok {
		return ""
	}
	if !s.Fleet {
		httpError(w, http.StatusNotFound, "no fleet module on this hub")
		return ""
	}
	return s.nodeMachineHost(w, r, ep)
}

// trialGuardList is host's list: its logins whose person is on trial
// (trialIdentity, the batch's one reading — WACK 共同约定 2).
func (s *Server) trialGuardList(host string) (TrialGuardList, error) {
	l := s.trialLimits()
	out := TrialGuardList{On: !l.Off, Limits: l.String(), CPU: l.CPU, MemBytes: l.MemBytes, DiskBytes: l.DiskBytes,
		Logins: map[string]string{}}
	if l.Off {
		return out, nil
	}
	// a login the hub opened or lent here (a trial's seat), and a person's
	// entry home here (what trial-egress reads, WACK C3)
	accts, err := s.Store.ActiveAccountsOn(host)
	if err != nil {
		return out, err
	}
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return out, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return out, err
	}
	add := func(login, pid string) {
		if _, dup := out.Logins[login]; dup || !control.ValidExistingLogin(login) || s.isFleetAdmin(login) {
			return
		}
		if s.trialIdentity(settings, pid) {
			out.Logins[login] = pid
		}
	}
	for _, a := range accts {
		add(a.Login, a.PrincipalID)
	}
	for _, h := range homes {
		if sameMachine(host, h.Machine) || sameMachine(h.Machine, host) {
			add(h.Login, h.Person)
		}
	}
	return out, nil
}

func (s *Server) handleNodeTrialLimits(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	host := s.trialGuardMachine(w, r)
	if host == "" {
		return
	}
	out, err := s.trialGuardList(host)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// TrialAlertRequest is POST TrialAlertNodePath.
type TrialAlertRequest struct {
	Login  string `json:"login"`
	Kind   string `json:"kind"`   // runaway | abuse
	What   string `json:"what"`   // cpu · mem · disk · miner · pool · scan
	Action string `json:"action"` // renice · pause · kill · warn · resume
	Detail string `json:"detail,omitempty"`
	Clear  bool   `json:"clear,omitempty"`
}

var trialAlertKinds = map[string]string{"runaway": store.AlertTrialRunaway, "abuse": store.AlertTrialAbuse}
var trialAlertWhat = map[string]bool{"cpu": true, "mem": true, "disk": true, "miner": true, "pool": true, "scan": true}
var trialAlertActions = map[string]bool{"renice": true, "pause": true, "kill": true, "warn": true, "resume": true}

// trialTold is when each (kind, subject) last reached the admins.
var trialTold = struct {
	sync.Mutex
	at map[string]time.Time
}{at: map[string]time.Time{}}

func (s *Server) handleNodeTrialAlert(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	host := s.trialGuardMachine(w, r)
	if host == "" {
		return
	}
	var req TrialAlertRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "want {login, kind, what, action, detail?, clear?}")
		return
	}
	kind, ok := trialAlertKinds[req.Kind]
	if !ok || !trialAlertWhat[req.What] || (!req.Clear && !trialAlertActions[req.Action]) {
		httpError(w, http.StatusBadRequest, "kind is runaway | abuse; what cpu · mem · disk · miner · pool · scan; action renice · pause · kill · warn · resume")
		return
	}
	if d := []rune(req.Detail); len(d) > 300 {
		req.Detail = string(d[:300])
	}
	list, err := s.trialGuardList(host)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	person, ok := list.Logins[req.Login]
	if !ok {
		// a member's login is never written up as a trial's (完成判据: 成员不受影响)
		httpError(w, http.StatusForbidden, "login "+req.Login+" on "+host+" is not a trial login")
		return
	}
	subject := strings.ToLower(host) + "/" + req.Login
	now := time.Now()
	if req.Clear {
		cleared, err := s.Store.ClearFleetAlert(kind, subject, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "cleared": cleared})
		return
	}
	b, _ := json.Marshal(map[string]string{"person": person, "what": req.What, "action": req.Action, "detail": req.Detail})
	raised, err := s.Store.RaiseFleetAlert(kind, subject, string(b), now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	line := req.What + " → " + req.Action
	if req.Detail != "" {
		line += ": " + req.Detail
	}
	if err := s.Store.HubAudit("node:"+host, "trial.guard", subject, req.Action, line, now); err != nil {
		log.Printf("trial guard: audit %s: %v", subject, err)
	}
	told := false
	trialTold.Lock()
	k := kind + "\x00" + subject
	if last := trialTold.at[k]; last.IsZero() || now.Sub(last) >= trialAlertQuiet {
		trialTold.at[k] = now
		told = true
	}
	trialTold.Unlock()
	if told {
		log.Printf("fleet alert: %s %s: %s", kind, subject, line)
		s.notify(trialAlertWords(kind, host, req, person))
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "raised": raised, "told": told})
}

var trialWhatWords = map[string][2]string{
	"cpu":   {"CPU 持续满载", "CPU pinned"},
	"mem":   {"内存超线", "memory over the line"},
	"disk":  {"家目录超线", "home over its size"},
	"miner": {"疑似挖矿进程", "a miner-like process"},
	"pool":  {"连向矿池端口", "a connection to a mining-pool port"},
	"scan":  {"短时大量新连接（疑似扫描）", "a burst of new connections (a scan?)"},
}

var trialActionWords = map[string][2]string{
	"renice": {"已降低优先级", "renice'd"},
	"pause":  {"已暂停它的进程", "its processes paused"},
	"kill":   {"已停掉最大的进程", "its largest process stopped"},
	"warn":   {"已提醒", "warned"},
	"resume": {"已恢复", "resumed"},
}

// trialAlertWords is the admins' one message, Chinese then English (共同约定 6).
func trialAlertWords(kind, host string, req TrialAlertRequest, person string) string {
	w, a := trialWhatWords[req.What], trialActionWords[req.Action]
	msg := fmt.Sprintf("fleet 试用告警 %s · %s 上的 %s（%s）：%s，%s。 · trial alert %s · %s on %s (%s): %s, %s.",
		kind, host, req.Login, person, w[0], a[0], kind, req.Login, host, person, w[1], a[1])
	if req.Detail != "" {
		msg += " — " + req.Detail
	}
	return msg + " 解除：fleet-trial-guard.py resume " + req.Login + " · to resume: fleet-trial-guard.py resume " + req.Login
}
