package api

import (
	"strings"
)

// One login takes new sessions on a machine (claude-fleet#2430).
//
// A person may hold two logins on one machine — m5's verkyyi (the old admin
// account) and verky (the ordinary account #2210 moved them to) — each with a
// fleet registered under them. Placement scores logins, so which one a new
// session lands in was the luck of the room each reported (verky 38, verkyyi
// 9). While a migration runs the operator may want ONE: the setting
//
//	fleet.node_login.<machine> = <login>
//
// leaves every other login on that machine out of placement — auto and named
// alike, as 维护中 is — and out of a start named straight at its fleet. A
// resume (worker_resume) of a session already there is never refused: the
// session lives where it lives. "" (or no key) = every login, as before.

// NodeLoginPrefix names the per-machine accepting-login setting.
const NodeLoginPrefix = "fleet.node_login."

// excludedOtherLogin opens the verdict on a login the setting leaves out. Not
// a fullness word: every candidate out this way is NO_ELIGIBLE_NODE, never
// AT_CAPACITY (excludedForFullness).
const excludedOtherLogin = "not the machine's accepting login"

// nodeLoginOf is the one login hostname accepts new sessions under, ok false
// when the setting names none. The key's machine name matches as a placement
// target does (sameMachine).
func nodeLoginOf(hostname string, settings map[string]string) (string, bool) {
	for k, v := range settings {
		if !strings.HasPrefix(k, NodeLoginPrefix) || strings.TrimSpace(v) == "" {
			continue
		}
		name := k[len(NodeLoginPrefix):]
		if sameMachine(hostname, name) || strings.EqualFold(hostname, name) {
			return strings.TrimSpace(v), true
		}
	}
	return "", false
}

// otherLoginExcluded is the verdict for osUser on hostname: "" when it may
// take a new session there.
func otherLoginExcluded(hostname, osUser string, settings map[string]string) string {
	if only, ok := nodeLoginOf(hostname, settings); ok && osUser != only {
		return excludedOtherLogin + " (" + only + ")"
	}
	return ""
}
