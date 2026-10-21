package api

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A spare's subscriptions during its own create / reset (claude-fleet NKTP).
// A spare is a principal spare:<machine>:<nonce> the hub mints itself
// (store.CreateSpare), so no administrator can list it ahead of time, and in
// strict mode «no list» denied every subscription: D0JC let the readiness
// check (fleet-login-ready.sh, #4673) lease inside the op, and the policy then
// withdrew every credential — 「person spare:… has no allowlist」, ready 0.
// Its person allowance is ONE hub setting instead of a key per spare:
//
//	fleet.spare.cred_allow   "*" (the default): every subscription the
//	                         spare is otherwise eligible for (the shared pool;
//	                         the machine's own list still applies); a JSON
//	                         list: only those; [] : none — every new spare
//	                         then fails its check (FAIL reply), as before.
//
// Security: the allowance lasts exactly as long as the lease's own in-flight
// answer (principalForLease) — while the spare's create / reset is sent and
// unanswered, at most accountOpLeaseWindow after the send. A ready spare
// sitting idle, a spare whose op failed or dropped (unknown), one past the
// window and anyone else still have no list: denied. A claimed spare is the
// person's principal (store.ClaimSpare re-keys it) and follows the person's
// rules (their own list, a trial's fleet.trial.cred_allow, the mode). A list
// written for the spare itself wins. Usage is counted by the spare's
// principal, which no budget or people list reads.
const SpareCredAllowKey = "fleet.spare.cred_allow"

// checkSpareCredAllow is the setting's checker: "*" (bare or quoted) or a
// JSON list of subscription IDs, stored as the cred-policy values are.
func checkSpareCredAllow(_ *Server, v string) (string, string) {
	v = strings.TrimSpace(v)
	if v == "*" || v == `"*"` {
		return `"*"`, ""
	}
	ids, err := parseCredAllow(v)
	if err != nil {
		return "", SpareCredAllowKey + ` is "*" (every eligible subscription), a JSON list of subscription IDs, or [] for none: ` + err.Error()
	}
	list := make([]string, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	sort.Strings(list)
	b, _ := json.Marshal(list)
	return string(b), ""
}

// spareCredAllowOf is a spare's allowance inside its op: the setting, "*" unset.
func spareCredAllowOf(settings map[string]string) credAllow {
	if v := strings.TrimSpace(settings[SpareCredAllowKey]); v == "" {
		return credAllow{Set: true, All: true}
	}
	return credAllowOf(settings, SpareCredAllowKey)
}

// spareUserAllow gives a spare with no list of its own the spare allowance —
// only while its own create / reset is in flight inside the op's window.
func (s *Server) spareUserAllow(settings map[string]string, p *credPolicy, now time.Time) error {
	if !store.IsSparePrincipal(p.Principal) || !p.User.Set || p.User.All {
		return nil
	}
	if _, own := settings[credUserKey(p.Principal)]; own {
		return nil
	}
	a, err := s.Store.SpareOpInFlight(p.Principal)
	if errors.Is(err, store.ErrNoPrincipal) {
		return nil
	}
	if err != nil {
		return err
	}
	if sent := a.UpdatedAt; now.Before(sent.Add(-time.Minute)) || now.Sub(sent) > accountOpLeaseWindow {
		return nil
	}
	p.User = spareCredAllowOf(settings)
	return nil
}
