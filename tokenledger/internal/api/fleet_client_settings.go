package api

import (
	"net/http"
	"regexp"
	"sort"
	"strings"
)

// The client's team defaults (claude-fleet#1722, EPIC #1718 C4): settings the
// operator writes once on the hub — `fleet.client_defaults.<KEY>` through
// PUT /v1/fleet/settings — and every colleague's client picks up on its next
// start (bin/fleet-client-update.sh), into ~/.config/claude-fleet/hub-defaults.conf,
// which is read FIRST: hub-defaults < fleet.conf (and the files it replaced),
// so a key this computer wrote always wins and the hub only fills the gaps.
//
// Never a credential (EPIC #1718 共同约定 2): only the keys below are settable,
// a value is one short line of plain characters, and anything shaped like a
// token is refused at PUT — so the GET can be public like /version and /install,
// which a client without a certificate yet already reads.

// ClientDefaultsPrefix is the fleet-settings prefix of a client default.
const ClientDefaultsPrefix = "fleet.client_defaults."

// clientDefaultKeys is the whitelist: what the client (fleet-shell.sh and the
// pieces it starts) reads, none of it a secret, none of it an address.
var clientDefaultKeys = map[string]bool{
	"FLEET_UI_LANG":                    true,
	"FLEET_NODE_ALIASES":               true,
	"FLEET_SHELL_PREFIX":               true,
	"FLEET_SHELL_WIDTH":                true,
	"FLEET_SIDEBAR_WIDTH_MAX":          true,
	"FLEET_SHELL_WARM":                 true,
	"FLEET_SHELL_WARM_MAX":             true,
	"FLEET_SHELL_WARM_EVERY":           true,
	"FLEET_HUB_SESSIONS_EVERY":         true,
	"FLEET_HUB_SESSIONS_WATCHED_EVERY": true,
	"FLEET_HUB_SESSIONS_STALE":         true,
	"FLEET_HUB_NODE_TIMEOUT":           true,
	"FLEET_CLIENT_AUTO_UPDATE":         true,
	"FLEET_CLIENT_CHECK_SECS":          true,
}

// clientDefaultValueRE: one line of plain characters — what a shell file can
// carry single-quoted with no escaping, and what the client re-checks.
var clientDefaultValueRE = regexp.MustCompile(`^[A-Za-z0-9 ._:=,@/+%-]{0,200}$`)

// secretShapeRE: a value that looks like a credential — a known token prefix
// at a word's start, an AWS key id, or a long unbroken run of token characters.
var secretShapeRE = regexp.MustCompile(`(?:^|[^A-Za-z0-9])(?:sk-|ghp_|gho_|ghs_|ghu_|github_pat_|xox[abprs]-|glpat-)|AKIA[0-9A-Z]{16}|[A-Za-z0-9+/_=-]{32,}`)

// clientDefaultCheck validates a PUT of fleet.client_defaults.<KEY>; "" = ok.
func clientDefaultCheck(key, value string) string {
	name := strings.TrimPrefix(key, ClientDefaultsPrefix)
	if !clientDefaultKeys[name] {
		return "client default " + name + " is not settable; the keys are " + strings.Join(clientDefaultKeyList(), ", ")
	}
	if !clientDefaultValueRE.MatchString(value) {
		return "a client default is one line of at most 200 letters, digits, spaces and ._:=,@/+%-"
	}
	if secretShapeRE.MatchString(value) {
		return "a client default never carries a credential — this value looks like one"
	}
	return ""
}

func clientDefaultKeyList() []string {
	keys := make([]string, 0, len(clientDefaultKeys))
	for k := range clientDefaultKeys {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// clientDefaults reads the whitelisted defaults out of the fleet settings.
// A stored row that no longer passes (a key dropped from the whitelist) is
// left out, never served.
func clientDefaults(settings map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range settings {
		if !strings.HasPrefix(k, ClientDefaultsPrefix) || clientDefaultCheck(k, v) != "" {
			continue
		}
		out[strings.TrimPrefix(k, ClientDefaultsPrefix)] = v
	}
	return out
}

// handleClientSettings serves GET /v1/fleet/client-settings: {"settings":
// {KEY: value}, "keys": [the whitelist]}. Public, like /version.
func (s *Server) handleClientSettings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"settings": clientDefaults(settings),
		"keys":     clientDefaultKeyList(),
		"pool":     s.poolSettings(),
	})
}

// poolSettings is the subscription pool's two hub settings (claude-fleet#1986)
// in the names a node's fleet.conf gives them — pool.skip_pct as
// FLEET_ACCOUNT_CEILING, pool.move_when_full as FLEET_FAILOVER — so a node
// can take the admin's value from here. What applies, defaults included.
func (s *Server) poolSettings() map[string]string {
	failover := "0"
	if s.settingOn(PoolMoveFullKey) {
		failover = "1"
	}
	return map[string]string{
		"FLEET_ACCOUNT_CEILING": s.setting(PoolSkipPctKey),
		"FLEET_FAILOVER":        failover,
	}
}
