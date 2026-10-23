package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

const nodeCapacityPath = "/v1/node/codex-capacity"

// Metadata only: the node's identity, trust, machine/person allowlists and
// credential dedup are the same gates as leasing. Never Lease or refresh here.
// The consumer must intersect these rows with its actually held subscriptions.
func (s *Server) handleNodeCapacity(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		httpError(w, 405, "GET only")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	if s.vaultOff(w) || s.vaultLocked(w) {
		return
	}
	now := time.Now().UTC()
	host, login := s.nodeIdentity(ep)
	principal, err := s.principalForLease(ep.ID, host, login, now)
	if err != nil {
		httpError(w, 403, "no active node principal")
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, 500, "policy read failed")
		return
	}
	trust, err := s.trustSettings(now)
	if err != nil {
		httpError(w, 500, "trust read failed")
		return
	}
	if t, _ := s.endpointTrust(ep.ID, host, trust); t != TrustTrusted {
		httpError(w, 403, "trusted node required")
		return
	}
	hb, _, _ := s.nodeStatusOf(ep.ID, now)
	if credsepGated(hb.Credsep) || s.computeOf(ep.ID, hb, settings, now).Off {
		httpError(w, 403, "node cannot lease subscriptions")
		return
	}
	revoked, err := s.Store.RevokedFor(host, principal)
	if err != nil {
		httpError(w, 500, "revocation read failed")
		return
	}
	denied, err := s.machineDeniedFor(ep.ID, host, principal)
	if err != nil {
		httpError(w, 500, "machine policy read failed")
		return
	}
	if revoked != nil || denied != "" {
		httpError(w, 403, "node subscription access refused")
		return
	}
	choices, err := s.sessionBindChoices(principal, ep.ID, credvault.Codex)
	if err != nil {
		httpError(w, 500, "subscription policy read failed")
		return
	}
	cat, err := s.Store.PlanCapacities()
	if err != nil {
		httpError(w, 500, "capacity catalog read failed")
		return
	}
	type row struct {
		codexQuotaInput
		CredentialID string          `json:"credential_id"`
		Paused       bool            `json:"paused"`
		Conservative codexQuotaInput `json:"conservative"`
	}
	rows := []row{}
	expires := now.Add(30 * time.Second)
	paused := map[string]bool{}
	for _, a := range pausedAccounts(settings) {
		paused[a] = true
	}
	seen := map[string]bool{}
	for _, c := range choices {
		// A local lease is addressed by label; own wins over a colliding pool label.
		if seen[c.Account] {
			continue
		}
		seen[c.Account] = true
		input := s.codexQuotaForCatalog(c, now, cat.Catalog)
		if input.Score != nil {
			for _, window := range input.Windows {
				// Cache may never extend the lifetime of positive observations.
				until := now.Add(codexQuotaFresh - time.Duration(window.Age+1)*time.Second)
				if until.Before(expires) {
					expires = until
				}
			}
			if input.Capacity.Profile.EffectiveTo != nil && input.Capacity.Profile.EffectiveTo.Before(expires) {
				expires = *input.Capacity.Profile.EffectiveTo
			}
		}
		rows = append(rows, row{codexQuotaInput: input, CredentialID: s.Vault.CredentialID(c), Paused: c.PrincipalID == store.PoolPrincipal && paused[c.Account], Conservative: s.codexQuotaForCatalog(c, now, store.PlanCapacityCatalog{Mode: "off"})})
	}
	writeJSON(w, 200, map[string]any{"policy": "codex-capacity-v2", "catalog_revision": cat.Revision, "mode": cat.Catalog.Mode, "observed_at": now, "expires_at": expires, "accounts": rows, "load_basis": "consumer supplies local session reservations; no global concurrency measurement", "mutates_bindings": false})
}
