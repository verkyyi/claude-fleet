package api

import (
	"errors"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Spare logins (claude-fleet#2263, EPIC #2259 C4): every host machine keeps
// fleet.spare_accounts logins opened ahead of time, so a newcomer's first
// sign-in is handed one that already exists — ready in the time a database
// write takes, instead of 「正在为你开机器，约 60 秒」.
//
//   - Refill rides the admin node's heartbeat (the same beat that sends queued
//     account ops): at most once per spareScanEvery, every fit machine short of
//     its count gets one more spare queued. Fit is the placement's own word —
//     online (not 维护中, not lost), hosts sessions, an admin node connected,
//     not a person's own computer or a SPOT node, load per core and free
//     memory inside the placement thresholds, and the machine's own admit gate
//     open. A machine with a failed spare gets no more until the operator
//     forgets it: a create that fails once would fail on every beat.
//   - Claim is placePrincipal's first move for a person the hub has never
//     recorded: a machine of theirs holding a ready spare hands it over
//     (store.ClaimSpare — record-only, nothing sent). No ready spare, or a
//     person already recorded: the create runs as before, and the doors say
//     「正在开」 with its ETA exactly as they did.
//   - A spare runs no session and holds no subscription: it is a login with
//     the fleet installed and nothing started. It is nobody in every people,
//     budget and usage view (store.Principals leaves it out).
//
// fleet.spare_accounts defaults to 0: the first spare on a real machine is a
// macOS user made on it, and the operator turns this on once they have said
// yes to that (EPIC #2259 共同约定 6). 0 ⇒ nothing is created, nothing claimed,
// and every answer is byte for byte what it was.

// SpareAccountsKey is how many spare logins each host machine keeps.
const SpareAccountsKey = "fleet.spare_accounts"

// maxSpareAccounts bounds fleet.spare_accounts: a spare is a macOS user, and a
// handful per machine is already more than a team onboards in ten minutes.
const maxSpareAccounts = 3

// spareScanEvery is how often a beat may run the refill scan. A variable so
// tests can move it.
var spareScanEvery = 30 * time.Second

// spareTarget is fleet.spare_accounts, 0 when unset or unreadable.
func (s *Server) spareTarget() int {
	n, err := strconv.Atoi(strings.TrimSpace(s.setting(SpareAccountsKey)))
	if err != nil || n < 0 {
		return 0
	}
	if n > maxSpareAccounts {
		return maxSpareAccounts
	}
	return n
}

func checkSpareAccounts(_ *Server, v string) (string, string) {
	v = strings.TrimSpace(v)
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > maxSpareAccounts {
		return "", SpareAccountsKey + " is an integer 0–" + strconv.Itoa(maxSpareAccounts) + " (0 = off)"
	}
	return strconv.Itoa(n), ""
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
			m.Sessions == nil || !admin[h] || paused[h] {
			continue
		}
		if m.NCPU > 0 && m.Load1/float64(m.NCPU) > maxLoadPerCore {
			continue
		}
		if m.MemTotal > 0 && float64(m.MemFree) < memFloor(m.MemTotal) {
			continue
		}
		out = append(out, m.Hostname)
	}
	return out
}

// spareCounts is, per machine (lower-cased), how many spares it holds in
// any state but removed, how many of them are ready (active), and whether
// one failed.
func (s *Server) spareCounts() (held, ready map[string]int, failed map[string]bool, err error) {
	rows, err := s.Store.SpareAccounts()
	if err != nil {
		return nil, nil, nil, err
	}
	held, ready, failed = map[string]int{}, map[string]int{}, map[string]bool{}
	for _, a := range rows {
		h := strings.ToLower(a.Hostname)
		switch a.State {
		case store.AccountRemoved:
			continue
		case store.AccountActive:
			ready[h]++
		case store.AccountFailed:
			failed[h] = true
		}
		held[h]++
	}
	return held, ready, failed, nil
}

// replenishSpares queues a spare on every fit machine short of
// fleet.spare_accounts. force skips the scan throttle (right after a claim).
// It reports whether anything was queued; the caller dispatches.
func (s *Server) replenishSpares(now time.Time, force bool) bool {
	if !s.Fleet || s.Store == nil {
		return false
	}
	target := s.spareTarget()
	if target == 0 {
		return false
	}
	s.spareMu.Lock()
	defer s.spareMu.Unlock()
	if !force && !s.spareScanAt.IsZero() && now.Sub(s.spareScanAt) < spareScanEvery {
		return false
	}
	s.spareScanAt = now
	held, _, failed, err := s.spareCounts()
	if err != nil {
		log.Printf("fleet: spares: %v", err)
		return false
	}
	queued := false
	for _, host := range s.spareFitMachines(now) {
		h := strings.ToLower(host)
		if failed[h] {
			continue // the operator looks at why first (fleet hub accounts)
		}
		for n := held[h]; n < target; n++ {
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

// claimSpare hands principal a ready spare on one of hosts, when the hub
// has never recorded them. It returns the machine it claimed on, "" for none.
func (s *Server) claimSpare(principal, displayName, actor string, hosts []string, now time.Time) string {
	if s.spareTarget() == 0 || store.IsSparePrincipal(principal) || s.Store.IsDrill(principal) {
		return ""
	}
	if _, err := s.Store.Principal(principal); !errors.Is(err, store.ErrNoPrincipal) {
		return "" // recorded already: their login is theirs, opened the usual way
	}
	for _, host := range hosts {
		a, err := s.Store.ClaimSpare(host, principal, s.spareDisplayName(principal, displayName), actor, now)
		if errors.Is(err, store.ErrNoSpare) {
			continue
		}
		if err != nil {
			log.Printf("fleet: claim a spare on %s for %s: %v", host, principal, err)
			return ""
		}
		log.Printf("fleet: first sign-in of %s: handed spare login %s on %s", principal, a.Login, host)
		go func() {
			if s.replenishSpares(time.Now(), true) {
				s.dispatchAccounts()
			}
		}()
		return host
	}
	return ""
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
// holds — for leastBusyMachine's preference and the operator's roster.
func (s *Server) spareReadyHosts() map[string]int {
	if s.spareTarget() == 0 {
		return nil
	}
	_, ready, _, err := s.spareCounts()
	if err != nil {
		log.Printf("fleet: spares: %v", err)
		return nil
	}
	return ready
}

// stampSpares writes each machine's ready spare count onto the operator's
// roster (machines[].spare) while spares are on; absent otherwise.
func (s *Server) stampSpares(snap *NodesSnapshot) {
	ready := s.spareReadyHosts()
	if ready == nil {
		return
	}
	for i := range snap.Machines {
		n := ready[strings.ToLower(snap.Machines[i].Hostname)]
		snap.Machines[i].Spare = &n
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
