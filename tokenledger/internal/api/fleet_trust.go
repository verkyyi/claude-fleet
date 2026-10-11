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
	if settings[NodeTrustMigratedKey] != "" && settings[NodeTrustMachinesMigratedKey] != "" {
		return settings, nil
	}
	if settings[NodeTrustMigratedKey] == "" {
		if err := s.trustMigrate(settings, now); err != nil {
			return nil, err
		}
		if settings, err = s.Store.FleetSettings(); err != nil {
			return nil, err
		}
	}
	if settings[NodeTrustMachinesMigratedKey] == "" {
		if err := s.trustMigrateMachines(settings, now); err != nil {
			return nil, err
		}
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
	return s.setTrustAs("operator", machine, value, now)
}

// setTrustAs is setTrust with the audit row's actor named.
func (s *Server) setTrustAs(actor, machine, value string, now time.Time) (was string, err error) {
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
	s.trustAudit(actor, machine, was+" → "+to, now)
	return was, nil
}

// trustAudit is one fleet_audit row per change: actor, node_trust,
// machine:<name>, the outcome.
func (s *Server) trustAudit(actor, machine, outcome string, at time.Time) {
	s.leaseAudit(actor, "node_trust", "machine:"+strings.ToLower(firstLabel(machine)), outcome, at)
}

// Trust is the MACHINE's, never a login's (claude-fleet#3300, after #2214).
//
// Every login and endpoint on a machine holds the machine's trust: the
// operator's `fleet.node_trust.<machine>`. The machine an endpoint is on is
// the one it ENROLLED as (endpoints.enrolled_host — a login's join code pins
// the machine the hub opened it on), never the hostname it reports now, so an
// endpoint cannot borrow a trusted machine's trust by reporting its name
// (#2214). A borrowed name reads untrusted, source name_borrowed, and the
// hello writes an audit row. An endpoint's own trust record (the join code's
// trust, the old desired-state write) is no longer read: trustMigrateMachines
// moved it onto its machine once, and a trusted join code or a desired-state
// trust write now writes the machine's setting.
const (
	// TrustSourceMachine: the machine's setting, the machine being the one
	// the endpoint enrolled as.
	TrustSourceMachine = "machine"
	// TrustSourceNameBorrowed: the reported name is trusted, but this
	// endpoint enrolled as another machine — it inherits nothing.
	TrustSourceNameBorrowed = "name_borrowed"
	// NodeTrustMachinesMigratedKey stamps trustMigrateMachines.
	NodeTrustMachinesMigratedKey = "fleet.node_trust_machines_migrated"
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

// enrolledMachine is the machine an endpoint is on: the name it enrolled as;
// "" when it enrolled naming none ("?").
func enrolledMachine(et store.EndpointTrust) string {
	if et.EnrolledHost == "?" {
		return ""
	}
	return et.EnrolledHost
}

// nodeTrust is one endpoint's trust and where it came from: its machine's.
// host is the name the endpoint reports now — it only decides whether a
// refusal is a borrowed name.
func nodeTrust(host string, et store.EndpointTrust, settings map[string]string) (trust, source string) {
	machine := enrolledMachine(et)
	if machine != "" && !nameUntrusted(machine, settings) && trustOf(machine, settings) == TrustTrusted {
		return TrustTrusted, TrustSourceMachine
	}
	if host != "" && !sameName(machine, host) && !nameUntrusted(host, settings) && trustOf(host, settings) == TrustTrusted {
		return TrustUntrusted, TrustSourceNameBorrowed
	}
	if machine != "" && nameUntrusted(machine, settings) {
		return TrustUntrusted, TrustSourceMachine
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
// login registering a new node under a name; a login opened on a machine).
func (s *Server) machineTrusted(machine string, settings map[string]string) bool {
	return machine != "" && !nameUntrusted(machine, settings) && trustOf(machine, settings) == TrustTrusted
}

// trustMachine puts a word on the machine an endpoint enrolled as: trusted |
// untrusted | "" (drop the key). force is the operator's own write (the
// desired-state PUT) and replaces whatever the machine held; without it (a
// trusted join code) the word only adds trust, never overriding the
// operator's explicit untrusted. Returns the machine ("" when the endpoint
// enrolled naming none — nothing is written).
func (s *Server) trustMachine(endpointID, value, actor string, force bool, now time.Time) (string, error) {
	et, err := s.Store.EndpointTrustOf(endpointID)
	if err != nil {
		return "", err
	}
	machine := enrolledMachine(et)
	if machine == "" {
		return "", nil
	}
	settings, err := s.trustSettings(now)
	if err != nil {
		return "", err
	}
	if !force && (value != TrustTrusted || nameUntrusted(machine, settings) || trustOf(machine, settings) == TrustTrusted) {
		return machine, nil
	}
	if _, err := s.setTrustAs(actor, machine, value, now); err != nil {
		return "", err
	}
	return machine, nil
}

// trustMigrateMachines moves every live endpoint's own trust onto its machine,
// once (claude-fleet#3300): a machine with no key and an endpoint the operator
// marked untrusted gets untrusted — the operator's untrusted wins over a
// sibling's trusted, as it did per name before; else one with a trusted
// endpoint gets trusted. A machine that already has a key keeps it. An
// endpoint that enrolled naming no machine has none to move to: logged.
func (s *Server) trustMigrateMachines(settings map[string]string, now time.Time) error {
	trusts, _, err := s.Store.EndpointTrusts()
	if err != nil {
		return err
	}
	want := map[string]string{}
	for id, et := range trusts {
		if et.Trust != TrustTrusted && et.Trust != TrustUntrusted {
			continue
		}
		machine := strings.ToLower(firstLabel(enrolledMachine(et)))
		if machine == "" {
			log.Printf("fleet: node trust — endpoint %s held %s but enrolled naming no machine; not moved", id, et.Trust)
			continue
		}
		if want[machine] == TrustUntrusted {
			continue
		}
		if et.Trust == TrustUntrusted && et.Source != store.TrustSourceOperator {
			continue
		}
		want[machine] = et.Trust
	}
	for machine, v := range want {
		if trustOf(machine, settings) == TrustTrusted || nameUntrusted(machine, settings) {
			continue
		}
		if err := s.Store.SetFleetSetting(trustKey(machine), v, now); err != nil {
			return err
		}
		s.trustAudit("migration", machine, v+" (moved from its endpoints)", now)
	}
	if len(want) > 0 {
		log.Printf("fleet: node trust — endpoint trust moved onto %d machine(s)", len(want))
	}
	return s.Store.SetFleetSetting(NodeTrustMachinesMigratedKey, now.UTC().Format(time.RFC3339), now)
}

// untrustedWhy is the refusal text for an endpoint that holds no trust.
func untrustedWhy(host, source string) string {
	name := strings.ToLower(firstLabel(host))
	if source == TrustSourceNameBorrowed {
		return name + " is a trusted machine, but this node did not join as it — a borrowed machine name inherits no trust"
	}
	return name + " is not a trusted machine — the operator marks it with fleet-node-trust.sh set " + name + " trusted"
}

// trustWord drops the source for a one-word audit field.
func trustWord(trust, _ string) string { return trust }
