package agent

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/sessions"
)

// accountProbeInterval is how often an unobserved subscription is probed.
//
// Deliberately slower than the limits poll. A probe is an inference call, so
// measuring the meter moves it: the reading is not free, and an operator should
// not find that watching a subscription is what consumed it. One call per
// account per five minutes is 288 a day of the cheapest model capped at a single
// token.
const accountProbeInterval = 5 * time.Minute

// probeAccounts reads the meter for every subscription in the token directory
// that nothing else has observed recently.
//
// It exists because the two cheaper sources have gaps. The credentials API needs
// a token with the `user:profile` scope, which only an interactive login has and
// which expires on a machine nobody uses. The statusLine reports a session's own
// account, which covers a subscription only while it is being worked on. A
// subscription that is idle, on a machine with stale credentials, is invisible to
// both — measured here: the account carrying 88% of one fleet's usage had seven
// utilization samples all day.
//
// Tokens minted by `claude setup-token` cannot call the usage endpoint at all
// (403, missing scope) but DO receive full rate-limit headers from inference.
// That is the gap this closes.
//
// Opt-in: with no directory configured this does nothing.
func (a *Agent) probeAccounts(ctx context.Context, observed map[string]bool) []*model.LimitsSnapshot {
	if a.cfg.AccountsDir == "" || a.limits == nil {
		return nil
	}
	entries, err := os.ReadDir(a.cfg.AccountsDir)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("cannot read the accounts directory %s: %v", a.cfg.AccountsDir, err)
		}
		return nil
	}

	now := time.Now().UTC()
	var out []*model.LimitsSnapshot
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		label := e.Name()
		if last, ok := a.lastAccountProbe[label]; ok && now.Sub(last) < accountProbeInterval {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(a.cfg.AccountsDir, label))
		if err != nil {
			continue
		}
		token := strings.TrimSpace(string(raw))
		if token == "" {
			continue
		}

		snap, err := a.limits.FetchViaInference(ctx, token)
		if err != nil {
			log.Printf("could not read the meter for %s: %v", label, err)
			a.noteProbe(label, now) // do not retry in a tight loop
			continue
		}
		a.noteProbe(label, now)

		// The token says nothing about which account it belongs to, but the
		// seven-day reset does: it is the same value ccquota already fingerprints
		// subscriptions by, and the hub folds that onto a real uuid when it
		// knows one.
		key := sessions.FingerprintFor(snap.SevenDay.ResetsAt)
		if key == "" {
			log.Printf("meter for %s carried no seven-day reset; cannot attribute it", label)
			continue
		}
		// Something fresher already covered this subscription this cycle — a
		// running session's statusLine, or this machine's own login. Those cost
		// nothing, so they win.
		if observed[key] {
			continue
		}
		snap.AccountUUID = key
		out = append(out, snap)
	}
	return out
}

func (a *Agent) noteProbe(label string, at time.Time) {
	if a.lastAccountProbe == nil {
		a.lastAccountProbe = map[string]time.Time{}
	}
	a.lastAccountProbe[label] = at
}
