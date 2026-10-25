package api

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

// The Bedrock fallback's hub half (task PNWW). The cluster credential proxy
// asks here — only after a Claude Messages request found no subscription
// (claude_pool_unavailable) or its subscription answered 429 past the one
// rebind — whether this session may replay the request on Amazon Bedrock:
//
//	POST /v1/fleet/credproxy/fallback   Bearer CCQUOTA_FLEET_CREDPROXY_TOKEN
//	     {cred, provider: "claude", model} → {ok, reason?, principal, worker_id,
//	                    account, region, access_key_id, secret_access_key}
//
// ok is false, with one reason, unless every rule holds: fleet.fallback.bedrock
// is "on" (default off — "off"); the pass verifies ("pass: …"); the person is
// not a trial person ("trial"); not over their budget ("budget"); the month's
// Bedrock spend (pool_usage rows of source bedrock, priced at API rates as a
// member's dollar limit is) is under fleet.fallback.bedrock.cap_usd ("cap");
// and the vault holds a Bedrock key ("no_key"). The key travels to the proxy
// for that one request and is never cached there, never leased to a machine.
// What Bedrock served is reported back as usage with source bedrock.

// CredProxyFallbackPath is the route the proxy asks.
const CredProxyFallbackPath = credproxy.FallbackPath

// The fallback's settings.
const (
	BedrockFallbackKey    = "fleet.fallback.bedrock"
	BedrockFallbackCapKey = "fleet.fallback.bedrock.cap_usd"
	bedrockCapDefault     = 200.0
)

func init() {
	hubSettings[BedrockFallbackKey] = hubSetting{def: "off",
		help:  "Amazon Bedrock as the Claude fallback (task PNWW): on — a Claude request the subscription pool cannot take (no account, or a 429 past the one rebind) is replayed on Bedrock with the pool's Bedrock key, metered as source bedrock; never for a trial person, never past fleet.fallback.bedrock.cap_usd a month. off — the original error, as before. 订阅池满时改走 Bedrock",
		check: onOff(BedrockFallbackKey, "off")}
	hubSettings[BedrockFallbackCapKey] = hubSetting{def: "200",
		help:  "the Bedrock fallback's monthly cap in US dollars (UTC month), priced at API rates; at or past it no request falls back (task PNWW). 0 = none falls back",
		check: checkBedrockCap}
}

func checkBedrockCap(_ *Server, v string) (string, string) {
	f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || f < 0 || f > 1e6 {
		return "", BedrockFallbackCapKey + " is a dollar amount 0–1000000, or \"\" for the default (200)"
	}
	return strconv.FormatFloat(f, 'f', -1, 64), ""
}

// bedrockCapUSD is the cap, the default when unreadable.
func (s *Server) bedrockCapUSD() float64 {
	if v, why := checkBedrockCap(s, s.setting(BedrockFallbackCapKey)); why == "" {
		f, _ := strconv.ParseFloat(v, 64)
		return f
	}
	return bedrockCapDefault
}

// monthStart is the first instant of now's UTC month.
func monthStart(now time.Time) time.Time {
	u := now.UTC()
	return time.Date(u.Year(), u.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// bedrockSpendUSD is this month's Bedrock spend, priced as a member's dollar
// limit prices pool usage (priceUsage).
func (s *Server) bedrockSpendUSD(now time.Time) (float64, error) {
	rows, err := s.Store.SourceModelUsageSince(store.UsageSourceBedrock, monthStart(now))
	if err != nil {
		return 0, err
	}
	return priceUsage(rows), nil
}

// bedrockKey is the key a fallback uses: the first Bedrock row by account.
func (s *Server) bedrockKey() (store.Credential, credvault.BedrockKey, error) {
	rows, err := s.Store.BedrockCredentials()
	if err != nil {
		return store.Credential{}, credvault.BedrockKey{}, err
	}
	for _, c := range rows {
		if c.PrincipalID != store.PoolPrincipal {
			continue
		}
		k, err := s.Vault.BedrockKey(c)
		if err == nil {
			return c, k, nil
		}
		log.Printf("bedrock fallback: key %s: %v", c.Account, err)
	}
	return store.Credential{}, credvault.BedrockKey{}, store.ErrNoCredential
}

// handleCredProxyFallback answers the proxy's one fallback question.
func (s *Server) handleCredProxyFallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST {cred, provider, model}")
		return
	}
	if s.CredProxyToken == "" {
		sessionCredRefuse(w, http.StatusServiceUnavailable, CredProxyOff,
			"the cluster credential proxy is off on this hub (no CCQUOTA_FLEET_CREDPROXY_TOKEN)")
		return
	}
	if !constantTimeEqual(bearer(r), s.CredProxyToken) {
		sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated", "the credential proxy's token is required")
		return
	}
	var req struct {
		Cred     string `json:"cred"`
		Provider string `json:"provider"`
		Model    string `json:"model"`
	}
	if err := readOptionalJSON(r, &req); err != nil || req.Cred == "" || !hasString(sessionCredProviders, req.Provider) {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "body must be {\"cred\": \"fcp-h1.…\", \"provider\": \"claude\", \"model\": \"…\"}")
		return
	}
	no := func(reason string) { writeJSON(w, http.StatusOK, credproxy.Fallback{OK: false, Reason: reason}) }
	if req.Provider != credvault.Claude {
		no("provider")
		return
	}
	// off by default: nothing else is read, no pass verified
	if s.setting(BedrockFallbackKey) != "on" {
		no("off")
		return
	}
	if len(s.SessionCredKey) == 0 {
		no("pass: session passes are off on this hub")
		return
	}
	if s.vaultOff(w) || s.vaultLocked(w) {
		return
	}
	now := time.Now()
	v, c := s.verifySessionCred(req.Cred, "", req.Provider, false, now)
	if !v.Valid || c == nil {
		no("pass: " + v.Reason)
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if s.trialIdentity(settings, c.Principal) {
		no("trial")
		return
	}
	clock := s.budgetClock()
	if st, err := s.personBudgetState(c.Principal, clock); err != nil || st.Over {
		no("budget")
		return
	}
	if _, over := s.svcBudgetRefusal(c.Principal, s.svcPassTenant(c), clock); over {
		no("budget")
		return
	}
	spent, err := s.bedrockSpendUSD(clock)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if limit := s.bedrockCapUSD(); spent >= limit {
		log.Printf("bedrock fallback: cap reached ($%.2f of $%.2f this month) principal=%s", spent, limit, c.Principal)
		no(fmt.Sprintf("cap: $%.2f of $%.2f this month", spent, limit))
		return
	}
	row, key, err := s.bedrockKey()
	if err != nil {
		no("no_key")
		return
	}
	log.Printf("bedrock fallback: granted principal=%s worker_id=%s model=%s account=%s", c.Principal, c.WorkerID, req.Model, row.Account)
	writeJSON(w, http.StatusOK, credproxy.Fallback{OK: true, Principal: c.Principal, WorkerID: c.WorkerID,
		Account: row.Account, Region: key.Region, AccessKeyID: key.AccessKeyID, SecretAccessKey: key.SecretAccessKey})
}

// BedrockSpend is the admin's view of the fallback (task PNWW).
type BedrockSpend struct {
	On       bool    `json:"on"`
	MonthUSD float64 `json:"month_usd"`
	CapUSD   float64 `json:"cap_usd"`
}

// bedrockSpendView is the fallback's month for the admin usage page.
func (s *Server) bedrockSpendView(now time.Time) (*BedrockSpend, error) {
	spent, err := s.bedrockSpendUSD(now)
	if err != nil {
		return nil, err
	}
	return &BedrockSpend{On: s.setting(BedrockFallbackKey) == "on", MonthUSD: spent, CapUSD: s.bedrockCapUSD()}, nil
}
