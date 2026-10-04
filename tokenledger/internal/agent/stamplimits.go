package agent

import (
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/sessions"
)

// stampLimitsMaxAge is how fresh a stamp must be to be believed as a limits
// reading. A statusLine redraws constantly while a session works, so anything
// older than this is from a session that has stopped.
const stampLimitsMaxAge = 3 * time.Minute

// limitsFromStamps harvests a utilization reading for every subscription a
// session on this machine is currently running under.
//
// Until now these readings were a SIDE EFFECT of attributing events: a group
// was created only when a subscription had new turns to file, so an idle
// session reported its account's rate limits every few seconds and ccquota threw
// them away. The consequence was measurable — the account carrying 88% of one
// fleet's usage had SEVEN utilization samples, all from a sixteen-minute window
// when a laptop happened to be logged into it, because no endpoint logged into
// it could read the credentials API.
//
// This path needs no credentials at all. Claude Code hands each session its own
// account-wide rate_limits in the statusLine payload, so any subscription being
// used anywhere on this machine can be observed, whether or not the machine is
// logged into it and whether or not its stored token has expired.
//
// One reading per subscription, from its freshest stamp: several sessions on one
// subscription all report the same account-wide numbers, so the rest are copies.
func (a *Agent) limitsFromStamps(now time.Time) []*model.LimitsSnapshot {
	if a.stamps == nil {
		return nil
	}
	freshest := map[string]sessions.Stamp{}
	for _, st := range a.stamps.ByTranscript {
		key := st.Account()
		if key == "" {
			continue
		}
		if now.Sub(st.StampedAt) > stampLimitsMaxAge {
			continue
		}
		// A stamp with no rate limits is an API-key session: it has invoices,
		// not windows, and reporting it as 0% utilization would claim a plan
		// was idle when it is not being used at all.
		if st.FiveHourPct == nil && st.SevenDayPct == nil {
			continue
		}
		if prev, ok := freshest[key]; !ok || st.StampedAt.After(prev.StampedAt) {
			freshest[key] = st
		}
	}

	var out []*model.LimitsSnapshot
	for key, st := range freshest {
		// Nothing new since the last one we sent for this subscription. Sending
		// it again would fill limit_snapshots with duplicates at the scan
		// cadence and make the row count look like observation.
		if last, ok := a.lastStampLimits[key]; ok && !st.StampedAt.After(last) {
			continue
		}
		if a.lastStampLimits == nil {
			a.lastStampLimits = map[string]time.Time{}
		}
		a.lastStampLimits[key] = st.StampedAt
		out = append(out, limitsFromStamp(st, key))
	}
	return out
}
