package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Spare logins (claude-fleet#2263, EPIC #2259 C4): every host machine keeps
// logins opened ahead of time, so a newcomer's first sign-in is handed one
// that already exists — ready in the time a database write takes, instead of
// 「正在为你开机器，约 60 秒」.
//
//   - How many: per machine (or cluster — a place is one hostname on the
//     roster, whatever stands behind it), the machine's own desired state
//     spare_accounts when the operator wrote one, else fleet.spare_max
//     (default 1, at most 2 — claude-fleet#4673; either way never above
//     spareMaxCeiling) — and never more than
//     fleet.node_user_cap.<machine> (default 10) − the logins already handed
//     out there. A spare runs no session and holds no subscription; measured
//     on mac-b (2026-10-08, idle fleet logins zx / vincent / erin) one costs
//     about 9 processes, 60–75 MB resident and 0.25–0.9 GB of disk.
//   - Refill rides the admin node's heartbeat (at most once per
//     spareScanEvery), and only on a fit machine: online (not 维护中, not
//     lost), hosts sessions, not a person's own computer,
//     CPU (cpu_busy first, else load per core) and free memory inside the
//     placement thresholds — and an admin node that opens logins
//     credential-separated (control.CapCredsep, claude-fleet#2294). Never the
//     logins' own admit / room: that is the gate for a new SESSION, and a
//     spare runs none — waiting on it left a busy machine with no spare
//     exactly when the next person most needs one (claude-fleet#4076). A machine
//     with a failed spare gets no more until the operator forgets it.
//   - Shrink needs no fitness: a machine holding more than its count (the cap
//     lowered, logins handed out) closes the newest ready spares and drops the
//     ones that never reached it. 维护中 / under pressure ⇒ only shrinks.
//   - Claim is the first move of placePrincipal and of the operator's
//     assign, for anyone with no login on that machine yet: a ready spare
//     there becomes theirs — the hub records 「this person → that login」,
//     nothing is renamed and nothing is sent. A person never recorded takes
//     the spare's principal row (store.ClaimSpare, their login is fleetu<N>
//     from then on); one already recorded takes only its account row, so
//     their login there is the spare's fleetu<N> while it stays their own
//     name elsewhere (store.ClaimSpareFor, claude-fleet#3501) — which is why
//     every 「person → login on a machine」 reads fleet_accounts. Ready means
//     its create came back credential-separated, so there is no window in
//     which the newcomer can read a token. No ready spare, or the operator's
//     assign with own_name: their own login is opened as before, and the
//     doors say 「正在开」 with its ETA.
//   - Ready is checked, not inferred (claude-fleet#4673, BREAK-IT
//     spare-ready-unverified): the open or wash ends with bin/fleet-login-ready.sh
//     on the machine — a session credential from the machine's proxy, the
//     login's home up, a first reply — and the hub keeps the time each step
//     passed (store.AccountCheck, keyed by the op). A spare is handed only while
//     its op passed all three (store.ClaimSpare's spareCheckedSQL); one that did
//     not is held, never ready, its why on the roster and the account list.
//     One with no check at all (opened before the check existed) is washed once
//     — or removed where the machine cannot recycle — so the next answer checks
//     it; a create whose check failed is washed once more, a wash whose check
//     failed is left for the operator. A pod is its cluster's (destroyed whole,
//     never washed) and is never judged here. (Before this the hub guessed:
//     「not seen live 10 minutes after its open」 — and still handed out spares
//     with no home, no proxy tenancy or no subscription, 2026-10-14.)
//   - A spare is nobody in every people, budget and usage view
//     (store.Principals leaves it out).
//
// fleet.spares defaults to off: a spare is a macOS user made on a real
// machine, and the operator turns this on once they have said yes to that
// (EPIC #2259 共同约定 6). Off ⇒ nothing is created, nothing claimed, and
// every answer is byte for byte what it was.

// The spare settings' keys.
const (
	SparesKey         = "fleet.spares"
	SpareMaxKey       = "fleet.spare_max"
	NodeUserCapPrefix = "fleet.node_user_cap."
)

// defaultNodeUserCap is a machine's login cap when fleet.node_user_cap.<machine>
// is unset.
const (
	defaultSpareMax    = 1
	defaultNodeUserCap = 10
)

// spareMaxCeiling bounds fleet.spare_max and every place's count: at most two
// a machine (claude-fleet#4673). A variable so tests that seat several people
// on one machine can move it.
var spareMaxCeiling = 2

// spareScanEvery is how often a beat may run the refill scan. A variable so
// tests can move it.
var spareScanEvery = 30 * time.Second

func checkSpareMax(_ *Server, v string) (string, string) {
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < 0 || n > spareMaxCeiling {
		return "", SpareMaxKey + " is an integer 0–" + strconv.Itoa(spareMaxCeiling) + ", or \"\" for the default (" + strconv.Itoa(defaultSpareMax) + ")"
	}
	return strconv.Itoa(n), ""
}

// sparesOn is fleet.spares.
func (s *Server) sparesOn() bool { return s.settingOn(SparesKey) }

// spareMax is fleet.spare_max.
func (s *Server) spareMax() int {
	n, err := strconv.Atoi(strings.TrimSpace(s.setting(SpareMaxKey)))
	if err != nil || n < 0 {
		return defaultSpareMax
	}
	if n > spareMaxCeiling {
		return spareMaxCeiling
	}
	return n
}

// nodeUserCap is how many logins hostname may hold: fleet.node_user_cap.<it>,
// else defaultNodeUserCap.
func nodeUserCap(hostname string, settings map[string]string) int {
	for k, v := range settings {
		if strings.HasPrefix(k, NodeUserCapPrefix) && sameMachine(hostname, k[len(NodeUserCapPrefix):]) {
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 {
				return n
			}
		}
	}
	return defaultNodeUserCap
}

// spareMachine is one machine's spare picture.
type spareMachine struct {
	Ready     int  // spares handed out at the next sign-in (active)
	Held      int  // spares in any state but closed / on their way out
	Used      int  // logins handed out (anyone's but a spare's, not closed)
	Cap       int  // the machine's login cap
	Target    int  // spares it should hold
	Failed    bool // a spare's create failed
	Resetting int  // spares being washed for the next person (never ready)
	FailedN   int  // spares that failed (never ready)
	Unchecked int  // active spares whose check did not pass (never ready, claude-fleet#4673)
	spares    []store.FleetAccount
	unchecked []store.FleetAccount
	checks    map[string]store.AccountCheck // by op_id
}

func (m *spareMachine) aim(max int) {
	m.Target = m.Cap - m.Used
	if m.Target > max {
		m.Target = max
	}
	if m.Target < 0 {
		m.Target = 0
	}
}

func leaving(state string) bool {
	switch state {
	case store.AccountRemoved, store.AccountRemovePending, store.AccountRemoving:
		return true
	}
	return false
}

// sparePicture is every machine's spare picture, keyed by lower-case name;
// machine (when not "") is in it even with no account at all.
func (s *Server) sparePicture(machines ...string) (map[string]*spareMachine, error) {
	all, err := s.Store.FleetAccounts("")
	if err != nil {
		return nil, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	checks, err := s.Store.AccountChecks()
	if err != nil {
		return nil, err
	}
	out := map[string]*spareMachine{}
	get := func(host string) *spareMachine {
		k := strings.ToLower(host)
		m := out[k]
		if m == nil {
			m = &spareMachine{Cap: nodeUserCap(host, settings), checks: checks}
			out[k] = m
		}
		return m
	}
	for _, h := range machines {
		get(h)
	}
	for _, a := range all {
		if !a.Managed() {
			continue
		}
		m := get(a.Hostname)
		if !store.IsSparePrincipal(a.PrincipalID) {
			if !leaving(a.State) {
				m.Used++
			}
			continue
		}
		m.spares = append(m.spares, a)
		if leaving(a.State) {
			continue
		}
		switch {
		case a.State == store.AccountActive && !s.spareChecked(a, checks):
			m.Unchecked++
			m.unchecked = append(m.unchecked, a)
		case a.State == store.AccountActive:
			m.Ready++
		case a.State == store.AccountFailed:
			m.Failed = true
			m.FailedN++
		case a.State == store.AccountResetPending, a.State == store.AccountResetting:
			m.Resetting++
		}
		m.Held++
	}
	max := s.spareMax()
	desired := s.desiredSpares()
	for k, m := range out {
		if n, ok := desired[k]; ok {
			m.aim(n)
		} else {
			m.aim(max)
		}
	}
	return out, nil
}

// desiredSpares is, per machine (lower-cased), the spare_accounts its desired
// state names (claude-fleet#3501), at most spareMaxCeiling — the one
// per-machine source, ahead of fleet.spare_max. A machine whose desired state never wrote the key is not
// in it; 0 written is 0. Several endpoints of one machine: the newest write.
func (s *Server) desiredSpares() map[string]int {
	nodes, err := s.Store.Nodes()
	if err != nil {
		log.Printf("fleet: spares: roster: %v", err)
		return nil
	}
	out, at := map[string]int{}, map[string]time.Time{}
	for _, n := range nodes {
		d, err := s.Store.DesiredOf(n.EndpointID)
		if err != nil || d.Version == 0 {
			continue
		}
		var body struct {
			Spares *int `json:"spare_accounts"`
		}
		if json.Unmarshal([]byte(d.Body), &body) != nil || body.Spares == nil {
			continue
		}
		k := strings.ToLower(n.Hostname)
		if prev, ok := at[k]; ok && !d.UpdatedAt.After(prev) {
			continue
		}
		v := *body.Spares
		if v < 0 {
			v = 0
		}
		if v > spareMaxCeiling {
			v = spareMaxCeiling // a machine keeps at most two (claude-fleet#4673)
		}
		out[k], at[k] = v, d.UpdatedAt
	}
	return out
}

// spareFitMachines is every machine a spare may be opened on right now.
func (s *Server) spareFitMachines(now time.Time) []string { return s.spareMachines(now, true) }

// spareMachines is every machine that keeps spares: online (not 维护中, not
// lost), hosting sessions, not a person's own computer or one person's
// pod, its admin node up and opening logins credential-separated.
// fit adds what a refill needs right now: CPU (cpuVerdict — cpu_busy first)
// and free memory inside the placement thresholds. It never reads a login's
// admit / room (claude-fleet#4076): those hold new sessions, not a login.
func (s *Server) spareMachines(now time.Time, fit bool) []string {
	snap, err := s.Nodes(now)
	if err != nil {
		log.Printf("fleet: spares: roster: %v", err)
		return nil
	}
	admin := map[string]bool{}
	for _, n := range snap.Nodes {
		if n.Admin && n.Connected && n.Status == "online" {
			admin[strings.ToLower(n.Hostname)] = true
		}
	}
	var out []string
	for _, m := range snap.Machines {
		h := strings.ToLower(m.Hostname)
		if m.Status != "online" || m.ComputeOff || m.Personal ||
			m.Sessions == nil || !admin[h] || !s.nodes.credsepAdminFor(m.Hostname) ||
			isUserPodName(m.Hostname) { // one person's pod holds one login (claude-fleet#3553)
			continue
		}
		if !fit {
			out = append(out, m.Hostname)
			continue
		}
		var lpc *float64
		if m.NCPU > 0 {
			l := m.Load1 / float64(m.NCPU)
			lpc = &l
		}
		if out, _ := cpuVerdict(m.CPUBusy, m.MaxCPUBusy, lpc); out != "" {
			continue
		}
		if m.MemTotal > 0 && float64(m.MemFree) < memFloor(m.MemTotal) {
			continue
		}
		out = append(out, m.Hostname)
	}
	return out
}

// replenishSpares brings every machine to its spare count: it queues spares
// on fit machines short of it, and closes or drops spares on any machine
// over it. force skips the scan throttle (right after a claim). It reports
// whether anything was queued; the caller dispatches.
func (s *Server) replenishSpares(now time.Time, force bool) bool {
	if !s.Fleet || s.Store == nil || !s.sparesOn() {
		return false
	}
	s.spareMu.Lock()
	defer s.spareMu.Unlock()
	if !force && !s.spareScanAt.IsZero() && now.Sub(s.spareScanAt) < spareScanEvery {
		return false
	}
	s.spareScanAt = now
	fit := s.spareFitMachines(now)
	pic, err := s.sparePicture(fit...)
	if err != nil {
		log.Printf("fleet: spares: %v", err)
		return false
	}
	queued := s.replenishClusterSpares(now)
	for _, m := range pic {
		queued = s.shrinkSpares(m, now) || queued
	}
	for _, host := range fit {
		m := pic[strings.ToLower(host)]
		// only where the machine is up to answer the wash (claude-fleet#4673)
		queued = s.healUncheckedSpares(m, now) || queued
		if m.Failed {
			continue // the operator looks at why first (fleet hub accounts)
		}
		for n := m.Held; n < m.Target; n++ {
			a, err := s.Store.CreateSpare(host, control.ValidLogin, now)
			if err != nil {
				log.Printf("fleet: spares: queue one on %s: %v", host, err)
				break
			}
			log.Printf("fleet: spares: queued %s on %s", a.Login, host)
			queued = true
		}
	}
	return queued
}

// shrinkSpares takes m down to its target: spares that never reached the
// machine are dropped, ready ones closed (newest first); a spare with an op
// in flight is left to finish. Closed spares are forgotten. It reports
// whether a removal was queued.
func (s *Server) shrinkSpares(m *spareMachine, now time.Time) bool {
	for _, a := range m.spares {
		if a.State == store.AccountRemoved {
			if err := s.Store.ForgetPrincipal(a.PrincipalID, ""); err != nil {
				log.Printf("fleet: spares: forget %s: %v", a.Login, err)
			}
		}
	}
	over := m.Held - m.Target
	if over <= 0 {
		return false
	}
	live := make([]store.FleetAccount, 0, len(m.spares))
	for _, a := range m.spares {
		if a.State == store.AccountPending || a.State == store.AccountActive {
			live = append(live, a)
		}
	}
	// Never-sent first, then the newest ready.
	sort.SliceStable(live, func(i, j int) bool {
		if pi, pj := live[i].State == store.AccountPending, live[j].State == store.AccountPending; pi != pj {
			return pi
		}
		return live[i].RequestedAt.After(live[j].RequestedAt)
	})
	queued := false
	for _, a := range live {
		if over == 0 {
			break
		}
		var err error
		if a.State == store.AccountPending {
			err = s.Store.ForgetPrincipal(a.PrincipalID, "")
		} else if err = s.Store.RequestAccountRemoval(a.PrincipalID, a.Hostname, now); err == nil {
			queued = true
		}
		if err != nil {
			log.Printf("fleet: spares: shrink %s on %s: %v", a.Login, a.Hostname, err)
			continue
		}
		log.Printf("fleet: spares: %s on %s is one over (%d held, %d wanted) — closing it", a.Login, a.Hostname, m.Held, m.Target)
		over--
	}
	return queued
}

// liveFleetRows is every fleet a home can be made of right now (claude-fleet
// #4234, entryHomeChoices): registered and present, an os user that is no
// fleet admin, its node not lost.
func (s *Server) liveFleetRows(now time.Time) ([]store.FleetRow, map[string]string, error) {
	rows, err := s.Store.Fleets()
	if err != nil {
		return nil, nil, err
	}
	avail := s.nodeAvailability(now)
	var out []store.FleetRow
	for _, r := range rows {
		if !r.Present || r.OSUser == "" || s.isFleetAdmin(r.OSUser) {
			continue
		}
		if a := avail[r.EndpointID]; a == "" || a == "lost" {
			continue
		}
		out = append(out, r)
	}
	return out, avail, nil
}

// spareChecked says a's op passed its check (claude-fleet#4673) — the hub's
// read of what store.ClaimSpare's spareCheckedSQL asks. A pod is its
// cluster's and never checked here: it is ready as active.
func (s *Server) spareChecked(a store.FleetAccount, checks map[string]store.AccountCheck) bool {
	if isUserPodName(a.Hostname) || s.isCluster(a.Hostname) {
		return true
	}
	c, ok := checks[a.OpID]
	return ok && c.Passed()
}

// noCheckWhy is a check row for an answer that carried none: a node older than
// bin/fleet-login-ready.sh (claude-fleet#4673).
const noCheckWhy = "the node ran no check before handing it out (a node older than claude-fleet#4673)"

// recordAccountCheck keeps the check of a create's or a wash's answer, before
// the answer is applied — so a spare is never active without its check. Only
// for the op's own node; an answer that carried none is recorded as such.
func (s *Server) recordAccountCheck(opID, epID string, res control.AccountResult, now time.Time) {
	if !res.OK || (res.Op != control.AccountCreate && res.Op != control.AccountReset) {
		return
	}
	a, err := s.Store.AccountByOp(opID)
	if err != nil || a.EndpointID != epID {
		return // stale or foreign: nothing of it is applied either
	}
	c := store.AccountCheck{OpID: opID, Op: res.Op, CheckedAt: now, Why: noCheckWhy}
	if r := res.Ready; r != nil {
		c.Why = r.Fail
		for _, f := range []struct {
			sec int64
			to  **time.Time
		}{{r.CredOK, &c.CredOK}, {r.HomeOK, &c.HomeOK}, {r.FirstReplyOK, &c.FirstReplyOK}} {
			if f.sec > 0 {
				t := time.Unix(f.sec, 0).UTC()
				*f.to = &t
			}
		}
		if c.Why == "" && c.Steps() < 3 {
			c.Why = fmt.Sprintf("the check passed %d of 3 steps", c.Steps())
		}
	}
	if err := s.Store.RecordAccountCheck(c); err != nil {
		log.Printf("fleet: check of %s on %s (op %s): %v", a.Login, a.Hostname, opID, err)
		return
	}
	if !c.Passed() && store.IsSparePrincipal(a.PrincipalID) {
		log.Printf("fleet: spares: %s on %s did not pass its check (%d/3): %s — not handed out", a.Login, a.Hostname, c.Steps(), c.Why)
		_ = s.Store.HubAudit("hub", "spare.unchecked", a.Login, "held", fmt.Sprintf("%s: %d/3 — %s", a.Hostname, c.Steps(), c.Why), now)
	}
}

// healUncheckedSpares washes m's spares that never had a check (opened before
// it existed) — or removes them where the machine's admin cannot recycle, so
// the refill opens a checked one — and washes once more a create whose check
// failed. A wash whose check failed, or an answer from a node that runs no
// check, is left for the operator (the roster says why). One hub_audit
// spare.recheck line each. It reports whether anything was queued.
func (s *Server) healUncheckedSpares(m *spareMachine, now time.Time) bool {
	queued := false
	for _, a := range m.unchecked {
		c, checked := m.checks[a.OpID]
		_, recycle := s.nodes.recyclerFor(a.Hostname)
		req, how := s.Store.RequestAccountRemoval, "removing it (this machine's admin cannot recycle; the refill opens a checked one)"
		switch {
		case !checked && recycle, checked && c.Op == control.AccountCreate && c.Why != noCheckWhy && recycle:
			req, how = s.Store.RequestAccountReset, "washing it (the wash checks it again)"
		case !checked:
		default:
			continue
		}
		if err := req(a.PrincipalID, a.Hostname, now); err != nil {
			if !errors.Is(err, store.ErrAccountState) {
				log.Printf("fleet: spares: recheck %s on %s: %v", a.Login, a.Hostname, err)
			}
			continue
		}
		why := "never checked"
		if checked {
			why = "its check failed: " + c.Why
		}
		why += " — " + how
		log.Printf("fleet: spares: %s on %s: %s", a.Login, a.Hostname, why)
		_ = s.Store.HubAudit("hub", "spare.recheck", a.Login, "queued", a.Hostname+": "+why, now)
		queued = true
	}
	return queued
}

// isSpareOp says opID was sent for a spare's account.
func (s *Server) isSpareOp(opID string) bool {
	a, err := s.Store.AccountByOp(opID)
	return err == nil && store.IsSparePrincipal(a.PrincipalID)
}

// claimSpareOn hands principal a ready spare on host — whether or not the
// hub has recorded them yet (claude-fleet#3501): a person never recorded
// takes the spare whole (store.ClaimSpare), one already recorded takes its
// account row (store.ClaimSpareFor). A drill identity takes one too
// (claude-fleet#3509, #2947) and gives it back washed when it deletes itself
// (closeDrillLogins → a reset). nil when it handed none: spares off, no ready
// spare there, or a login of theirs already on host.
func (s *Server) claimSpareOn(principal, displayName, actor, host string, now time.Time) *store.FleetAccount {
	if !s.sparesOn() || store.IsSparePrincipal(principal) {
		return nil
	}
	if s.isCluster(host) {
		// A cluster hands a whole pod (claude-fleet#3553) — to a drill
		// identity too: the pod is destroyed whole at its remove, so nothing
		// of the drill is left for the next person.
		return s.claimClusterSpare(principal, displayName, actor, host, now)
	}
	a := s.claimSpareAt(principal, displayName, actor, host, now)
	if a == nil {
		return nil
	}
	go func() {
		if s.replenishSpares(time.Now(), true) {
			s.dispatchAccounts()
		}
	}()
	return a
}

// claimSpareAt is the claim itself: the oldest ready spare login on host,
// whoever principal is. nil when none was handed.
func (s *Server) claimSpareAt(principal, displayName, actor, host string, now time.Time) *store.FleetAccount {
	var a *store.FleetAccount
	var err error
	// Only a checked spare is handed (claude-fleet#4673): the store's claim
	// asks for it — but a pod's, which is its cluster's and never checked.
	checked := !isUserPodName(host) && !s.isCluster(host)
	switch _, perr := s.Store.Principal(principal); {
	case errors.Is(perr, store.ErrNoPrincipal):
		a, err = s.Store.ClaimSpare(host, principal, s.spareDisplayName(principal, displayName), actor, now, checked)
		switch {
		case errors.Is(err, store.ErrRekeyTarget):
			// Recorded between the two reads: the recorded person's road.
			a, err = s.Store.ClaimSpareFor(host, principal, actor, now, checked)
		case errors.Is(err, store.ErrSpareNameHeld):
			// A recycled spare whose name a person's record still holds
			// (claude-fleet#3504): record them under a name of their own,
			// then hand them its login.
			if _, err = s.Store.EnsurePrincipal(principal, s.spareDisplayName(principal, displayName),
				control.MaxLoginLen, control.ValidLogin, now); err == nil {
				a, err = s.Store.ClaimSpareFor(host, principal, actor, now, checked)
			}
		}
	case perr != nil:
		log.Printf("fleet: claim a spare on %s for %s: %v", host, principal, perr)
		return nil
	default:
		a, err = s.Store.ClaimSpareFor(host, principal, actor, now, checked)
	}
	switch {
	case errors.Is(err, store.ErrNoSpare), errors.Is(err, store.ErrAccountState):
		return nil
	case err != nil:
		log.Printf("fleet: claim a spare on %s for %s: %v", host, principal, err)
		return nil
	}
	log.Printf("fleet: %s: handed spare login %s on %s", principal, a.Login, host)
	return a
}

// claimSpares runs claimSpareOn on every one of hosts where principal holds
// no account row at all (a closed one stays closed: reopening it is the
// operator's assign), and returns the hosts it claimed on.
func (s *Server) claimSpares(principal, displayName, actor string, hosts []string, now time.Time) []string {
	if !s.sparesOn() || len(hosts) == 0 {
		return nil
	}
	have := map[string]bool{}
	if as, err := s.Store.FleetAccounts(principal); err == nil {
		for _, a := range as {
			have[strings.ToLower(a.Hostname)] = true
		}
	} else {
		log.Printf("fleet: accounts of %s: %v", principal, err)
		return nil
	}
	var out []string
	for _, host := range hosts {
		if have[strings.ToLower(host)] || (s.isCluster(host) && s.holdsClusterPod(principal, host)) {
			continue
		}
		if s.claimSpareOn(principal, displayName, actor, host, now) != nil {
			out = append(out, host)
		}
	}
	return out
}

// spareDisplayName is the name a claimed spare's principal row takes: the
// one the sign-in carried, else their GitHub username (a door that places
// them carries none), else their id.
func (s *Server) spareDisplayName(principal, displayName string) string {
	if strings.TrimSpace(displayName) != "" {
		return displayName
	}
	if l := s.personLogin(principal); l != "" {
		return l
	}
	return principal
}

// spareReadyHosts is, per machine (lower-cased), how many ready spares it
// holds — leastBusyMachine's preference. nil while spares are off.
func (s *Server) spareReadyHosts() map[string]int {
	if !s.sparesOn() {
		return nil
	}
	pic, err := s.sparePicture()
	if err != nil {
		log.Printf("fleet: spares: %v", err)
		return nil
	}
	out := map[string]int{}
	for k, m := range pic {
		out[k] = m.Ready
	}
	return out
}

// stampSpares writes each machine's 备用 N · 已用 M / 上限 K onto the
// operator's roster while spares are on; absent otherwise.
func (s *Server) stampSpares(snap *NodesSnapshot) {
	if !s.sparesOn() {
		return
	}
	hosts := make([]string, len(snap.Machines))
	for i, m := range snap.Machines {
		hosts[i] = m.Hostname
	}
	pic, err := s.sparePicture(hosts...)
	if err != nil {
		log.Printf("fleet: spares: %v", err)
		return
	}
	for i := range snap.Machines {
		mv := &snap.Machines[i]
		m := pic[strings.ToLower(mv.Hostname)]
		ready, used, cap := m.Ready, m.Used, m.Cap
		mv.Spare, mv.LoginsUsed, mv.LoginCap = &ready, &used, &cap
		resetting, failed, target := m.Resetting, m.FailedN, m.Target
		mv.SpareResetting, mv.SpareFailed, mv.SpareTarget = &resetting, &failed, &target
		unchecked := m.Unchecked
		mv.SpareUnchecked = &unchecked
	}
}

// dropHost is hosts without host (case folded).
func dropHost(hosts []string, host string) []string {
	out := make([]string, 0, len(hosts))
	for _, h := range hosts {
		if !strings.EqualFold(h, host) {
			out = append(out, h)
		}
	}
	return out
}
