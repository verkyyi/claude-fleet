package api

import (
	"encoding/json"
	"errors"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Spare logins (claude-fleet#2263, EPIC #2259 C4): every host machine keeps
// logins opened ahead of time, so a newcomer's first sign-in is handed one
// that already exists — ready in the time a database write takes, instead of
// 「正在为你开机器，约 60 秒」.
//
//   - How many: per machine (or cluster — a place is one hostname on the
//     roster, whatever stands behind it), the machine's own desired state
//     spare_accounts when the operator wrote one, else fleet.spare_max
//     (default 2, claude-fleet#3501) — and never more than
//     fleet.node_user_cap.<machine> (default 10) − the logins already handed
//     out there. A spare runs no session and holds no subscription; measured
//     on m5 (2026-10-08, idle fleet logins zx / vincent / victor) one costs
//     about 9 processes, 60–75 MB resident and 0.25–0.9 GB of disk.
//   - Refill rides the admin node's heartbeat (at most once per
//     spareScanEvery), and only on a fit machine: online (not 维护中, not
//     lost), hosts sessions, not a person's own computer or a SPOT node,
//     load per core and free memory inside the placement thresholds, the
//     machine's own admit gate open — and an admin node that opens logins
//     credential-separated (control.CapCredsep, claude-fleet#2294). A machine
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

// spareMaxCeiling bounds fleet.spare_max; defaultNodeUserCap is a machine's
// login cap when fleet.node_user_cap.<machine> is unset.
const (
	spareMaxCeiling    = 20
	defaultSpareMax    = 2
	defaultNodeUserCap = 10
)

// spareScanEvery is how often a beat may run the refill scan. A variable so
// tests can move it.
var spareScanEvery = 30 * time.Second

func checkSpareMax(_ *Server, v string) (string, string) {
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < 0 || n > spareMaxCeiling {
		return "", SpareMaxKey + " is an integer 0–" + strconv.Itoa(spareMaxCeiling) + ", or \"\" for the default (2)"
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
	spares    []store.FleetAccount
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
	out := map[string]*spareMachine{}
	get := func(host string) *spareMachine {
		k := strings.ToLower(host)
		m := out[k]
		if m == nil {
			m = &spareMachine{Cap: nodeUserCap(host, settings)}
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
		switch a.State {
		case store.AccountActive:
			m.Ready++
		case store.AccountFailed:
			m.Failed = true
			m.FailedN++
		case store.AccountResetPending, store.AccountResetting:
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
// state names (claude-fleet#3501) — the one per-machine source, ahead of
// fleet.spare_max. A machine whose desired state never wrote the key is not
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
		out[k], at[k] = v, d.UpdatedAt
	}
	return out
}

// spareFitMachines is every machine a spare may be opened on right now.
func (s *Server) spareFitMachines(now time.Time) []string {
	snap, err := s.Nodes(now)
	if err != nil {
		log.Printf("fleet: spares: roster: %v", err)
		return nil
	}
	admin, paused := map[string]bool{}, map[string]bool{}
	for _, n := range snap.Nodes {
		h := strings.ToLower(n.Hostname)
		if n.Admin && n.Connected && n.Status == "online" {
			admin[h] = true
		}
		if (n.Admit != nil && !*n.Admit) || (n.Room != nil && *n.Room < 1) {
			paused[h] = true // the machine's own gate holds new sessions
		}
	}
	var out []string
	for _, m := range snap.Machines {
		h := strings.ToLower(m.Hostname)
		if m.Status != "online" || m.ComputeOff || m.Personal || m.Kind == store.NodeKindEphemeral ||
			m.Sessions == nil || !admin[h] || paused[h] || !s.nodes.credsepAdminFor(m.Hostname) {
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
	queued := false
	for _, m := range pic {
		queued = s.shrinkSpares(m, now) || queued
	}
	for _, host := range fit {
		m := pic[strings.ToLower(host)]
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

// isSpareOp says opID was sent for a spare's account.
func (s *Server) isSpareOp(opID string) bool {
	a, err := s.Store.AccountByOp(opID)
	return err == nil && store.IsSparePrincipal(a.PrincipalID)
}

// claimSpareOn hands principal a ready spare on host — whether or not the
// hub has recorded them yet (claude-fleet#3501): a person never recorded
// takes the spare whole (store.ClaimSpare), one already recorded takes its
// account row (store.ClaimSpareFor). nil when it handed none: spares off, a
// drill, no ready spare there, or a login of theirs already on host.
func (s *Server) claimSpareOn(principal, displayName, actor, host string, now time.Time) *store.FleetAccount {
	if !s.sparesOn() || store.IsSparePrincipal(principal) || s.Store.IsDrill(principal) {
		return nil
	}
	var a *store.FleetAccount
	var err error
	switch _, perr := s.Store.Principal(principal); {
	case errors.Is(perr, store.ErrNoPrincipal):
		a, err = s.Store.ClaimSpare(host, principal, s.spareDisplayName(principal, displayName), actor, now)
		if errors.Is(err, store.ErrRekeyTarget) {
			// Recorded between the two reads: the recorded person's road.
			a, err = s.Store.ClaimSpareFor(host, principal, actor, now)
		}
	case perr != nil:
		log.Printf("fleet: claim a spare on %s for %s: %v", host, principal, perr)
		return nil
	default:
		a, err = s.Store.ClaimSpareFor(host, principal, actor, now)
	}
	switch {
	case errors.Is(err, store.ErrNoSpare), errors.Is(err, store.ErrAccountState):
		return nil
	case err != nil:
		log.Printf("fleet: claim a spare on %s for %s: %v", host, principal, err)
		return nil
	}
	log.Printf("fleet: %s: handed spare login %s on %s", principal, a.Login, host)
	go func() {
		if s.replenishSpares(time.Now(), true) {
			s.dispatchAccounts()
		}
	}()
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
		if have[strings.ToLower(host)] {
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
	if id, ok := githubIDOf(principal); ok {
		if u, err := s.Store.HubUserByID(id); err == nil && u != nil && u.Login != "" {
			return u.Login
		}
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
