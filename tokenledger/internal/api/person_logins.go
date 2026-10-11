package api

import (
	"sort"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A person is not one login (claude-fleet#3302): the same GitHub person can
// hold `verky` on two machines and `verkyyi` on a third. The admin pages and
// `fleet hub accounts` used to show one name for a person — the hub_users
// row's machine_login — which hid the real mapping. PersonLogin is one
// (machine, login) pair a person holds, read from the account rows as they
// are (no schema of its own), with the two things a reader needs to tell
// the pairs apart: which one is the person's home (家, fleet_entry_home) and
// whether the machine is a service node or a client device.

// PersonLogin is one machine·login pair of a person's.
type PersonLogin struct {
	Hostname string `json:"hostname"`
	Login    string `json:"login"`
	State    string `json:"state"`
	// Home marks the pair the person's home (家) points at.
	Home bool `json:"home,omitempty"`
	// Kind is "node" for a service node (a machine that hosts sessions for
	// the fleet), "client" for a person's own computer or a device the hub
	// has no hosting record of.
	Kind string `json:"kind"`
}

// Machine kinds of a PersonLogin.
const (
	loginKindNode   = "node"
	loginKindClient = "client"
)

// personLogins groups accounts by principal into each person's pairs: the
// home first, then service nodes before clients, then by machine. Spare
// logins are nobody's and are left out.
func (s *Server) personLogins(accounts []store.FleetAccount) map[string][]PersonLogin {
	homes := map[string]store.EntryHome{}
	if hs, err := s.Store.EntryHomes(); err == nil {
		for _, h := range hs {
			homes[h.Person] = h
		}
	}
	return buildPersonLogins(accounts, homes, s.hostingMachines())
}

// buildPersonLogins is personLogins without the store, for the tests.
func buildPersonLogins(accounts []store.FleetAccount, homes map[string]store.EntryHome, hosts []string) map[string][]PersonLogin {
	isNode := func(hostname string) bool {
		for _, h := range hosts {
			if sameMachine(h, hostname) || sameMachine(hostname, h) {
				return true
			}
		}
		return false
	}
	out := map[string][]PersonLogin{}
	for _, a := range accounts {
		if store.IsSparePrincipal(a.PrincipalID) {
			continue
		}
		pl := PersonLogin{Hostname: a.Hostname, Login: a.Login, State: a.State, Kind: loginKindClient}
		if isNode(a.Hostname) {
			pl.Kind = loginKindNode
		}
		if h, ok := homes[a.PrincipalID]; ok && (sameMachine(a.Hostname, h.Machine) || sameMachine(h.Machine, a.Hostname)) &&
			(h.Login == "" || h.Login == a.Login) {
			pl.Home = true
		}
		out[a.PrincipalID] = append(out[a.PrincipalID], pl)
	}
	for _, ls := range out {
		sort.SliceStable(ls, func(i, j int) bool {
			a, b := ls[i], ls[j]
			if a.Home != b.Home {
				return a.Home
			}
			if a.Kind != b.Kind {
				return a.Kind == loginKindNode
			}
			if a.Hostname != b.Hostname {
				return a.Hostname < b.Hostname
			}
			return a.Login < b.Login
		})
	}
	return out
}
