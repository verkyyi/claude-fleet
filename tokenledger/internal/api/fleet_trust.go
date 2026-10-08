package api

import (
	"log"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 可信 / 不可信 — which machines the hub hands subscription credentials to
// (claude-fleet#1968, EPIC #1967 C1).
//
// A login that once signed in could lease the whole account pool from any
// computer, and nothing on the hub said which computers deserved it. Trust is
// that word, and like 维护中 it is the operator's, never the machine's:
//
//   - stored as the fleet setting `fleet.node_trust.<machine>` = trusted |
//     untrusted (the same table, key shape and machine match as
//     fleet.node_maintenance.<machine>), written ONLY through the operator's
//     PUT /v1/fleet/settings (bin/fleet-node-trust.sh) — a node has no route
//     that sets it, for itself or anyone;
//   - no key = untrusted: a machine that joins later, and a client that only
//     holds a connection certificate, lease nothing until the operator says so;
//   - the one migration (trustMigrate) marks every machine that had an ACTIVE
//     fleet account when this shipped as trusted, once, and stamps
//     fleet.node_trust_migrated — so m4 / m5 lease exactly what they leased
//     before (TestTrustOffAddsNothing);
//   - read by POST /v1/node/credentials after the principal and revocation
//     checks: untrusted → 403 untrusted_node + a fleet_cred_audit deny row;
//     and surfaced as `trust` on the roster and /v1/node/self, which the
//     machine's own proxy reads to pick its road (C3).

const (
	// NodeTrustPrefix names the per-machine trust setting.
	NodeTrustPrefix = "fleet.node_trust."
	// NodeTrustMigratedKey stamps the one migration (the time it ran).
	NodeTrustMigratedKey = "fleet.node_trust_migrated"

	TrustTrusted   = "trusted"
	TrustUntrusted = "untrusted"

	// LeaseUntrusted: the operator has not marked this machine trusted.
	LeaseUntrusted = "untrusted_node"
)

// trustOf is hostname's trust from the settings: trusted only when a key that
// names the machine says so; anything else — no key, a stray value — is
// untrusted. A machine is matched like a maintenance flag (sameMachine: the
// whole name or its first label).
func trustOf(hostname string, settings map[string]string) string {
	if hostname == "" {
		return TrustUntrusted
	}
	for k, v := range settings {
		if !strings.HasPrefix(k, NodeTrustPrefix) {
			continue
		}
		name := k[len(NodeTrustPrefix):]
		if (sameMachine(hostname, name) || strings.EqualFold(hostname, name)) && v == TrustTrusted {
			return TrustTrusted
		}
	}
	return TrustUntrusted
}

// trustKey is the setting key for a machine name as given.
func trustKey(machine string) string {
	return NodeTrustPrefix + strings.ToLower(firstLabel(machine))
}

// trustSettings is the fleet settings with the trust migration applied: the
// first read after the hub starts runs it (a no-op once stamped), so no
// reader ever judges a machine before the machines that were already
// trusted have been written down.
func (s *Server) trustSettings(now time.Time) (map[string]string, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	if settings[NodeTrustMigratedKey] != "" {
		return settings, nil
	}
	if err := s.trustMigrate(settings, now); err != nil {
		return nil, err
	}
	return s.Store.FleetSettings()
}

// trustMigrate writes trusted for every machine with an active fleet account
// that has no trust key yet, then stamps the migration. Runs once per hub
// database: after the stamp, a machine with no key stays untrusted.
func (s *Server) trustMigrate(settings map[string]string, now time.Time) error {
	accts, err := s.Store.FleetAccountsInState(store.AccountActive)
	if err != nil {
		return err
	}
	done := map[string]bool{}
	for _, a := range accts {
		key := trustKey(a.Hostname)
		if a.Hostname == "" || done[key] || !a.Managed() {
			continue
		}
		done[key] = true
		if _, set := settings[key]; set {
			continue
		}
		if err := s.Store.SetFleetSetting(key, TrustTrusted, now); err != nil {
			return err
		}
		s.trustAudit("migration", a.Hostname, TrustTrusted, now)
	}
	if len(done) > 0 {
		log.Printf("fleet: node trust — %d machine(s) with an active account marked trusted", len(done))
	}
	return s.Store.SetFleetSetting(NodeTrustMigratedKey, now.UTC().Format(time.RFC3339), now)
}

// setTrust is the operator's write: trusted | untrusted (or "" to drop the
// key, which reads untrusted). Every spelling of the machine is cleared first
// so "m5.local" and "m5" cannot disagree.
func (s *Server) setTrust(machine, value string, now time.Time) (was string, err error) {
	settings, err := s.trustSettings(now)
	if err != nil {
		return "", err
	}
	was = trustOf(machine, settings)
	for k, v := range settings {
		if strings.HasPrefix(k, NodeTrustPrefix) && v != "" &&
			(sameMachine(machine, k[len(NodeTrustPrefix):]) || sameMachine(k[len(NodeTrustPrefix):], machine)) {
			if err := s.Store.SetFleetSetting(k, "", now); err != nil {
				return was, err
			}
		}
	}
	if value != "" {
		if err := s.Store.SetFleetSetting(trustKey(machine), value, now); err != nil {
			return was, err
		}
	}
	to := value
	if to == "" {
		to = TrustUntrusted + " (cleared)"
	}
	s.trustAudit("operator", machine, was+" → "+to, now)
	return was, nil
}

// trustAudit is one fleet_audit row per change: actor, node_trust,
// machine:<name>, the outcome.
func (s *Server) trustAudit(actor, machine, outcome string, at time.Time) {
	s.leaseAudit(actor, "node_trust", "machine:"+strings.ToLower(firstLabel(machine)), outcome, at)
}

// Trust rides the endpoint, not the name (claude-fleet#2214, EPIC #2329 C2).
//
// endpoints.hostname is the agent's own report, so a trust keyed only by it
// let an untrusted endpoint inherit a trusted machine's trust by reporting
// that machine's name. The answer for an endpoint is now, in order:
//
//  1. the operator named the machine untrusted → untrusted (their word only
//     ever takes trust away);
//  2. the endpoint's own trust — from the join code that enrolled it, or the
//     operator's desired-state write — whatever name it reports;
//  3. compat-1v: the old name rule (fleet.node_trust.<machine>), but only
//     while the endpoint reports the name it ENROLLED under
//     (endpoints.enrolled_host); a borrowed name reads untrusted, source
//     name_borrowed, and the hello writes an audit row.
const (
	// TrustSourceMachineName: the old name-keyed setting, on the endpoint
	// that enrolled under that name. # compat-1v: 下一批删
	TrustSourceMachineName = "machine_name"
	// TrustSourceNameBorrowed: the reported name is trusted, but this
	// endpoint enrolled under another — it inherits nothing.
	TrustSourceNameBorrowed = "name_borrowed"
)

// sameName is "these two spellings name one machine": first labels, any case.
func sameName(a, b string) bool {
	return a != "" && b != "" && strings.EqualFold(firstLabel(a), firstLabel(b))
}

// nameUntrusted is the operator's explicit untrusted for hostname.
func nameUntrusted(hostname string, settings map[string]string) bool {
	if hostname == "" {
		return false
	}
	for k, v := range settings {
		if strings.HasPrefix(k, NodeTrustPrefix) && v == TrustUntrusted && sameName(hostname, k[len(NodeTrustPrefix):]) {
			return true
		}
	}
	return false
}

// nodeTrust is one endpoint's trust and where it came from. host is the name
// the endpoint reports now; et its own record.
func nodeTrust(host string, et store.EndpointTrust, settings map[string]string) (trust, source string) {
	if nameUntrusted(host, settings) {
		return TrustUntrusted, store.TrustSourceOperator
	}
	switch et.Trust {
	case TrustTrusted, TrustUntrusted:
		return et.Trust, et.Source
	}
	if trustOf(host, settings) == TrustTrusted {
		if sameName(et.EnrolledHost, host) {
			return TrustTrusted, TrustSourceMachineName
		}
		return TrustUntrusted, TrustSourceNameBorrowed
	}
	return TrustUntrusted, ""
}

// endpointTrust reads one endpoint's record and judges it. An unreadable
// record is untrusted — never the name's word alone.
func (s *Server) endpointTrust(endpointID, host string, settings map[string]string) (trust, source string) {
	et, err := s.Store.EndpointTrustOf(endpointID)
	if err != nil {
		return TrustUntrusted, ""
	}
	return nodeTrust(host, et, settings)
}

// machineTrusted is "is the machine called this trusted" — for the checks
// that hold a name, not an endpoint (a relay credential is the machine's; a
// login registering a new node under a name): the operator's name setting, or
// a live endpoint that holds trust of its own and reports this name.
func (s *Server) machineTrusted(machine string, settings map[string]string) bool {
	if machine == "" || nameUntrusted(machine, settings) {
		return false
	}
	if trustOf(machine, settings) == TrustTrusted {
		return true
	}
	trusts, hosts, err := s.Store.EndpointTrusts()
	if err != nil {
		return false
	}
	for id, et := range trusts {
		if et.Trust == TrustTrusted && sameName(hosts[id], machine) {
			return true
		}
	}
	return false
}

// untrustedWhy is the refusal text for an endpoint that holds no trust.
func untrustedWhy(host, source string) string {
	name := strings.ToLower(firstLabel(host))
	if source == TrustSourceNameBorrowed {
		return name + " is a trusted machine, but this node did not join as it — a borrowed machine name inherits no trust; join it with a trusted join code"
	}
	return name + " is not a trusted machine — the operator marks it with fleet-node-trust.sh set " + name + " trusted, or joins it with a trusted join code"
}

// trustWord drops the source for a one-word audit field.
func trustWord(trust, _ string) string { return trust }
