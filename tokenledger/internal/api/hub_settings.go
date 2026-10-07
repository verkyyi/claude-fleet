package api

import (
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The hub's settings live in the database (claude-fleet#1986, EPIC #1982 C4):
// an admin changes them on the web or with `fleet hub set <key> <value>`
// (PUT /v1/fleet/settings), they apply on the next request, and every change
// is one hub_audit row (who, when, old → new). The deploy keeps only what a
// running hub cannot change about itself (EPIC #1982 rule 2).
//
// Reading a setting goes through Server.setting(key) and nothing else: the
// stored value, else — for ONE version — the old environment variable or
// flag it replaces, else the default below. The hub copies each old value
// into the database once at start (MigrateLegacySettings), so the list an
// admin reads shows what applies; the next version stops reading the old
// variables.

// The hub settings' keys.
const (
	PublicBadgesKey = "hub.public_badges"
	PoolSkipPctKey  = "pool.skip_pct"
	PoolMoveFullKey = "pool.move_when_full"
	AutoAssignKey   = "fleet.auto_assign"
	SpotKey         = "fleet.spot"
	RoutesExtraKey  = "fleet.routes_extra"

	// userSettingPrefix / machineLoginSuffix make user.<id>.machine_login:
	// the OS login that is a person's on the machines. <id> is the principal
	// — gh:<GitHub ID> for a GitHub person (stored on their hub_users row,
	// the one place the scope reads), a WeCom userid otherwise.
	userSettingPrefix  = "user."
	machineLoginSuffix = ".machine_login"

	// noneValue clears a list or a login on purpose: "" means "back to the
	// default", which for one version is still the old variable.
	noneValue = "none"

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
	MeterKey: {def: "on", help: "the public counter (/meter.json, /odometer.svg)",
		check: onOff(MeterKey, "on")},
	PublicBadgesKey: {def: "off", help: "badges and embeds readable without signing in (replaces --public-badges)",
		check: onOff(PublicBadgesKey, "off"),
		legacy: func(s *Server) string {
			if s.PublicBadges {
				return "on"
			}
			return ""
		}},
	PoolSkipPctKey: {def: "85", help: "a subscription at or above this % of a window is skipped (nodes: FLEET_ACCOUNT_CEILING)",
		check: func(_ *Server, v string) (string, string) {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil || n < 1 || n > 100 {
				return "", PoolSkipPctKey + " is an integer 1–100, or \"\" for the default (85)"
			}
			return strconv.Itoa(n), ""
		}},
	PoolMoveFullKey: {def: "off", help: "move a session to another subscription when its own is full (nodes: FLEET_FAILOVER)",
		check: onOff(PoolMoveFullKey, "off")},
	AutoAssignKey: {def: "", help: "machines a new person gets a login opened on, comma-separated, or none (replaces CCQUOTA_FLEET_AUTO_ASSIGN)",
		check: func(_ *Server, v string) (string, string) {
			if strings.EqualFold(strings.TrimSpace(v), noneValue) {
				return noneValue, ""
			}
			hosts := splitHosts(v)
			if len(hosts) == 0 {
				return "", AutoAssignKey + " is machine names, comma-separated, or none"
			}
			for _, h := range hosts {
				if !nodeNameRE.MatchString(h) {
					return "", fmt.Sprintf("%s: %q is not a machine name", AutoAssignKey, h)
				}
			}
			return strings.Join(hosts, ","), ""
		},
		legacy: func(s *Server) string { return strings.Join(s.FleetAutoAssign, ",") }},
	SpotKey: {def: "off", help: "rented SPOT machines when no machine has room (needs CCQUOTA_FLEET_SPOT_IMAGE)",
		check: onOff(SpotKey, "off"),
		legacy: func(s *Server) string {
			// Before the switch, a configured image WAS on.
			if s.Spot != nil {
				return "on"
			}
			return ""
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

// isHubSettingKey reports whether key is one of hubSettings, a
// user.<id>.machine_login or a user.<GitHub ID>.lang.
func isHubSettingKey(key string) bool {
	if _, ok := hubSettings[key]; ok {
		return true
	}
	if _, ok := langKeyID(key); ok {
		return true
	}
	_, ok := machineLoginKey(key)
	return ok
}

// machineLoginKey parses user.<id>.machine_login. <id> is a GitHub ID — bare
// digits, as C9's user.<id>.lang spells it (claude-fleet#2033), or gh:<id> —
// else a WeCom userid; the principal comes back as gh:<id> for a GitHub one.
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

// langKeyID parses user.<GitHub ID>.lang — the account language C9 reads
// (pagelang.go's langSettingKey).
func langKeyID(key string) (int64, bool) {
	rest, ok := strings.CutPrefix(key, userSettingPrefix)
	if !ok {
		return 0, false
	}
	num, ok := strings.CutSuffix(rest, ".lang")
	if !ok {
		return 0, false
	}
	num = strings.TrimPrefix(num, githubPrincipalPrefix)
	id, err := strconv.ParseInt(num, 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func machineLoginSettingKey(principal string) string {
	return userSettingPrefix + principal + machineLoginSuffix
}

// setting is the ONE reading of a hub setting: the stored value, else the
// old variable (one version), else the default. An unreadable table reads
// as the old variable or the default.
func (s *Server) setting(key string) string {
	spec, ok := hubSettings[key]
	if s.Store != nil {
		if settings, err := s.Store.FleetSettings(); err == nil {
			if v := settings[key]; v != "" {
				return v
			}
			if settings[legacyMigratedPrefix+key] != "" {
				// The old value was copied in and since cleared: the
				// default, not the variable.
				return spec.def
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
	return spec.def
}

func (s *Server) settingOn(key string) bool { return strings.EqualFold(s.setting(key), "on") }

// publicBadges reports whether /badge/ and /embed/ answer without a sign-in.
func (s *Server) publicBadges() bool { return s.settingOn(PublicBadgesKey) }

// autoAssign is the machines a new person gets a login queued on.
func (s *Server) autoAssign() []string {
	v := s.setting(AutoAssignKey)
	if strings.EqualFold(v, noneValue) {
		return nil
	}
	return splitHosts(v)
}

// spot is the SPOT controller while fleet.spot is on, else nil.
func (s *Server) spot() *SpotController {
	if s.Spot == nil || !s.settingOn(SpotKey) {
		return nil
	}
	return s.Spot
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

// settingMachineLogins is every user.<id>.machine_login stored in the
// settings table (WeCom people; a GitHub person's is on their hub_users
// row), principal → login. "none" entries are kept: they mean "no login",
// and they hide an old CCQUOTA_FLEET_PRINCIPAL_LOGINS entry.
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

// principalLogins is the whole person → machine login map placement reads:
// the stored settings, then — one version — CCQUOTA_FLEET_PRINCIPAL_LOGINS
// for a person the settings do not name. Keys are lower case; "none" is
// dropped.
func (s *Server) principalLogins() map[string]string {
	out := map[string]string{}
	for pid, login := range s.FleetPrincipalLogins {
		out[strings.ToLower(pid)] = login
	}
	for pid, login := range s.settingMachineLogins() {
		out[pid] = login
	}
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
	if who := s.machineLoginOwner(v); who != "" && !strings.EqualFold(who, pid) {
		return "", fmt.Sprintf("machine login %s is already %s's", v, who)
	}
	return v, ""
}

// machineLoginOwner is the principal a machine login belongs to, "" when
// nobody's: a GitHub person's row, a stored setting, or the old variable.
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
					return githubPrincipal(u.GitHubID)
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
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return http.StatusInternalServerError, err.Error()
	}
	if pid, ok := machineLoginKey(key); ok {
		return s.putMachineLogin(actor, pid, value, settings, now)
	}
	if id, ok := langKeyID(key); ok {
		// The account language (claude-fleet#2033): zh-CN | en, or "".
		stored := ""
		if strings.TrimSpace(value) != "" {
			if stored = parseLang(value); stored == "" {
				return http.StatusBadRequest, "user.<id>.lang is zh-CN | en, or \"\" for none"
			}
		}
		key = langSettingKey(id)
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
	if id, ok := githubIDOf(pid); ok {
		if u, err := s.Store.HubUserByID(id); err != nil {
			return http.StatusInternalServerError, err.Error()
		} else if u == nil {
			return http.StatusNotFound, pid + " is not on the list — add them first (fleet users add <name>)"
		}
	}
	stored := ""
	if strings.TrimSpace(value) != "" {
		var why string
		if stored, why = s.checkMachineLogin(pid, value); why != "" {
			return http.StatusBadRequest, why
		}
	}
	if _, gh := githubIDOf(pid); !gh {
		// A WeCom userid is case-insensitive (claude-fleet#1472): one key
		// per person, whichever way it was typed.
		pid = strings.ToLower(pid)
	}
	key := machineLoginSettingKey(pid)
	if id, ok := githubIDOf(pid); ok {
		u, err := s.Store.HubUserByID(id)
		if err != nil {
			return http.StatusInternalServerError, err.Error()
		}
		if u == nil {
			return http.StatusNotFound, pid + " is not on the list — add them first (fleet users add <name>)"
		}
		if stored == noneValue {
			stored = ""
		}
		old := u.MachineLogin
		u.MachineLogin = stored
		if err := s.Store.UpsertHubUser(*u); err != nil {
			return http.StatusInternalServerError, err.Error()
		}
		s.settingAudit(actor, key, old, stored, now)
		if stored != "" {
			// Placed now, as their sign-in would: the login is theirs on
			// every machine an agent runs as it.
			s.onPrincipalSignIn(pid, u.Login)
		}
		return http.StatusOK, ""
	}
	if err := s.Store.SetFleetSetting(key, stored, now); err != nil {
		return http.StatusInternalServerError, err.Error()
	}
	s.settingAudit(actor, key, settings[key], stored, now)
	if stored != "" && stored != noneValue {
		s.adoptMappedLogins(now)
	}
	return http.StatusOK, ""
}

// hubSettingsView is what GET /v1/fleet/settings adds: every hub setting,
// what applies and where it comes from.
type hubSettingView struct {
	Key    string `json:"key"`
	Value  string `json:"value"`
	Source string `json:"source"` // set | legacy | default
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
		}
		out = append(out, v)
	}
	return out
}

// MigrateLegacySettings copies each old variable the hub was started with
// into the database, once per key: a key already set keeps its value, and a
// key migrated before is never re-copied (so an admin who cleared it is not
// overruled by the deploy at the next start). The per-person machine logins
// of CCQUOTA_FLEET_PRINCIPAL_LOGINS go the same way, to
// user.<id>.machine_login. Each copy is a hub_audit row by "deploy".
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
	const loginsMarker = legacyMigratedPrefix + "principal_logins"
	if len(s.FleetPrincipalLogins) > 0 && settings[loginsMarker] == "" {
		pids := make([]string, 0, len(s.FleetPrincipalLogins))
		for pid := range s.FleetPrincipalLogins {
			pids = append(pids, pid)
		}
		sort.Strings(pids)
		for _, pid := range pids {
			login := s.FleetPrincipalLogins[pid]
			if code, why := s.migrateMachineLogin(pid, login, settings, now); code != http.StatusOK {
				log.Printf("WARN hub settings: CCQUOTA_FLEET_PRINCIPAL_LOGINS %s=%s not copied: %s", pid, login, why)
			}
		}
		if err := s.Store.SetFleetSetting(loginsMarker, now.UTC().Format(time.RFC3339), now); err != nil {
			return err
		}
	}
	return nil
}

// migrateMachineLogin copies one old map entry unless the person already
// has a login on record.
func (s *Server) migrateMachineLogin(pid, login string, settings map[string]string, now time.Time) (int, string) {
	if id, ok := githubIDOf(pid); ok {
		u, err := s.Store.HubUserByID(id)
		if err != nil {
			return http.StatusInternalServerError, err.Error()
		}
		if u == nil {
			return http.StatusNotFound, "not on the list"
		}
		if u.MachineLogin != "" {
			return http.StatusOK, ""
		}
	} else if settings[machineLoginSettingKey(pid)] != "" {
		return http.StatusOK, ""
	}
	return s.putMachineLogin("deploy", pid, login, settings, now)
}
