package api

import (
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// credentialLimits is the shared reader for UI, overview and selection. The
// snapshot tables' historical account_uuid column holds an internal subject;
// no account row is invented and the wire's account_uuid stays the real UUID.
func (s *Server) credentialLimits(c store.Credential) (*LimitsView, error) {
	v := &LimitsView{Source: c.Provider, Reason: "No quota reading yet", ReadStatus: "unknown"}
	if s.Vault == nil {
		return v, nil
	}
	id := s.Vault.CredentialID(c)
	if id == "" {
		return v, nil
	}
	var err error
	if c.Provider == credvault.Codex {
		v, err = s.codexLimitsFor(id)
	} else {
		v, err = s.LimitsFor(id)
	}
	if err != nil {
		return nil, err
	}
	v.AccountUUID = s.Vault.AccountUUID(c)
	v.Source, v.ReadStatus = c.Provider, "unknown"
	if v.Available {
		v.ReadStatus = "ok"
	}
	r, err := s.Store.CredentialQuotaRead(id)
	if err != nil {
		return nil, err
	}
	if r != nil {
		v.ReadAttemptAt = &r.At
		if r.Error != "" {
			v.ReadStatus, v.ReadNote = "failed", r.Error
		}
	}
	if v.ObservedAt != nil {
		fresh := DefaultHubQuotaInterval * 2
		if s.HubQuota != nil {
			fresh = s.HubQuota.Fresh()
		}
		if time.Since(*v.ObservedAt) > fresh && v.ReadStatus == "ok" {
			v.ReadStatus = "stale"
		}
	}
	return v, nil
}

func (s *Server) credentialSnapshot(c store.Credential) *model.LimitsSnapshot {
	v, err := s.credentialLimits(c)
	if err != nil || !v.Available {
		return nil
	}
	snap := &model.LimitsSnapshot{}
	if v.ObservedAt != nil {
		snap.ObservedAt = *v.ObservedAt
	}
	if v.FiveHour != nil {
		snap.FiveHour = model.Window{Utilization: v.FiveHour.Utilization, ResetsAt: v.FiveHour.ResetsAt}
	}
	if v.SevenDay != nil {
		snap.SevenDay = model.Window{Utilization: v.SevenDay.Utilization, ResetsAt: v.SevenDay.ResetsAt}
	}
	for _, w := range v.Windows {
		if w.Minutes == 300 {
			snap.FiveHour = model.Window{Utilization: w.Utilization, ResetsAt: w.ResetsAt}
		}
		if w.Minutes == 10080 {
			snap.SevenDay = model.Window{Utilization: w.Utilization, ResetsAt: w.ResetsAt}
		}
	}
	return snap
}

// dedupCredentials runs after authorization/pausing: an allowed alias must not
// disappear just because another name for the same token was denied.
func (s *Server) dedupCredentials(rows []store.Credential) []store.Credential {
	if s.Vault == nil {
		return rows
	}
	seen := map[string]bool{}
	out := make([]store.Credential, 0, len(rows))
	for _, c := range rows {
		id := s.Vault.CredentialID(c)
		if id != "" && seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, c)
	}
	return out
}
