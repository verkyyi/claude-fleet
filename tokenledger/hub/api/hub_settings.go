package api

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The hub's settings live in the database (claude-fleet#1986, EPIC #1982 C4):
// an admin changes them on the web or with `fleet hub set <key> <value>`
// (PUT /v1/fleet/settings), they apply on the next request, and every change
// is one hub_audit row (who, when, old → new). The deploy keeps only what a
// running hub cannot change about itself (EPIC #1982 rule 2).
//
// Reading a setting goes through Server.setting(key) and nothing else: the
// stored value, else the default below. A key may still name an old value
// read where the setting is unset, copied into the database once at start
// (MigrateLegacySettings); none does since fleet.spot left with the SPOT
// nodes (claude-fleet#4797).
// --public-badges, CCQUOTA_FLEET_AUTO_ASSIGN and
// CCQUOTA_FLEET_PRINCIPAL_LOGINS are no longer read at all
// (claude-fleet#2087): their copies are in the database since #1986.

// The hub settings' keys.
const (
	PoolSkipPctKey  = "pool.skip_pct"
	AutoAssignKey   = "fleet.auto_assign"
	RoutesExtraKey  = "fleet.routes_extra"
	MachineNamesKey = "fleet.machine_names"
	// SparesKey / SpareMaxKey are fleet_spare.go's (claude-fleet#2263).

	// userSettingPrefix / machineLoginSuffix make user.<id>.machine_login:
	// the OS login that is a person's on the machines. <id> is the principal
	// — gh:<GitHub ID> for a GitHub person (stored on their hub_users row,
	// the one place the scope reads), any other principal otherwise (an old map's entry).
	userSettingPrefix  = "user."
	machineLoginSuffix = ".machine_login"

	// noneValue clears a list or a login on purpose: "" means "back to the
	// default".
	noneValue = "none"
	// leastBusyValue is fleet.auto_assign's "pick for me" (claude-fleet#2069):
	// the online, unflagged host machine with the fewest sessions.
	leastBusyValue = "least-busy"

	// legacyMigratedPrefix marks a key whose old variable has been copied
	// into the database once, so clearing it later is not undone at the
	// next start.
	legacyMigratedPrefix = "hub.legacy_migrated."
)

// hubSetting is one setting: its default, its check, and the old variable
// it replaces.
type hubSetting struct {
	def  string
	help string
	// check returns the stored form of v, or why it is refused.
	check func(s *Server, v string) (string, string)
	// legacy is the old variable's value; "" = it says nothing.
	legacy func(s *Server) string
	// deploy is a default the deploy implies (claude-fleet#3199): used in
	// place of def while nothing is stored, never copied into the database —
	// change the deploy and the default follows. "" = def.
	deploy func(s *Server) string
}

func onOff(key, def string) func(*Server, string) (string, string) {
	return func(_ *Server, v string) (string, string) {
		v = strings.ToLower(strings.TrimSpace(v))
		if v != "on" && v != "off" {
			return "", key + " is on | off, or \"\" for the default (" + def + ")"
		}
		return v, ""
	}
}

// hubSettings is every hub setting but the per-person machine login.
var hubSettings = map[string]hubSetting{
	MeterKey: {def: "on", help: "the public counter (/meter.json)",
		check: onOff(MeterKey, "on")},
	PoolSkipPctKey: {def: "85", help: "a subscription at or above this % of a window is skipped (nodes: FLEET_ACCOUNT_CEILING)",
		check: func(_ *Server, v string) (string, string) {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil || n < 1 || n > 100 {
				return "", PoolSkipPctKey + " is an integer 1–100, or \"\" for the default (85)"
			}
			return strconv.Itoa(n), ""
		}},
	AutoAssignKey: {def: "", help: "machines a new person gets a login opened on: least-busy, names comma-separated, or none",
		check: func(_ *Server, v string) (string, string) {
			if strings.EqualFold(strings.TrimSpace(v), noneValue) {
				return noneValue, ""
			}
			if strings.EqualFold(strings.TrimSpace(v), leastBusyValue) {
				return leastBusyValue, ""
			}
			hosts := splitHosts(v)
			if len(hosts) == 0 {
				return "", AutoAssignKey + " is least-busy, machine names comma-separated, or none"
			}
			for _, h := range hosts {
				if !nodeNameRE.MatchString(h) {
					return "", fmt.Sprintf("%s: %q is not a machine name", AutoAssignKey, h)
				}
			}
			return strings.Join(hosts, ","), ""
		}},
	ReleaseCanaryKey: {def: "", help: "the machine a new stable goes to first (claude-fleet#4915): the rest switch once it is on it with its doctor passing, or after 2 minutes; it rolls back ⇒ nobody else gets it. Empty = everyone at once",
		check: func(_ *Server, v string) (string, string) {
			v = strings.TrimSpace(v)
			if v != "" && !nodeNameRE.MatchString(v) {
				return "", fmt.Sprintf("%s: %q is not a machine name", ReleaseCanaryKey, v)
			}
			return v, ""
		}},
	TermDoorsKey: {def: "", help: "browser terminals through the nearest door (XX79): a JSON list of {id, url (wss://host/v1/door/pipe), endpoint (the door's node endpoint — its token signs the tickets), label}; the browser picks the fastest, else the hub. Empty = no door offered",
		check: termDoorsCheck},
	DoorKey: {def: "", help: "the cluster's one public door (claude-fleet#3549): its machine name(s); a person whose home is their own pod u-<nonce> is reached through it",
		check: doorCheck},
	EntryKey: {def: "off", help: "the direct door: people's keys, address names and homes, pushed to their home machines (default on when the hub writes address records: CCQUOTA_DNS_*)",
		check: onOff(EntryKey, "off"),
		deploy: func(s *Server) string {
			// The DNS credentials are there for the addresses alone: a hub
			// that has them means the door (claude-fleet#3199).
			if s.EntryDNS != nil {
				return "on"
			}
			return ""
		}},
	EntryDomainKey: {def: "", help: "the zone every person's address lives under: <name>.<zone> (cf.example.com; default CCQUOTA_DNS_SUBDOMAIN.CCQUOTA_DNS_DOMAIN)",
		deploy: func(s *Server) string {
			if s.EntryDNS != nil {
				return s.EntryDNS.Zone
			}
			return ""
		},
		check: func(_ *Server, v string) (string, string) {
			v = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(v)), ".")
			if !entryDomainRE.MatchString(v) || len(v) > 200 {
				return "", EntryDomainKey + " is a domain name (cf.example.com), or \"\" for none"
			}
			return v, ""
		}},
	DoorAddressKey: {def: "", help: "the door's one address for everyone (A5SQ): host or host:port (default port 22022) — the phone page's default way in; \"\" = none",
		check: func(_ *Server, v string) (string, string) {
			v = strings.ToLower(strings.TrimSpace(v))
			if v == "" {
				return "", ""
			}
			if _, _, ok := doorAddress(v); !ok {
				return "", DoorAddressKey + " is a host name or address, optionally :port (door.example.com:22022), or \"\" for none"
			}
			return v, ""
		}},
	RoutesExtraKey: {def: "", help: "more ways in, on top of CCQUOTA_FLEET_ROUTES: the same JSON array",
		check: func(_ *Server, v string) (string, string) {
			ms, err := ParseFleetRoutes(v)
			if err != nil {
				return "", strings.Replace(err.Error(), "CCQUOTA_FLEET_ROUTES", RoutesExtraKey, 1)
			}
			if len(ms) == 0 {
				return "", RoutesExtraKey + " is a JSON array of machines, or \"\" for none"
			}
			return strings.TrimSpace(v), ""
		}},
	TrialKey: {def: "off", help: "the trial at /app/try (立即体验): a verified sign-in — WeChat scan, mailed code or GitHub — the list does not name is handed a ready spare login (fleet.spares) within fleet.trial.*, or waits in line (claude-fleet#3590, #4058)",
		check: onOff(TrialKey, "off")},
	TrialSlotsKey: {def: "8", help: "at most this many trials hold a machine at once (claude-fleet#4058)",
		check: checkIntSetting(TrialSlotsKey, 0, 200, defaultTrialSlots)},
	TrialLoadRatioKey: {def: "0.8", help: "no new trial while the machine's load is above this × its cores; the person waits with an ETA (claude-fleet#4058)",
		check: checkTrialLoadRatio},
	TrialQuotaFloorKey: {def: "20", help: "no new trial while the subscription pool has less than this percent of its window left; under 50 the day's total is halved (claude-fleet#4058)",
		check: checkIntSetting(TrialQuotaFloorKey, 0, 100, defaultTrialQuotaFloor)},
	TrialDailyKey: {def: "30", help: "at most this many trials start a day (Beijing time), halved while the pool is under half (claude-fleet#4058)",
		check: checkIntSetting(TrialDailyKey, 0, 10000, defaultTrialDaily)},
	TrialEgressKey: {def: "off", help: "what a trial login may reach (WACK C3): off — anything, as any login; log — anything, and what block would refuse is written to the machine's egress-deny.log; block — only conf/trial-egress.allow, the hub and DNS, mail ports 25/465/587 never. Each machine applies it within a minute (pf anchor fleet-trial); FLEET_TRIAL_EGRESS in a machine's machine.env overrides it there. 试用账号能连到哪：off 不限；log 不拦只记；block 只能连白名单",
		check: checkTrialEgress},
	TrialOnceKey: {def: "on", help: "one trial per account (WeChat by unionid, else openid; an address; a GitHub account): a second one is told it has tried and pointed at /apply (claude-fleet#4058)",
		check: onOff(TrialOnceKey, "on")},
	TrialCredAllowKey: {def: `"*"`, help: "the subscriptions a trial person may use (they are never listed one by one): \"*\" every one the trial is otherwise eligible for (the machine's own list still applies), a JSON list of subscription IDs only those, [] none — trials then wait 「试用暂时没有可用订阅」; approval writes it as the new member's own list (claude-fleet#4260)",
		check: checkTrialCredAllow},
	SpareCredAllowKey: {def: `"*"`, help: "the subscriptions a spare login may use, and only while its own create / reset is in flight (its readiness check's one reply — a spare is minted by the hub and never listed one by one): \"*\" every one it is otherwise eligible for (the machine's own list still applies), a JSON list of subscription IDs only those, [] none — new spares then fail their check; a ready spare and a claimed one get nothing from it (claude-fleet NKTP)",
		check: checkSpareCredAllow},
	TrialMaxSecsKey: {def: "900", help: "a trial's time on a machine, in seconds — whichever of this and fleet.trial.max_msgs comes first ends it and gives the machine back (claude-fleet#4059)",
		check: checkIntSetting(TrialMaxSecsKey, 60, 86400, defaultTrialMaxSecs)},
	TrialMaxMsgsKey: {def: "20", help: "a trial's lines sent — whichever of this and fleet.trial.max_secs comes first ends it (claude-fleet#4059)",
		check: checkIntSetting(TrialMaxMsgsKey, 1, 1000, defaultTrialMaxMsgs)},
	TrialHiddenSecsKey: {def: "120", help: "a trial whose page has sent no heartbeat (closed, or switched away) for this many seconds gives its machine back; the conversation is kept 24 h (claude-fleet#4060)",
		check: checkIntSetting(TrialHiddenSecsKey, 30, 3600, defaultTrialHiddenSecs)},
	TrialIdleWarnKey: {def: "180", help: "a trial with no input for this many seconds is told 「1 分钟后暂停」 (claude-fleet#4060)",
		check: checkIntSetting(TrialIdleWarnKey, 30, 3600, defaultTrialIdleWarnSecs)},
	TrialIdleKey: {def: "240", help: "a trial with no input for this many seconds gives its machine back; the conversation is kept 24 h (claude-fleet#4060)",
		check: checkIntSetting(TrialIdleKey, 60, 7200, defaultTrialIdleSecs)},
	CredPodProvidersKey: {def: credPodProvidersDef, help: "the subscription providers every cluster pod (u-<nonce>, fleet-linux-*) may use, whatever its owner's allowance: comma-separated (codex, claude), or * for no limit (claude-fleet#4601)",
		check: checkCredPodProviders},
	SparesKey: {def: "off", help: "keep spare logins opened on each host machine, so a newcomer's first sign-in is ready at once (each is a macOS user)",
		check: onOff(SparesKey, "off")},
	ClustersKey: {def: "", help: "the clusters that keep spare pods (claude-fleet#3553): each one's name as its fleet-ops reports it, comma-separated; with fleet.spares on and the account key set, a newcomer placed there is handed a ready pod",
		check: checkClusters},
	UserPodRollKey: {def: "on", help: "roll each person's pod onto the cluster's new image once stable moves past its runtime (claude-fleet#4174): a few at a time, never one with a session working or asking",
		check: onOff(UserPodRollKey, "on")},
	ClusterPodRetireKey: {def: "on", help: "retire a cluster pod's machine once its cluster's fleet-ops has not listed the pod (Deployment deleted or scaled to 0) for 30 minutes and none of its logins has been heard from (claude-fleet#4887): actor system, the PVC untouched, the operator told",
		check: onOff(ClusterPodRetireKey, "on")},
	UserPodRollBatchKey: {def: "2", help: "at most this many person pods rolled per batch, a batch every 10 minutes (claude-fleet#4174)",
		check: checkIntSetting(UserPodRollBatchKey, 1, 20, 2)},
	SpareMaxKey: {def: "1", help: "this many spare logins per machine, 0–2 (claude-fleet#4673), within fleet.node_user_cap.<machine> (default 10) minus the logins handed out",
		check: checkSpareMax},
	MachineNamesKey: {def: "", help: "the short name every client shows a machine by: hostname=name, comma-separated (mac-a.local=mac-a, mac-b.local=mac-b)",
		check: func(_ *Server, v string) (string, string) {
			names, err := parseMachineNames(v)
			if err != "" {
				return "", err
			}
			if len(names) == 0 {
				return "", MachineNamesKey + " is hostname=name pairs, comma-separated, or \"\" for none"
			}
			return formatMachineNames(names), ""
		}},
}

// hubSettingKeys is hubSettings' keys, sorted.
func hubSettingKeys() []string {
	keys := make([]string, 0, len(hubSettings))
	for k := range hubSettings {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func splitHosts(v string) []string {
	var out []string
	for _, h := range strings.Split(v, ",") {
		if h = strings.TrimSpace(h); h != "" {
			out = append(out, h)
		}
	}
	return out
}

// isHubSettingKey reports whether key is one of hubSettings, a retired one
// (refused by putHubSetting), a user.<id>.machine_login or a user.<GitHub ID>.lang.
func isHubSettingKey(key string) bool {
	if _, ok := hubSettings[key]; ok || slices.Contains(store.RetiredSettings, key) {
		return true
	}
	if _, ok := langKeyPerson(key); ok {
		return true
	}
	if _, ok := poolPausedKey(key); ok {
		return true
	}
	_, ok := machineLoginKey(key)
	return ok
}

// PoolPausedPrefix makes pool.paused.<account> (claude-fleet#1990): a pool
// subscription an admin paused — "on", or "" (the row is deleted) when it
// runs. <account> is the credential's account as /v1/fleet/credentials
// lists it. The hub still leases it, flagged paused, so a session already
// on it finishes; a node that reads the flag starts no new one there.
const PoolPausedPrefix = "pool.paused."

// poolPausedKey parses pool.paused.<account>.
func poolPausedKey(key string) (string, bool) {
	acct, ok := strings.CutPrefix(key, PoolPausedPrefix)
	if !ok || !validAccountLabel(acct) {
		return "", false
	}
	return acct, true
}

// pausedAccounts is every pool account an admin paused, sorted.
func pausedAccounts(settings map[string]string) []string {
	out := []string{}
	for k, v := range settings {
		if acct, ok := poolPausedKey(k); ok && strings.EqualFold(v, "on") {
			out = append(out, acct)
		}
	}
	sort.Strings(out)
	return out
}

// machineLoginKey parses user.<id>.machine_login. <id> is a GitHub ID — bare
// digits, as C9's user.<id>.lang spells it (claude-fleet#2033), or gh:<id> —
// else any other principal; the principal comes back as gh:<id> for a GitHub one.
func machineLoginKey(key string) (principal string, ok bool) {
	rest, ok := strings.CutPrefix(key, userSettingPrefix)
	if !ok {
		return "", false
	}
	pid, ok := strings.CutSuffix(rest, machineLoginSuffix)
	if !ok || pid == "" || len(pid) > 128 || strings.ContainsAny(pid, " \t\r\n") {
		return "", false
	}
	if n, err := strconv.ParseInt(pid, 10, 64); err == nil && n > 0 {
		pid = githubPrincipal(n)
	}
	return pid, true
}

// langKeyPerson parses user.<GitHub ID>.lang (or user.gh:<id>.lang) and
// user.<person>.lang — the account language C9 reads (pagelang.go's
// langSettingKey) — into the person it is about.
func langKeyPerson(key string) (string, bool) {
	rest, ok := strings.CutPrefix(key, userSettingPrefix)
	if !ok {
		return "", false
	}
	who, ok := strings.CutSuffix(rest, ".lang")
	if !ok {
		return "", false
	}
	if id, err := strconv.ParseInt(who, 10, 64); err == nil && id > 0 {
		who = githubPrincipal(id)
	}
	if !isPerson(who) {
		return "", false
	}
	return who, true
}

func machineLoginSettingKey(principal string) string {
	return userSettingPrefix + principal + machineLoginSuffix
}

// setting is the ONE reading of a hub setting: the stored value, else the
// old value (a key's legacy), else the default. An unreadable table reads
// as the old variable or the default.
func (s *Server) setting(key string) string {
	spec, ok := hubSettings[key]
	def := spec.def
	if ok && spec.deploy != nil {
		if v := spec.deploy(s); v != "" {
			def = v
		}
	}
	if s.Store != nil {
		if settings, err := s.Store.FleetSettings(); err == nil {
			if v := settings[key]; v != "" {
				return v
			}
			if settings[legacyMigratedPrefix+key] != "" {
				// The old value was copied in and since cleared: the
				// default, not the variable.
				return def
			}
		}
	}
	if !ok {
		return ""
	}
	if spec.legacy != nil {
		if v := spec.legacy(s); v != "" {
			return v
		}
	}
	return def
}

func (s *Server) settingOn(key string) bool { return strings.EqualFold(s.setting(key), "on") }

// autoAssign is the machines a new person gets a login queued on:
// fleet.auto_assign's list, or for least-busy the one leastBusyMachine picks
// right now (nil when none is fit — the person is told who to ask).
func (s *Server) autoAssign() []string {
	v := s.setting(AutoAssignKey)
	switch {
	case strings.EqualFold(v, noneValue):
		return nil
	case strings.EqualFold(v, leastBusyValue):
		if h := s.leastBusyMachine(time.Now()); h != "" {
			return []string{h}
		}
		return nil
	}
	return splitHosts(v)
}

// autoAssignOn says fleet.auto_assign would open a login for a new person at
// all — what the client's 「正在为你开」 versus 「请找管理员」 turns on.
func (s *Server) autoAssignOn() bool {
	v := strings.TrimSpace(s.setting(AutoAssignKey))
	return v != "" && !strings.EqualFold(v, noneValue)
}

// routesExtra is fleet.routes_extra, parsed; a stored value that no longer
// parses is logged and left out.
func (s *Server) routesExtra() []FleetMachine {
	v := s.setting(RoutesExtraKey)
	if v == "" {
		return nil
	}
	ms, err := ParseFleetRoutes(v)
	if err != nil {
		log.Printf("fleet routes: %s: %v", RoutesExtraKey, err)
		return nil
	}
	return ms
}

// parseMachineNames reads fleet.machine_names (claude-fleet#1706):
// "mac-e=mac-d, mac-f=mac-c" → {"mac-e": "mac-d", "mac-f": "mac-c"}, keyed by the
// hostname's first label, lower-cased, the way a heartbeat's hostname is
// matched. Both sides go into ssh configs, so both are plain tokens; a name
// two machines would share is refused.
func parseMachineNames(v string) (map[string]string, string) {
	names := map[string]string{}
	taken := map[string]string{}
	for _, pair := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == '\n' || r == ';' }) {
		if pair = strings.TrimSpace(pair); pair == "" {
			continue
		}
		h, a, ok := strings.Cut(pair, "=")
		h, a = strings.ToLower(firstLabel(strings.TrimSpace(h))), strings.TrimSpace(a)
		if !ok || !sshToken(h) || !sshToken(a) {
			return nil, fmt.Sprintf("%s: %q is not hostname=name", MachineNamesKey, pair)
		}
		if _, dup := names[h]; dup {
			return nil, fmt.Sprintf("%s: %s is named twice", MachineNamesKey, h)
		}
		if other, dup := taken[strings.ToLower(a)]; dup {
			return nil, fmt.Sprintf("%s: %s and %s cannot both be %s", MachineNamesKey, other, h, a)
		}
		names[h], taken[strings.ToLower(a)] = a, h
	}
	return names, ""
}

// formatMachineNames is the stored form: "h=a,h=a", sorted by hostname.
func formatMachineNames(names map[string]string) string {
	hs := make([]string, 0, len(names))
	for h := range names {
		hs = append(hs, h)
	}
	sort.Strings(hs)
	for i, h := range hs {
		hs[i] = h + "=" + names[h]
	}
	return strings.Join(hs, ",")
}

// machineNames is fleet.machine_names, parsed; a stored value that no longer
// parses is logged and reads as none.
func (s *Server) machineNames() map[string]string {
	v := s.setting(MachineNamesKey)
	if v == "" {
		return nil
	}
	names, err := parseMachineNames(v)
	if err != "" {
		log.Printf("fleet routes: %s", err)
		return nil
	}
	return names
}

// machineAlias is the short name a machine is shown by: fleet.machine_names,
// else "" (the caller keeps whatever it had).
func machineAlias(hostname string, names map[string]string) string {
	if hostname == "" {
		return ""
	}
	return names[strings.ToLower(firstLabel(hostname))]
}

// staticAliases is every alias the operator wrote down, keyed like
// machineNames: CCQUOTA_FLEET_ROUTES and fleet.routes_extra first, then
// fleet.machine_names over them — fleetMachines' precedence, without the
// node roster read (a caller that has the settings in hand).
func (s *Server) staticAliases(settings map[string]string) map[string]string {
	out := map[string]string{}
	for _, m := range append(append([]FleetMachine(nil), s.FleetRoutes...), s.routesExtra()...) {
		k := strings.ToLower(firstLabel(m.Hostname))
		if m.Alias != "" && out[k] == "" {
			out[k] = m.Alias
		}
	}
	if v := settings[MachineNamesKey]; v != "" {
		if names, err := parseMachineNames(v); err == "" {
			for h, a := range names {
				out[h] = a
			}
		}
	}
	return out
}

// settingMachineLogins is every user.<id>.machine_login stored in the
// settings table (non-GitHub principals; a GitHub person's is on their hub_users
// row), principal → login. "none" entries are kept: they mean "no login".
func (s *Server) settingMachineLogins() map[string]string {
	out := map[string]string{}
	if s.Store == nil {
		return out
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		log.Printf("fleet: read machine logins: %v", err)
		return out
	}
	for k, v := range settings {
		if pid, ok := machineLoginKey(k); ok && v != "" {
			out[strings.ToLower(pid)] = v
		}
	}
	return out
}

// principalLogins is the stored person → machine login map placement reads
// (a GitHub person's own login is on their hub_users row). Nothing else
// names a login: CCQUOTA_FLEET_PRINCIPAL_LOGINS is no longer read
// (claude-fleet#2087). Keys are lower case; "none" is dropped.
func (s *Server) principalLogins() map[string]string {
	out := s.settingMachineLogins()
	for pid, login := range out {
		if login == noneValue {
			delete(out, pid)
		}
	}
	return out
}

// checkMachineLogin validates a user.<id>.machine_login value for pid: an
// existing OS login, not already someone else's.
func (s *Server) checkMachineLogin(pid, v string) (string, string) {
	v = strings.TrimSpace(v)
	if strings.EqualFold(v, noneValue) {
		return noneValue, ""
	}
	if !control.ValidExistingLogin(v) {
		return "", fmt.Sprintf("%q is not a machine login (2-16 lowercase letters and digits, not reserved)", v)
	}
	if who := s.machineLoginOwner(v); who != "" && !strings.EqualFold(who, pid) && !s.legacyHolder(pid, who) {
		// An old identity's map entry (user.<old id>.machine_login, copied in
		// from the enterprise-WeChat era) gives way to a GitHub person: the
		// mapping hands it over (handOverLegacyMap, claude-fleet#2108).
		return "", fmt.Sprintf("machine login %s is already %s's", v, who)
	}
	if s.Store != nil {
		// The hub's own record. An identity from before GitHub sign-in that
		// no map names any more is handed over at placement
		// (claude-fleet#2094); another GitHub person keeps it (an admin the
		// deploy names has no list row to carry a map).
		if p, err := s.Store.PrincipalByLogin(v); err == nil && !strings.EqualFold(p.ID, pid) && !s.legacyHolder(pid, p.ID) {
			return "", fmt.Sprintf("machine login %s is already %s's", v, s.personName(p.ID))
		}
	}
	return v, ""
}

// legacyHolder reports whether a GitHub person pid may take a login over
// from holder: an identity from before GitHub sign-in (an enterprise-WeChat
// id), which takeOverLegacyLogin re-keys to them (claude-fleet#2094). Another
// GitHub person — or a non-GitHub pid — never takes anything over.
func (s *Server) legacyHolder(pid, holder string) bool {
	if !isPerson(pid) || isPerson(holder) {
		return false
	}
	return true
}

// handOverLegacyMap is the mapping of a GitHub person pid to login when an
// identity from before GitHub sign-in still holds it in the settings
// (user.<old id>.machine_login — the enterprise-WeChat map C4 copied in,
// claude-fleet#2108). The old principal row, when it has the login, is
// re-keyed to pid (takeOverLegacyLogin), and RekeyPrincipal drops the map
// entry in that same transaction; an entry with no row behind it is deleted
// here. Each drop is a hub_audit row (actor, the key, old id → pid, login).
// Nothing to hand over ⇒ nil, nil; a refusal changes nothing.
func (s *Server) handOverLegacyMap(actor, pid, displayName, login string, now time.Time) (*store.RekeyResult, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	var key, holder string
	for k, v := range settings {
		if id, ok := machineLoginKey(k); ok && v == login && !strings.EqualFold(id, pid) && s.legacyHolder(pid, id) {
			key, holder = k, id
			break
		}
	}
	if key == "" {
		return nil, nil
	}
	var moved *store.RekeyResult
	if p, err := s.Store.PrincipalByLogin(login); err == nil && strings.EqualFold(p.ID, holder) {
		if moved, err = s.takeOverLegacyLogin(pid, login, displayName, actor, now, true); err != nil {
			return nil, err
		}
	} else if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		return nil, err
	}
	if moved == nil {
		if err := s.Store.SetFleetSetting(key, "", now); err != nil {
			return nil, err
		}
	}
	if err := s.Store.HubAudit(actor, "setting", key, "ok",
		fmt.Sprintf("%s → (default): login %s handed from the old identity %s to %s", login, login, holder, pid), now); err != nil {
		log.Printf("WARN hub settings: audit %s: %v", key, err)
	}
	log.Printf("hub settings: %s cleared — login %s handed from %s to %s (by %s)", key, login, holder, pid, actor)
	return moved, nil
}

// DropLegacyMachineLogins deletes every user.<old id>.machine_login (an
// identity from before GitHub sign-in) that no longer means anything
// (claude-fleet#2108): its login is a GitHub person's — on their hub_users
// row or their principal row — or the old identity holds no login under it
// ("none", a login nobody or someone else holds). An entry whose old
// principal still holds its login, and no GitHub person is mapped to, is
// kept: it is that person's until their GitHub account is mapped
// (handOverLegacyMap). Each drop is a hub_audit row by "deploy". Run at
// every start; once the entries are gone it does nothing.
func (s *Server) DropLegacyMachineLogins(now time.Time) error {
	if s.Store == nil {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	ghMapped := map[string]string{}
	if users, err := s.Store.HubUsers(); err != nil {
		return err
	} else {
		for _, u := range users {
			if u.MachineLogin != "" {
				ghMapped[u.MachineLogin] = u.PrincipalID
			}
		}
	}
	keys := make([]string, 0, len(settings))
	for k := range settings {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		pid, ok := machineLoginKey(k)
		if !ok {
			continue
		}
		if isPerson(pid) {
			continue
		}
		login := settings[k]
		why := ""
		switch p, err := s.Store.PrincipalByLogin(login); {
		case ghMapped[login] != "":
			why = "login " + login + " is " + ghMapped[login] + "'s"
		case err == nil:
			if isPerson(p.ID) {
				why = "login " + login + " is " + p.ID + "'s"
			} else if !strings.EqualFold(p.ID, pid) {
				why = "login " + login + " is " + p.ID + "'s, not " + pid + "'s"
			}
		case errors.Is(err, store.ErrNoPrincipal):
			why = "no account holds login " + login
		default:
			return err
		}
		if why == "" {
			continue
		}
		if err := s.Store.SetFleetSetting(k, "", now); err != nil {
			return err
		}
		if err := s.Store.HubAudit("deploy", "setting", k, "ok", login+" → (default): old identity, "+why, now); err != nil {
			log.Printf("WARN hub settings: audit %s: %v", k, err)
		}
		log.Printf("hub settings: dropped %s=%s (old identity, %s)", k, login, why)
	}
	return nil
}

// machineLoginOwner is the principal a machine login belongs to, "" when
// nobody's: a GitHub person's row or a stored setting.
func (s *Server) machineLoginOwner(login string) string {
	for pid, l := range s.principalLogins() {
		if l == login {
			return pid
		}
	}
	if s.Store != nil {
		if users, err := s.Store.HubUsers(); err == nil {
			for _, u := range users {
				if u.MachineLogin == login {
					return u.PrincipalID
				}
			}
		}
	}
	return ""
}

// actorOf names who made a change, for the audit: the signed-in person, the
// viewer the shared door was used as, else "operator".
func actorOf(r *http.Request) string {
	if pid := principalOf(r.Context()); pid != "" {
		if sess := sessionOf(r.Context()); sess != nil && sess.Name != "" {
			return sess.Name + " (" + pid + ")"
		}
		return pid
	}
	if v := viewerOf(r.Context()); v != "" {
		return v
	}
	return "operator"
}

// settingAudit records one setting change. old and new are the stored
// values ("" = unset).
func (s *Server) settingAudit(actor, key, old, new string, at time.Time) {
	if old == new {
		return
	}
	show := func(v string) string {
		if v == "" {
			return "(default)"
		}
		if len(v) > 300 {
			return v[:300] + "…"
		}
		return v
	}
	if err := s.Store.HubAudit(actor, "setting", key, "ok", show(old)+" → "+show(new), at); err != nil {
		log.Printf("hub audit: setting %s: %v", key, err)
	}
}

// putHubSetting validates and stores one hub setting, auditing the change.
// Returns the HTTP status and, on a refusal, why.
func (s *Server) putHubSetting(actor, key, value string, now time.Time) (int, string) {
	if slices.Contains(store.RetiredSettings, key) {
		// An older console's switch (claude-fleet T543): refused, never a
		// silent 200 that changes nothing.
		return http.StatusBadRequest, key + " 已不用：池子按请求挑订阅，满了自然换下一个，没有开关可拨"
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return http.StatusInternalServerError, err.Error()
	}
	if pid, ok := machineLoginKey(key); ok {
		return s.putMachineLogin(actor, pid, value, settings, now)
	}
	if _, ok := poolPausedKey(key); ok {
		stored := ""
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "on":
			stored = "on"
		case "", "off":
		default:
			return http.StatusBadRequest, PoolPausedPrefix + "<account> is on, or \"\" (off) to resume"
		}
		if err := s.Store.SetFleetSetting(key, stored, now); err != nil {
			return http.StatusInternalServerError, err.Error()
		}
		s.settingAudit(actor, key, settings[key], stored, now)
		if settings[key] != stored {
			s.BroadcastCreds("pool pause") // no node starts a new session there (#3744)
		}
		return http.StatusOK, ""
	}
	if who, ok := langKeyPerson(key); ok {
		// The account language (claude-fleet#2033): zh-CN | en, or "".
		stored := ""
		if strings.TrimSpace(value) != "" {
			if stored = parseLang(value); stored == "" {
				return http.StatusBadRequest, "user.<id>.lang is zh-CN | en, or \"\" for none"
			}
		}
		key = langSettingKey(who)
		if err := s.Store.SetFleetSetting(key, stored, now); err != nil {
			return http.StatusInternalServerError, err.Error()
		}
		s.settingAudit(actor, key, settings[key], stored, now)
		return http.StatusOK, ""
	}
	spec := hubSettings[key]
	stored := ""
	if strings.TrimSpace(value) != "" {
		var why string
		if stored, why = spec.check(s, value); why != "" {
			return http.StatusBadRequest, why
		}
	}
	if err := s.Store.SetFleetSetting(key, stored, now); err != nil {
		return http.StatusInternalServerError, err.Error()
	}
	s.settingAudit(actor, key, settings[key], stored, now)
	return http.StatusOK, ""
}

// putMachineLogin sets user.<pid>.machine_login: on the person's hub_users
// row for a GitHub person (who must be on the list), in the settings table
// for anyone else.
func (s *Server) putMachineLogin(actor, pid, value string, settings map[string]string, now time.Time) (int, string) {
	code, why, _ := s.putMachineLoginMoved(actor, pid, value, settings, now)
	return code, why
}

// putMachineLoginMoved is putMachineLogin, also returning the login it moved
// off an old identity onto the person (claude-fleet#2094), nil when none.
func (s *Server) putMachineLoginMoved(actor, pid, value string, settings map[string]string, now time.Time) (int, string, *store.RekeyResult) {
	if isPerson(pid) {
		if u, err := s.personRow(pid); err != nil {
			return http.StatusInternalServerError, err.Error(), nil
		} else if u == nil {
			return http.StatusNotFound, pid + " is not on the list — add them first (fleet users add <name>)", nil
		}
	}
	stored := ""
	if strings.TrimSpace(value) != "" {
		var why string
		if stored, why = s.checkMachineLogin(pid, value); why != "" {
			return http.StatusBadRequest, why, nil
		}
	}
	if !isPerson(pid) {
		// Any other principal is case-insensitive (claude-fleet#1472): one key
		// per person, whichever way it was typed.
		pid = strings.ToLower(pid)
	}
	key := machineLoginSettingKey(pid)
	if isPerson(pid) {
		u, err := s.personRow(pid)
		if err != nil {
			return http.StatusInternalServerError, err.Error(), nil
		}
		if u == nil {
			return http.StatusNotFound, pid + " is not on the list — add them first (fleet users add <name>)", nil
		}
		if stored == noneValue {
			stored = ""
		}
		var moved *store.RekeyResult
		if stored != "" {
			// An old identity mapped to it in the settings hands it over
			// first; a refusal leaves everything as it was.
			m, err := s.handOverLegacyMap(actor, pid, u.Login, stored, now)
			if err != nil {
				return http.StatusConflict, err.Error(), nil
			}
			moved = m
		}
		old := u.MachineLogin
		u.MachineLogin = stored
		if err := s.Store.UpsertHubUser(*u); err != nil {
			return http.StatusInternalServerError, err.Error(), nil
		}
		s.settingAudit(actor, key, old, stored, now)
		if stored != "" {
			// Placed now, as their sign-in would: the login is theirs on
			// every machine an agent runs as it — taken over from an old
			// identity first when the hub still has it there.
			if m := s.placePrincipal(pid, u.Login, actor); m != nil {
				moved = m
			}
		}
		return http.StatusOK, "", moved
	}
	if err := s.Store.SetFleetSetting(key, stored, now); err != nil {
		return http.StatusInternalServerError, err.Error(), nil
	}
	s.settingAudit(actor, key, settings[key], stored, now)
	if stored != "" && stored != noneValue {
		s.adoptMappedLogins(now)
	}
	return http.StatusOK, "", nil
}

// hubSettingsView is what GET /v1/fleet/settings adds: every hub setting,
// what applies and where it comes from.
type hubSettingView struct {
	Key    string `json:"key"`
	Value  string `json:"value"`
	Source string `json:"source"` // set | legacy | deploy | default
	Help   string `json:"help,omitempty"`
}

func (s *Server) hubSettingsView(settings map[string]string) []hubSettingView {
	keys := hubSettingKeys()
	out := make([]hubSettingView, 0, len(keys))
	for _, k := range keys {
		spec := hubSettings[k]
		v := hubSettingView{Key: k, Value: s.setting(k), Help: spec.help, Source: "default"}
		switch {
		case settings[k] != "":
			v.Source = "set"
		case settings[legacyMigratedPrefix+k] == "" && spec.legacy != nil && spec.legacy(s) != "":
			v.Source = "legacy"
		case spec.deploy != nil && spec.deploy(s) != "":
			v.Source = "deploy"
		}
		out = append(out, v)
	}
	return out
}

// MigrateLegacySettings copies each old variable the hub was started with
// into the database, once per key: a key already set keeps its value, and a
// key migrated before is never re-copied (so an admin who cleared it is not
// overruled by the deploy at the next start). Each copy is a hub_audit row
// by "deploy".
func (s *Server) MigrateLegacySettings(now time.Time) error {
	if s.Store == nil {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	for _, k := range hubSettingKeys() {
		spec := hubSettings[k]
		if spec.legacy == nil || settings[legacyMigratedPrefix+k] != "" {
			continue
		}
		v := spec.legacy(s)
		if v == "" {
			continue
		}
		if settings[k] == "" {
			stored, why := spec.check(s, v)
			if why != "" {
				log.Printf("WARN hub settings: old value of %s not copied: %s", k, why)
				continue
			}
			if err := s.Store.SetFleetSetting(k, stored, now); err != nil {
				return err
			}
			s.settingAudit("deploy", k, "", stored, now)
			log.Printf("hub settings: copied the old value of %s into the database (%s)", k, stored)
		}
		if err := s.Store.SetFleetSetting(legacyMigratedPrefix+k, now.UTC().Format(time.RFC3339), now); err != nil {
			return err
		}
	}
	return nil
}
