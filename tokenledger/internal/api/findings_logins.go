package api

import (
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/findings"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The account_login inputs (claude-fleet#1469, EPIC #1665 C2): where the hub
// learns that an account can no longer be renewed, folded into one
// findings.LoginState per (provider, account).
//
// Two feeders, two halves of the fleet's credentials:
//
//   - a machine's collector reports its Codex profile's login health on every
//     status push (model.CollectorStatus.Login — computed on the node by
//     internal/codex.LoginHealth, the same reading `ccquota codex list`
//     prints). reauth_required there means that machine's copy of the
//     credential is dead and the agent has given up on it.
//   - a vault credential the hub itself refreshes carries refresh_error when
//     the token endpoint refused (store.Credential.RefreshError). Only once
//     the access token it was meant to replace has run out does that count:
//     a refused refresh with hours of access left is the agent's retry, not
//     the operator's problem.
//
// Both say "a person has to sign in" — and name the one command that does.

// loginHorizon bounds which collector reports can raise account_login: a
// profile not observed for this long belongs to a machine that is gone (a
// retired login, a wiped home), not to an account that is broken.
const loginHorizon = 7 * 24 * time.Hour

// reauthCommand is the one line that fixes a dead credential, per provider —
// the operator's words (EPIC #1665): Codex re-authenticates with the device
// flow, Claude mints a setup token to import again.
var reauthCommand = map[string]string{
	model.SourceCodex: "codex login --device-auth",
	credvault.Claude:  "claude setup-token",
}

// loginStates folds collector reports and vault refresh errors into the
// account_login inputs. accts and eps are the rosters GatherNow already
// holds; creds may be nil on a hub with no vault.
func (s *Server) loginStates(accts []store.Account, eps []store.Endpoint, creds []store.Credential, now time.Time) []findings.LoginState {
	label := map[string]string{}
	for _, a := range accts {
		label[a.AccountUUID] = a.Label()
	}
	machine := map[string]string{}
	for _, e := range eps {
		name := e.Label
		if name == "" {
			name = e.Hostname
		}
		machine[e.ID] = name
	}
	type key struct{ provider, account string }
	states := map[key]*findings.LoginState{}
	var order []key
	note := func(k key, where, reason string) {
		st, ok := states[k]
		if !ok {
			st = &findings.LoginState{Provider: k.provider, Account: k.account, State: "reauth_required", Command: reauthCommand[k.provider]}
			states[k] = st
			order = append(order, k)
		}
		if where != "" {
			st.Where = appendWhere(st.Where, where)
		}
		if st.Reason == "" {
			st.Reason = reason
		}
	}
	// Collector reports. Every source, filtered on the Login field: only the
	// Codex collector fills it today, and a second one that starts to needs
	// no change here.
	if cs, err := s.Store.Collectors(store.AllAccounts, ""); err == nil {
		for _, c := range cs {
			if c.Login == nil || c.Login.State != "reauth_required" {
				continue
			}
			if !c.ObservedAt.IsZero() && now.Sub(c.ObservedAt) > loginHorizon {
				continue
			}
			acct := label[c.AccountUUID]
			if acct == "" {
				acct = firstNonEmpty(c.ProfileName, c.ProfileID, c.AccountUUID)
			}
			where := firstNonEmpty(machine[c.EndpointID], c.EndpointID)
			if p := firstNonEmpty(c.ProfileName, c.ProfileID); p != "" {
				where += ":" + p
			}
			note(key{c.Source, acct}, where, c.Login.Reason)
		}
	}
	// Vault credentials the hub could not refresh, once the access they
	// backed has run out. A setup token is never refreshed (it expires, and
	// setupTokens says so); a token kind has nothing to refresh either.
	for _, c := range creds {
		if c.RefreshError == "" || c.Kind == credvault.KindSetupToken {
			continue
		}
		if c.AccessExpiresAt != nil && c.AccessExpiresAt.After(now) {
			continue
		}
		who := c.PrincipalID
		if who == "" {
			who = "pool"
		}
		note(key{c.Provider, c.Account}, "hub · "+who, "refresh failed: "+c.RefreshError)
	}
	out := make([]findings.LoginState, 0, len(order))
	for _, k := range order {
		out = append(out, *states[k])
	}
	return out
}

// appendWhere adds one location to a sorted, comma-joined list, once.
func appendWhere(list, where string) string {
	parts := []string{}
	if list != "" {
		parts = strings.Split(list, ", ")
	}
	for _, p := range parts {
		if p == where {
			return list
		}
	}
	parts = append(parts, where)
	sort.Strings(parts)
	return strings.Join(parts, ", ")
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}
