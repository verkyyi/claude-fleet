package api

import (
	"strings"
	"time"

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

// openingETA is the client's "about how long" for a login being opened: a
// create is one useradd + the fleet's own install, about a minute.
const openingETA = 60

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
}

// accountStateOf is pid's AccountState, nil when they hold an active login
// (or pid is the operator, "").
func (s *Server) accountStateOf(pid string, now time.Time) *AccountState {
	if pid == "" || s.Store == nil || !s.Fleet {
		return nil
	}
	ask := strings.Join(s.FleetAdmins, ", ")
	accts, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil
	}
	if len(accts) == 0 && (s.autoAssignOn() || s.invitedPrincipal(pid)) {
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
	var opening, failed *store.FleetAccount
	for i := range accts {
		a := &accts[i]
		if !a.Managed() {
			continue // a computer the person logged in on, not a machine opened for them (#2212)
		}
		switch a.State {
		case store.AccountActive:
			return nil
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
	if opening != nil {
		eta := openingETA - int(now.Sub(opening.RequestedAt).Seconds())
		if eta < 5 {
			eta = 5
		}
		return &AccountState{State: "opening", EtaS: eta, Machine: opening.Hostname, Login: opening.Login, Ask: ask}
	}
	if failed != nil {
		return &AccountState{State: "failed", Machine: failed.Hostname, Login: failed.Login, Ask: ask}
	}
	return &AccountState{State: "none", Ask: ask}
}
