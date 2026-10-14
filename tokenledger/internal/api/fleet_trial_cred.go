package api

import (
	"encoding/json"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A trial person's subscriptions (claude-fleet#4260). A trial person is a
// p:<uuid> minted at the trial's sign-in (trialSignIn): no administrator has
// ever listed it, and in strict mode «no list» is denied every subscription —
// so the trial's first line answered the proxy's raw 403 and no trial ever
// spoke. Its person allowance is ONE hub setting instead of a key per person:
//
//	fleet.trial.cred_allow   "*" (the default): every subscription the trial
//	                         is otherwise eligible for (the shared pool, the
//	                         machine's own list still applies); a JSON list:
//	                         only those; [] : none — a trial then waits with
//	                         reason nosub (「试用暂时没有可用订阅」), never
//	                         placed onto a 403.
//
// Usage is still counted by the trial's own principal (共同约定 1). A list
// written for the person themselves wins. Approval (convertTrial) writes the
// trial's allowance as the new member's own list, so the conversation they
// started keeps its subscription — an administrator narrows it from there.
const TrialCredAllowKey = "fleet.trial.cred_allow"

// trialWaitNoSub: fleet.trial.cred_allow leaves a trial no subscription.
const trialWaitNoSub = "nosub"

// checkTrialCredAllow is the setting's checker: "*" (bare or quoted) or a
// JSON list of subscription IDs, stored as the cred-policy values are.
func checkTrialCredAllow(_ *Server, v string) (string, string) {
	v = strings.TrimSpace(v)
	if v == "*" || v == `"*"` {
		return `"*"`, ""
	}
	ids, err := parseCredAllow(v)
	if err != nil {
		return "", TrialCredAllowKey + ` is "*" (every eligible subscription), a JSON list of subscription IDs, or [] for none: ` + err.Error()
	}
	list := make([]string, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	sort.Strings(list)
	b, _ := json.Marshal(list)
	return string(b), ""
}

// trialCredAllowOf is a trial person's allowance: the setting, "*" unset.
func trialCredAllowOf(settings map[string]string) credAllow {
	if v := strings.TrimSpace(settings[TrialCredAllowKey]); v == "" {
		return credAllow{Set: true, All: true}
	}
	return credAllowOf(settings, TrialCredAllowKey)
}

// trialUserAllow gives a trial person with no list of its own the trial's
// allowance. A converted trial is a member: its own list (written at the
// conversion) or the mode decides, as for anyone.
func (s *Server) trialUserAllow(settings map[string]string, p *credPolicy) {
	if p.Principal == "" || !p.User.Set || p.User.All || isSvcPrincipal(p.Principal) {
		return
	}
	if _, own := settings[credUserKey(p.Principal)]; own {
		return
	}
	if s.trialPerson(p.Principal) {
		p.User = trialCredAllowOf(settings)
	}
}

// trialNoSub says whether the trial's allowance leaves it nothing to use:
// an empty or broken list. "*" and a list are judged by the lease as usual.
func (s *Server) trialNoSub() bool {
	if s.Store == nil {
		return false
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return false
	}
	a := trialCredAllowOf(settings)
	return !a.All && (a.Bad != "" || len(a.IDs) == 0)
}

// trialCredOnConvert writes the trial's allowance as pid's own person list
// when it has none, so approval does not cut off the subscription the trial
// was using (strict mode would deny a member with no list).
func (s *Server) trialCredOnConvert(pid, by string, now time.Time) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		log.Printf("fleet: trial of %s: convert allowlist: %v", pid, err)
		return
	}
	key := credUserKey(pid)
	if _, own := settings[key]; own {
		return
	}
	value := `"*"`
	if v := strings.TrimSpace(settings[TrialCredAllowKey]); v != "" {
		value = v
	}
	if err := s.Store.SetFleetSetting(key, value, now); err != nil {
		log.Printf("fleet: trial of %s: convert allowlist: %v", pid, err)
		return
	}
	if err := s.Store.AddCredAudit(store.CredAudit{Action: store.CredPolicy, PrincipalID: pid,
		Detail: "user " + pid + ": unconfigured → " + value + " · trial converted (" + TrialCredAllowKey + ") · by " + by}); err != nil {
		log.Printf("fleet: trial of %s: convert allowlist audit: %v", pid, err)
	}
	s.settingAudit(by, key, "", value, now)
	s.sessCred.drop("")
}
