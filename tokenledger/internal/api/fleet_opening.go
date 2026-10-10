package api

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A newcomer's own word on their login (claude-fleet#2069, EPIC #2140 C1).
//
// A person signed in with GitHub, ran the installer, and typed a name into an
// empty list: before, the client could only say "no machine of yours hosts a
// repo yet" for four seconds. The hub knows more — a login queued for them by
// fleet.auto_assign is being opened right now, or nothing is coming and the
// operator must give them one — and says it on every door the client reads
// (/v1/nodes and /v1/fleet/summary as `account`, /v1/fleet/home as `state`),
// so the client can hold a 「正在为你开机器，约 1 分钟」 and retry on its own,
// or name who to ask. A person with an active login gets no `account` at all:
// byte for byte the answer before.

// openingETA is the client's "about how long" for a login being opened when
// its machine has opened none yet. It was 60 s — "one useradd + the fleet's
// own install" — but a real create on a Mac runs sysadminctl (minutes), the
// clone, credential separation and the daemons: the drill of 2026-10-09 read
// 「about 5s」 for six minutes (claude-fleet#2696). 8 min was still short:
// macmini's create of drill10100612 (claude-fleet#2908) — record 23:14,
// `sysadminctl -addUser` done 23:19 (5 min alone, on every drill run), home
// with the install and daemons 23:27 — took 13 min and more, so a machine
// with no history of its own is told 14. A machine that has opened logins
// answers with its own measured median instead (openingETAFor).
const openingETA = 14 * 60

// openingGiveUp is how long a create may stay pending / creating / unknown
// before the doors stop saying opening and say failed — name who to ask: the
// node gives one op accountOpTimeout (15 min), plus room for a queue of one.
// openingNoAdmin is how long a create may wait unsent because its machine has
// no admin node connected to run it. Variables so tests can move them.
var (
	openingGiveUp  = 20 * time.Minute
	openingNoAdmin = 2 * time.Minute
)

// openingOverFloor is the least a create may run before running past its
// machine's own estimate fails it (claude-fleet#2941): past 3 × the estimate,
// never sooner than this, never later than openingGiveUp. A machine whose
// median is 60 s gave its newcomer 「about 59s」 and then nothing for six
// minutes; a real create that runs long still turns active when it answers.
var openingOverFloor = 8 * time.Minute

// A login the node opened (create ok → active) is not yet a place a session
// can open: its own node must enroll with the create's join code, say hello
// and report its fleet (claude-fleet#2941). Until a fleet of that login is
// registered the doors keep saying opening — about openingSettleETA more —
// and past openingSettle they say failed, naming the step that did not come.
// Before, active alone read as done: every door went quiet, placement said
// 「mini2: 没有你的登录」 and nobody said why.
const openingSettleETA = 90

var openingSettle = 10 * time.Minute

// AccountState is a person's login, when they have no active one yet.
type AccountState struct {
	// State is opening (a create is queued or in flight), failed (the last
	// create failed — the operator retries it) or none (nothing is coming:
	// fleet.auto_assign is off, or no machine was fit).
	State string `json:"state"`
	// EtaS is how many more seconds opening is expected to take (≥ 5).
	EtaS int `json:"eta_s,omitempty"`
	// Machine is where it is being opened.
	Machine string `json:"machine,omitempty"`
	// Login is the login being opened.
	Login string `json:"login,omitempty"`
	// Ask is who gives a person a machine: the hub's admin logins.
	Ask string `json:"ask,omitempty"`
	// Why is, on failed, what went wrong in one line (claude-fleet#2696): the
	// create's own failure, no answer in openingGiveUp, or no admin node.
	Why string `json:"why,omitempty"`
	// Stage is, on opening, what is awaited (claude-fleet#2941): create (the
	// node opening the login) or fleet (the login opened, its fleet not yet
	// reported).
	Stage string `json:"stage,omitempty"`
}

// accountStateOf is pid's AccountState, nil when they hold an active login
// a session can open on — one the hub opened counts once its fleet has
// reported (claude-fleet#2941) — or pid is the operator, "".
func (s *Server) accountStateOf(pid string, now time.Time) *AccountState {
	if pid == "" || s.Store == nil || !s.Fleet {
		return nil
	}
	ask := strings.Join(s.FleetAdmins, ", ")
	accts, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil
	}
	// A drill person's own computer (claude-fleet#2549) is the bare login
	// `fleet drill invite` named: it is where the client runs, never where a
	// session can open, so it counts for nothing here.
	drill, _ := s.Store.Drill(pid)
	own := func(a store.FleetAccount) bool {
		// for a drill, any computer it signed in on (#2212) is no machine either
		return drill.OwnComputer(a) || (drill != nil && !a.Managed())
	}
	if !hasMachine(accts, own) && (s.autoAssignOn() || s.invitedPrincipal(pid)) {
		// Nothing queued yet — least-busy found no fit machine at the
		// sign-in, or the setting came on after it: the same idempotent
		// placement the sign-in runs, once more, so the client's next look
		// reads opening instead of waiting for an operator.
		if _, mapped := s.mappedLoginFor(pid); !mapped {
			s.placePrincipal(pid, "", pid)
			if accts, err = s.Store.FleetAccounts(pid); err != nil {
				return nil
			}
		}
	}
	var opening, failed, settling *store.FleetAccount
	ownActive := false
	reported := s.loginsWithFleet()
	for i := range accts {
		a := &accts[i]
		if own(*a) {
			ownActive = ownActive || a.State == store.AccountActive
			continue
		}
		if !a.Managed() {
			continue // a computer the person logged in on, not a machine opened for them (#2212)
		}
		switch a.State {
		case store.AccountActive:
			if a.Op != "create" || reported == nil || reported[[2]string{a.Hostname, a.Login}] {
				return nil
			}
			if settling == nil {
				settling = a
			}
		case store.AccountPending, store.AccountCreating, store.AccountUnknown:
			if opening == nil {
				opening = a
			}
		case store.AccountFailed:
			if failed == nil {
				failed = a
			}
		}
	}
	if settling != nil && now.Sub(settling.UpdatedAt) <= openingSettle {
		// Opened, its fleet not yet reported: the nearest to done.
		return &AccountState{State: "opening", EtaS: etaLeft(openingSettleETA, now.Sub(settling.UpdatedAt), openingSettle),
			Machine: settling.Hostname, Login: settling.Login, Ask: ask, Stage: "fleet"}
	}
	if opening != nil {
		if why := s.openingStuck(*opening, now); why != "" {
			// Never 「about 5s」 forever (claude-fleet#2696): an opening
			// nobody can finish is a failure the person can act on.
			return &AccountState{State: "failed", Machine: opening.Hostname, Login: opening.Login, Ask: ask, Why: why}
		}
		took := now.Sub(opening.RequestedAt)
		eta := openingETALeft(s.openingETAFor(opening.Hostname), took)
		return &AccountState{State: "opening", EtaS: eta, Machine: opening.Hostname, Login: opening.Login, Ask: ask, Stage: "create"}
	}
	if settling != nil {
		return &AccountState{State: "failed", Machine: settling.Hostname, Login: settling.Login, Ask: ask,
			Why: s.settleWhy(*settling, now.Sub(settling.UpdatedAt))}
	}
	if failed != nil {
		return &AccountState{State: "failed", Machine: failed.Hostname, Login: failed.Login, Ask: ask,
			Why: truncate(lastLine(failed.Detail), 200)}
	}
	if ownActive {
		// No other machine to open one on: the drill's own login is all it
		// has — the answer before #2549, when it may well host its fleet.
		return nil
	}
	return &AccountState{State: "none", Ask: ask}
}

// hasMachine says accts holds a row that is a machine for the person: any
// account but the ones own() names (a drill's own computer). An account in
// any state counts — one being opened or removed is not a reason to queue
// another.
func hasMachine(accts []store.FleetAccount, own func(store.FleetAccount) bool) bool {
	for _, a := range accts {
		if !own(a) {
			return true
		}
	}
	return false
}

// openingStuck says why a create still pending / creating / unknown will not
// finish on its own (claude-fleet#2696), "" while it still may: unsent for
// openingNoAdmin with no admin node of its machine connected to run it, or no
// answer at all in openingGiveUp.
func (s *Server) openingStuck(a store.FleetAccount, now time.Time) string {
	took := now.Sub(a.RequestedAt)
	if took > openingGiveUp {
		return fmt.Sprintf("no answer from %s in %d min (%s)", a.Hostname, int(openingGiveUp.Minutes()), a.State)
	}
	if est := s.openingETAFor(a.Hostname); took > openingOver(est) {
		// Far past what this machine takes (claude-fleet#2941).
		return fmt.Sprintf("no answer from %s in %d min — it usually takes about %d min (%s)",
			a.Hostname, int(took.Minutes()), (est+59)/60, a.State)
	}
	if a.State == store.AccountPending && took > openingNoAdmin {
		if _, ok := s.nodes.adminFor(a.Hostname); !ok {
			return "no admin node of " + a.Hostname + " is connected to open it"
		}
	}
	return ""
}

// openingETAFor is how many seconds opening a login on host takes: the median
// of the last few it opened (Store.RecentCreates), openingETA when it has
// opened none yet. Clamped to [60 s, openingGiveUp].
func (s *Server) openingETAFor(host string) int {
	recent, err := s.Store.RecentCreates(host, 7)
	if err != nil || len(recent) == 0 {
		return openingETA
	}
	took := make([]int, 0, len(recent))
	for _, a := range recent {
		if d := int(a.UpdatedAt.Sub(a.RequestedAt).Seconds()); d >= 0 {
			took = append(took, d)
		}
	}
	if len(took) == 0 {
		return openingETA
	}
	sort.Ints(took)
	eta := took[len(took)/2]
	if eta < 60 {
		eta = 60
	}
	if max := int(openingGiveUp.Seconds()); eta > max {
		eta = max
	}
	return eta
}

// openingETALeft is the seconds left of an opening expected to take est
// seconds (≤ openingGiveUp) that has run for took: est × (giveUp − took) ÷
// giveUp, at least 5. It starts at est and only goes down, reaching the floor
// as the doors give up and say failed. Before claude-fleet#2728 it was est −
// took and, past it, the time left until the give-up — a number that jumped UP
// (the drill read 「about 313s」, then 「about 858s」). Its give-up is the
// create's own (openingOver, claude-fleet#2941): it reaches the floor when
// the doors say failed.
func openingETALeft(est int, took time.Duration) int {
	return etaLeft(est, took, openingOver(est))
}

// openingOver is how long a create expected to take est seconds may run
// before it reads failed: 3 × est, clamped to [openingOverFloor,
// openingGiveUp].
func openingOver(est int) time.Duration {
	d := 3 * time.Duration(est) * time.Second
	if d < openingOverFloor {
		d = openingOverFloor
	}
	if d > openingGiveUp {
		d = openingGiveUp
	}
	return d
}

// etaLeft is openingETALeft against any give-up: est × (giveUp − took) ÷
// giveUp, at least 5 — a countdown that only goes down.
func etaLeft(est int, took, giveUpAfter time.Duration) int {
	giveUp := giveUpAfter.Seconds()
	if max := int(giveUp); est > max {
		est = max
	}
	left := giveUp - took.Seconds()
	if left < 0 {
		left = 0
	}
	eta := int(float64(est) * left / giveUp)
	if eta < 5 {
		eta = 5
	}
	return eta
}

// lastLine is s's last non-empty line.
func lastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, " \t\r\n"), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// loginsWithFleet is every (machine, login) a fleet was ever registered under
// — present or not: a login whose fleet reported once has come up, and a
// fleet stopped since is placement's to say. nil when the registry cannot be
// read (then nothing is held back).
func (s *Server) loginsWithFleet() map[[2]string]bool {
	rows, err := s.Store.Fleets()
	if err != nil {
		return nil
	}
	out := map[[2]string]bool{}
	for _, r := range rows {
		out[[2]string{r.Hostname, r.OSUser}] = true
	}
	return out
}

// settleWhy is why an opened login a has no fleet after took: its node never
// connected, or what its last beat says (claude-fleet#2941).
func (s *Server) settleWhy(a store.FleetAccount, took time.Duration) string {
	head := fmt.Sprintf("login %s on %s was opened %d min ago, but ", a.Login, a.Hostname, int(took.Minutes()))
	nodes, err := s.Store.Nodes()
	if err != nil {
		return head + "its fleet has not reported"
	}
	var last *store.Node
	for i := range nodes {
		n := &nodes[i]
		if n.Hostname != a.Hostname || n.OSUser != a.Login {
			continue
		}
		if last == nil || (n.LastHeartbeat != nil && (last.LastHeartbeat == nil || n.LastHeartbeat.After(*last.LastHeartbeat))) {
			last = n
		}
	}
	if last == nil {
		return head + "its own node never connected (join code not redeemed, or its agent did not start)"
	}
	if last.LastHeartbeat == nil {
		return head + "its node said hello and sent no heartbeat"
	}
	var hb control.Heartbeat
	_ = json.Unmarshal([]byte(last.StatusJSON), &hb)
	switch {
	case hb.FleetError != "":
		return head + "its node cannot read its fleet: " + truncate(hb.FleetError, 160)
	case hb.MachineID == "":
		return head + "its node reports no claude-fleet (no machine_id)"
	case len(hb.Fleets) == 0:
		return head + "its node reports no fleet running"
	}
	return head + "its node reports a fleet the hub did not register (see the hub log)"
}

// openingNotes is, for each machine (lower-cased) where pid has a login the
// hub is opening or has opened with no fleet registered yet, what a refused
// placement says about it (claude-fleet#2941): 「正在为你开登录 X」 or 「登录 X
// 已开好，它的 fleet 还没报上来」. Nil for the operator ("").
func (s *Server) openingNotes(pid string) map[string]string {
	if pid == "" || s.Store == nil {
		return nil
	}
	accts, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil
	}
	var reported map[[2]string]bool
	out := map[string]string{}
	for _, a := range accts {
		if !a.Managed() {
			continue
		}
		host := strings.ToLower(a.Hostname)
		switch a.State {
		case store.AccountPending, store.AccountCreating, store.AccountUnknown:
			out[host] = "正在为你开登录 " + a.Login + "（" + a.State + "）"
		case store.AccountActive:
			if a.Op != "create" {
				continue
			}
			if reported == nil {
				if reported = s.loginsWithFleet(); reported == nil {
					return out
				}
			}
			if !reported[[2]string{a.Hostname, a.Login}] {
				out[host] = "登录 " + a.Login + " 已开好，它的 fleet 还没报上来"
			}
		}
	}
	return out
}