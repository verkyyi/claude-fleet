package api

import (
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A person's door from a phone (claude-fleet#3069, EPIC #3067 C2): the
// address, the port, the login Termius asks for and how the door stands —
// what the new console's 设备 reads through EntryView's door (entryDoorOf).
// The server-drawn keys page that first said it, and 我的连接 beside it, went
// with the old console (claude-fleet#3939): their addresses only move on
// (consolePages).

// EntryPagePath is where the keys page was.
const EntryPagePath = "/fleet/keys"

// EntryConnPath is where 我的连接 was (claude-fleet#3199).
const EntryConnPath = "/fleet/connection"

// entryReturnCookie remembers, across the GitHub sign-in, where the browser
// was on its way to (loginReturn reads it; the trial and an admin request's page set it).
const entryReturnCookie = "ccquota_return"

// entryOpenGrace is how long after a new key (or home) the door is said to be
// 「正在打开」 before what is in the way is said (a var for tests).
var entryOpenGrace = 10 * time.Minute

type entryChoiceRow struct {
	Machine, Display, Login string
	Online, Current         bool
	Port                    int // the door's port from outside (entryPublicPort)
}

// entryBook is a person's book laid out as the door says it.
type entryBook struct {
	Domain   string
	Address  string // <name>.<domain>; "" when either is missing
	Port     int
	Home     *entryChoiceRow
	HomeWhy  string // why this machine is the home
	HomeDown string // when the home is not reachable: since when, or ""
	Keys     int
	State    string // nokey | opening | ok | down | far | nohome
	Why      string // State far: where it is stuck
}

// fillEntryBook lays the book v out: the address, the home, how the door
// stands.
func (s *Server) fillEntryBook(v EntryView, now time.Time, page *entryBook) {
	page.Domain = s.setting(EntryDomainKey)
	if v.Name != "" && page.Domain != "" {
		page.Address = v.Name + "." + page.Domain
	}
	var changed time.Time // the newest key, or the home's move: what the door must catch up with
	for _, k := range v.Keys {
		page.Keys++
		if k.Created.After(changed) {
			changed = k.Created
		}
	}
	for _, ch := range v.HomeChoices {
		if v.Home != nil && sameMachine(ch.Machine, v.Home.Machine) && ch.Login == v.Home.Login {
			page.Home = &entryChoiceRow{Machine: ch.Machine, Display: s.entryMachineName(ch.Machine), Login: ch.Login, Online: ch.Online,
				Current: true, Port: s.entryPublicPort(ch.Machine, now)}
			break
		}
	}
	if v.Home != nil && page.Home == nil {
		// The home has no live fleet right now: the machine is gone, or the
		// fleet on it is.
		page.Home = &entryChoiceRow{Machine: v.Home.Machine, Display: s.entryMachineName(v.Home.Machine), Login: v.Home.Login, Current: true,
			Port: s.entryPublicPort(v.Home.Machine, now)}
	}
	if page.Home != nil {
		// Two homes behind one router share the address and differ by the
		// port the router forwards (EPIC #3067 改约定 3, the entry= route): Termius's port is
		// the home's, not a constant.
		page.Port = page.Home.Port
		page.HomeWhy = "你自己选的。"
		if v.Home.SetBy == "auto" {
			page.HomeWhy = "系统替你选的：你在这台上有登录、上面开着 fleet"
			if len(v.HomeChoices) > 1 {
				page.HomeWhy += "，也是你平时打 fleet 进的那台"
			}
			page.HomeWhy += "。"
		}
		if v.Home.SetAt.After(changed) {
			changed = v.Home.SetAt
		}
	}
	if page.Home != nil && !page.Home.Online {
		page.HomeDown = "现在"
		if t := s.entryLastBeat(page.Home.Machine); t != nil {
			page.HomeDown = entryWhen(*t, now) + "起"
		}
	}
	page.State, page.Why = s.entryDoorState(page, changed, now)
}

// EntryDoor is how a person's way in from a phone stands (claude-fleet#3930):
// what Termius asks for — the address, the port, the login (the home's) — the
// door's state, and the three as a QR code the phone's
// camera hands to the app (ssh://<login>@<address>:<port>).
type EntryDoor struct {
	Domain   string `json:"domain,omitempty"`
	Address  string `json:"address,omitempty"` // <name>.<domain>; "" when either is missing
	Port     int    `json:"port"`
	Login    string `json:"login,omitempty"`     // the home's login: Termius's username
	HomeName string `json:"home_name,omitempty"` // the home machine as a person knows it
	HomeWhy  string `json:"home_why,omitempty"`
	HomeDown string `json:"home_down,omitempty"` // the home not reachable: since when
	// State: nokey | opening | ok | down | far | nohome; Why says where it is stuck (far).
	State string `json:"state"`
	Why   string `json:"why,omitempty"`
	// QR: the ssh:// address as rows of '#' (dark) and '.', no quiet zone; none
	// until there is an address and a home, and never for a pod (its one road
	// is Jump).
	QR []string `json:"qr,omitempty"`
	// Jump: for a home that is a pod behind the door, the one line a phone's
	// Jump host or a bare ssh copies (claude-fleet#4193); "" otherwise.
	Jump string `json:"jump,omitempty"`
	// HostFP: the SHA256 fingerprint of the host key the address answers with
	// (the home's entry, or the door's for a pod) — what a phone is asked to
	// trust once after a home move (T702); "" until one was seen.
	HostFP string `json:"host_fp,omitempty"`
}

// entryDoorOf is v's door, as fillEntryBook lays it out.
func (s *Server) entryDoorOf(v EntryView, now time.Time) EntryDoor {
	var page entryBook
	page.Port = entryPort
	s.fillEntryBook(v, now, &page)
	d := EntryDoor{Domain: page.Domain, Address: page.Address, Port: page.Port, HomeWhy: page.HomeWhy,
		HomeDown: page.HomeDown, State: page.State, Why: page.Why}
	if page.Home != nil {
		d.Login, d.HomeName = page.Home.Login, page.Home.Display
		d.HostFP = s.entryHostFP(s.entryAddrMachine(page.Home.Machine, now))
		pod := s.podBehindDoor(page.Home.Machine)
		if d.Address != "" && !pod {
			d.QR = qrMatrix(entrySSHURL(d.Login, d.Address, d.Port))
		}
		// a pod is reached only through the door's jump: no ssh://login@door
		// code (that was the door's per-login account, retired by T643)
		if d.Address != "" && pod {
			d.Jump = entryJumpLine(d.Address, d.Port, d.Login,
				s.jumpTarget(page.Home.Machine, s.entryAddrMachine(page.Home.Machine, now), now))
		}
	}
	return d
}

// entryHostFP is the SHA256 fingerprint of machine's entry host key, "" when
// none is known.
func (s *Server) entryHostFP(machine string) string {
	k, err := s.Store.EntryHostKey(machine)
	if err != nil || k == "" {
		return ""
	}
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(k))
	if err != nil {
		return ""
	}
	return ssh.FingerprintSHA256(pk)
}

// entrySSHURL is the address a phone's terminal app opens: ssh://login@host:port.
func entrySSHURL(login, host string, port int) string {
	return (&url.URL{Scheme: "ssh", User: url.User(login), Host: host + ":" + strconv.Itoa(port)}).String()
}

// entryDoorState is how the door stands for this person, said as a state
// rather than a failed check (claude-fleet#3199): no key yet (nothing to
// open); the home opening it since the last change (changed); the outside
// reaching it; the home itself away; or stuck — and then where.
func (s *Server) entryDoorState(page *entryBook, changed, now time.Time) (string, string) {
	switch {
	case page.Home == nil:
		return "nohome", ""
	case page.Keys == 0:
		return "nokey", ""
	case page.HomeDown != "":
		return "down", ""
	}
	m := page.Home.Machine
	name := page.Home.Display
	last, seen := s.entryLastReport(m)
	if seen && last.HeldBy != "" {
		// T702: another listener holds the port — the new list never reaches it,
		// whatever the outside sees
		return "far", "家机器 " + name + " 的入口端口被另一个程序占着（" + last.HeldBy + "），新名单没有生效。" +
			"请管理员在 " + name + " 上停掉它（fleet doctor 的 public 一行写着怎么做），一分钟内入口按新名单起来。"
	}
	if reach, err := s.EntryReachable(m, now); err == nil && len(reach) > 0 {
		return "ok", ""
	}
	rows, _ := s.entryReachRows(m)
	var checked time.Time
	for _, r := range rows {
		if r.CheckedAt.After(checked) {
			checked = r.CheckedAt
		}
	}
	// The newest word: a report that said nothing listens, else the dials.
	deaf := seen && !last.Listening && !last.At.Before(checked)
	if seen && last.At.After(checked) {
		checked = last.At
	}
	if now.Sub(changed) < entryOpenGrace && (checked.Before(changed) || deaf) {
		return "opening", ""
	}
	switch {
	case !seen && len(rows) == 0:
		return "far", "家机器 " + name + " 还没报告它的入口（每 5 分钟报一次）。一直这样，多半是那台的直连入口没开：请管理员在它上面看 fleet doctor 的 entry 一行。"
	case deaf:
		return "far", "家机器 " + name + " 上的入口没在听：请管理员在它上面看 fleet doctor 的 entry 一行。"
	case len(rows) == 0:
		return "far", "看不到家机器 " + name + " 的公网地址：它在运营商级 NAT 后面，又没有 IPv6。请管理员看那台 fleet doctor 的 public 一行。"
	}
	r := rows[0]
	at := fmt.Sprintf("%s:%d", r.Addr, r.Port)
	if r.Family == "ipv6" {
		at = fmt.Sprintf("[%s]:%d", r.Addr, r.Port)
	}
	there := name
	if seen && last.LAN != "" && last.Port > 0 {
		// the address on the home's own network (T702): two homes behind one
		// router share the public address, so "转到 <机器名>" alone does not say where
		there = fmt.Sprintf("%s（%s:%d）", name, last.LAN, last.Port)
	}
	switch r.Reason {
	case control.ReachHostKey:
		return "far", "从外面敲 " + at + "，应答的不是 " + name + " 的入口：路由器的端口 " + strconv.Itoa(r.Port) + " 转到了别处（另一台机器，或这台的普通 SSH），请管理员改成转到 " + there + "。"
	case control.ReachNotSSH:
		return "far", "从外面敲 " + at + "，应答的不是入口：端口 " + strconv.Itoa(r.Port) + " 被别的程序占着，请管理员看一眼。"
	}
	return "far", "从外面敲 " + at + " 没有回应：路由器还没把端口 " + strconv.Itoa(r.Port) + " 转到 " + there + "。请管理员在路由器上开这个端口（或看那台 fleet doctor 的 public 一行）。"
}

// entryMachineName is how a person knows a machine: its short name, else its
// first label.
func (s *Server) entryMachineName(host string) string {
	if a := machineAlias(host, s.machineNames()); a != "" {
		return a
	}
	for _, m := range s.fleetMachines() {
		if sameMachine(m.Hostname, host) && m.Alias != "" {
			return m.Alias
		}
	}
	return firstLabel(host)
}

// entryLastBeat is the newest heartbeat any login on host sent.
func (s *Server) entryLastBeat(host string) *time.Time {
	rows, err := s.Store.Nodes()
	if err != nil {
		return nil
	}
	var last *time.Time
	for _, n := range rows {
		if n.LastHeartbeat != nil && sameMachine(n.Hostname, host) && (last == nil || n.LastHeartbeat.After(*last)) {
			last = n.LastHeartbeat
		}
	}
	return last
}

// entryWhen is a time as a person reads it on a phone: how long ago, then the
// day (UTC+8, the people the door is for).
func entryWhen(t, now time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "刚才"
	case d < time.Hour:
		return fmt.Sprintf("%d 分钟前", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d 小时前", int(d.Hours()))
	case d < 7*24*time.Hour:
		return fmt.Sprintf("%d 天前", int(d.Hours()/24))
	}
	return t.In(time.FixedZone("CST", 8*3600)).Format("2006-01-02")
}

// entryReturnTo is where the GitHub sign-in sends a browser the cookie names,
// "" for any other; the cookie is spent. The old pages' addresses stay on the
// list for a cookie set before they went: they move on from there. An admin
// request's page (claude-fleet#4062) sets its own.
func entryReturnTo(w http.ResponseWriter, r *http.Request) string {
	c, err := r.Cookie(entryReturnCookie)
	if err != nil {
		return ""
	}
	http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: "", Path: "/", MaxAge: -1})
	switch c.Value { // the only places it may send anyone
	case EntryPagePath, EntryConnPath, ChatPagePath, TryPagePath:
		return c.Value
	}
	if adminRequestPageRe.MatchString(c.Value) {
		return c.Value
	}
	return ""
}
