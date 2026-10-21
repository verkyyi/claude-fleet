package api

import (
	"log"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Where a trial's quota comes from (EPIC WACK C1). Every subscription has a
// source class (store.Credential.Source): a pool row is a personal
// subscription (subscription, the default) or a commercial API key (api), as
// an admin records it (credentials action=source); a person's own row is
// always byo (自带). One setting decides which classes a TRIAL IDENTITY
// (trialIdentity, fleet_trial_egress.go: 立即体验, a member on trial terms,
// a scanned trial code) may draw on:
//
//	fleet.trial.sources   comma list of pool · subscription · api · byo;
//	                      pool = subscription + api. Default "pool,byo":
//	                      every class — no gate at all, byte for byte as
//	                      before. "byo": a trial spends only its own
//	                      subscription; with none connected the try page
//	                      says so (reason byo) and offers 「接上我自己的订阅」.
//
// The gate rides the one resolver (credPolicy.Sources, judged in
// credVerdict), so the node lease, the pool manifest and the central proxy's
// choice all honour it. fleet.trial.cred_allow (#4260) still narrows an
// instant trial's IDs on top. A full member is never touched.
const TrialSourcesKey = "fleet.trial.sources"

const trialSourcesDefault = "pool,byo"

// trialWaitBYO: fleet.trial.sources leaves a trial only its own
// subscription, and it has none to use.
const trialWaitBYO = "byo"

// sourceTokens is what each word of the setting stands for.
var sourceTokens = map[string][]string{
	"pool":                   {store.SourceSubscription, store.SourceAPI},
	store.SourceSubscription: {store.SourceSubscription},
	store.SourceAPI:          {store.SourceAPI},
	store.SourceBYO:          {store.SourceBYO},
}

// parseTrialSources reads the setting: the classes it allows, or why not.
func parseTrialSources(v string) (map[string]bool, string) {
	v = strings.TrimSpace(v)
	if v == "" {
		v = trialSourcesDefault
	}
	out := map[string]bool{}
	for _, w := range strings.Split(v, ",") {
		w = strings.ToLower(strings.TrimSpace(w))
		if w == "" {
			continue
		}
		cls, ok := sourceTokens[w]
		if !ok {
			return nil, TrialSourcesKey + " is a comma list of pool, subscription, api and byo (pool = subscription + api): " + w + " is none of them"
		}
		for _, c := range cls {
			out[c] = true
		}
	}
	if len(out) == 0 {
		return nil, TrialSourcesKey + " needs at least one of pool, subscription, api, byo"
	}
	return out, ""
}

// checkTrialSources is the setting's checker: stored in a fixed order.
func checkTrialSources(_ *Server, v string) (string, string) {
	cls, why := parseTrialSources(v)
	if why != "" {
		return "", why
	}
	var words []string
	if cls[store.SourceSubscription] && cls[store.SourceAPI] {
		words = append(words, "pool")
	} else {
		for _, c := range []string{store.SourceSubscription, store.SourceAPI} {
			if cls[c] {
				words = append(words, c)
			}
		}
	}
	if cls[store.SourceBYO] {
		words = append(words, store.SourceBYO)
	}
	return strings.Join(words, ","), ""
}

// trialSourcesOf is the classes a trial identity may use; nil = every class
// (no gate). A broken stored value allows only byo: a broken restriction
// never reads as none.
func trialSourcesOf(settings map[string]string) map[string]bool {
	cls, why := parseTrialSources(settings[TrialSourcesKey])
	if why != "" {
		log.Printf("fleet: %s: %s — trials use only their own subscription", TrialSourcesKey, why)
		return map[string]bool{store.SourceBYO: true}
	}
	if cls[store.SourceSubscription] && cls[store.SourceAPI] && cls[store.SourceBYO] {
		return nil
	}
	return cls
}

// trialSourcesAllow narrows a trial identity's policy to fleet.trial.sources.
func (s *Server) trialSourcesAllow(settings map[string]string, p *credPolicy) {
	if p.Principal == "" {
		return
	}
	cls := trialSourcesOf(settings)
	if cls == nil || !s.trialIdentity(settings, p.Principal) {
		return
	}
	p.Sources = cls
}

// sourcesWhy is "" when c's class is in p's sources, else the readable
// refusal the lease, the proxy and the policy view carry.
func (p credPolicy) sourcesWhy(c store.Credential) string {
	if p.Sources == nil || c.Provider == credvault.GitHub || p.Sources[c.Source()] {
		return ""
	}
	if p.Sources[store.SourceBYO] && len(p.Sources) == 1 {
		return "trials use only their own subscription now (" + TrialSourcesKey + "=byo): connect your own Claude or ChatGPT subscription · 试用现在只用你自己的订阅：请先接上自己的 Claude 或 ChatGPT 订阅"
	}
	return "a " + c.Source() + " subscription is not a source trials may use (" + TrialSourcesKey + "=" + sourcesWords(p.Sources) + ") · 试用不能用这类订阅"
}

func sourcesWords(cls map[string]bool) string {
	var w []string
	for c := range cls {
		w = append(w, c)
	}
	sort.Strings(w)
	return strings.Join(w, ",")
}

// trialNeedsOwn says whether pid, a trial identity, is limited to its own
// subscription by fleet.trial.sources and has none it could use (none
// connected, every one paused or needing a new sign-in).
func (s *Server) trialNeedsOwn(pid string) bool {
	if s.Store == nil || pid == "" {
		return false
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return false
	}
	cls := trialSourcesOf(settings)
	if cls == nil || cls[store.SourceSubscription] || cls[store.SourceAPI] || !s.trialIdentity(settings, pid) {
		return false
	}
	own, err := s.Store.Credentials(pid)
	if err != nil {
		return false
	}
	for _, c := range own {
		if c.Provider != credvault.GitHub && !c.ReauthRequired && !ownPaused(settings, c) {
			return false
		}
	}
	return true
}

// setCredentialSource is the credentials route's action=source.
func (s *Server) setCredentialSource(principal, provider, account, class string, now time.Time) error {
	if err := s.Store.SetCredentialSource(principal, provider, account, class, now); err != nil {
		return err
	}
	s.sessCred.drop("")
	return nil
}
