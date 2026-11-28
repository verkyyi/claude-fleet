package api

import (
	"errors"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// A pool credential's quota, as the machine that runs it read it.
//
// The hub read every pool credential's windows itself, through the Singapore
// relay (CCQUOTA_FLEET_HUB_QUOTA=relay, claude-fleet#2169) — until the hub
// moved beyond that relay and the reader went quiet (2026-10-26). The machine's
// credential proxy already holds a reading of every account it serves, off the
// rate-limit headers of each answer: that is the reading its own pick goes by.
// It rides the usage report (POST /v1/node/usage, `quota`), and the hub files
// it under the pool credential's identity exactly as its own reader did, so
// the subscriptions page and the cluster proxy's Codex pick read it with no
// change. No extra upstream request is ever made for it.
//
// A reading is taken only when it can be true: the provider is Claude or Codex,
// the account a pool credential the hub LEASED to this very endpoint within
// nodeQuotaLeaseWindow (fleet_cred_audit `issue`), the reading no older than
// that and no later than now, and newer than the credential's last reading —
// two machines on one account file the newest once. A label the reporting
// login's person also owns is skipped (which of the two the proxy read cannot
// be told). Anything refused is dropped quietly: the usage report it rode on is
// never refused for it, and an older hub ignores the field.

// nodeQuotaLeaseWindow bounds both the lease that vouches for a reading and the
// reading's own age. A node is re-leased every ~10 minutes.
const nodeQuotaLeaseWindow = time.Hour

// NodeQuotaProfile is the Codex snapshot's profile for a proxy reading.
const NodeQuotaProfile = "proxy"

// ObservationProxyHeaders is a Codex reading taken off an answer's headers.
// Not "account_api": the cluster pick treats it as the partial evidence it is.
const ObservationProxyHeaders = "proxy_headers"

type nodeQuotaReading struct {
	Provider string `json:"provider"`
	Account  string `json:"account"`
	At       int64  `json:"at"`
	RL5h     string `json:"rl5h"`
	RL7d     string `json:"rl7d"`
	Reset5   string `json:"rl_reset5"`
	Reset7   string `json:"rl_reset7"`
	Win5     string `json:"win5,omitempty"`
	Win7     string `json:"win7,omitempty"`
}

// pct reads one of the proxy's percents: "-" or junk = absent.
func nodeQuotaPct(v string) (float64, bool) {
	f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || f < 0 || f > 100 {
		return 0, false
	}
	return f, true
}

func nodeQuotaReset(v string, at time.Time) *time.Time {
	n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil || n <= 0 {
		return nil
	}
	t := time.Unix(n, 0).UTC()
	if t.Before(at.Add(-time.Minute)) || t.After(at.Add(8*24*time.Hour)) {
		return nil
	}
	return &t
}

func nodeQuotaMinutes(v string, def int64) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil || n <= 0 || n > 60*24*31 {
		return def
	}
	return n
}

// nodePoolQuota files the readings a node's usage report carried; it returns
// how many it filed. person is the login's principal ("" = none known).
func (s *Server) nodePoolQuota(ep *store.Endpoint, person string, rs []nodeQuotaReading, now time.Time) int {
	if s.Vault == nil || len(rs) == 0 || len(rs) > 64 {
		return 0
	}
	filed := 0
	for _, q := range rs {
		if q.Provider != credvault.Claude && q.Provider != credvault.Codex {
			continue
		}
		if q.Account == "" || len(q.Account) > 128 {
			continue
		}
		at := time.Unix(q.At, 0).UTC()
		if q.At <= 0 || at.After(now.Add(time.Minute)) || now.Sub(at) > nodeQuotaLeaseWindow {
			continue
		}
		c, err := s.Store.Credential(store.PoolPrincipal, q.Provider, q.Account)
		if err != nil || c == nil {
			continue
		}
		if person != "" {
			if own, err := s.Store.Credential(person, q.Provider, q.Account); own != nil || (err != nil && !errors.Is(err, store.ErrNoCredential)) {
				continue
			}
		}
		if ok, err := s.Store.CredIssuedTo(ep.ID, q.Provider, q.Account, now.Add(-nodeQuotaLeaseWindow)); err != nil || !ok {
			continue
		}
		id := s.Vault.CredentialID(*c)
		if id == "" {
			continue
		}
		if prev, err := s.Store.CredentialQuotaRead(id); err != nil || (prev != nil && !at.After(prev.At)) {
			continue
		}
		if err := s.fileNodeQuota(ep, *c, id, q, at); err != nil {
			log.Printf("node quota: %s/%s from %s: %v", q.Provider, q.Account, ep.ID, err)
			continue
		}
		if err := s.Store.SaveCredentialQuotaRead(id, at, ""); err != nil {
			log.Printf("node quota: %s/%s: record the read: %v", q.Provider, q.Account, err)
		}
		filed++
	}
	return filed
}

func (s *Server) fileNodeQuota(ep *store.Endpoint, c store.Credential, id string, q nodeQuotaReading, at time.Time) error {
	p7, ok7 := nodeQuotaPct(q.RL7d)
	if !ok7 {
		return errBadReading
	}
	p5, ok5 := nodeQuotaPct(q.RL5h)
	uuid := s.Vault.AccountUUID(c)
	switch c.Provider {
	case credvault.Claude:
		snap := &model.LimitsSnapshot{AccountUUID: id, EndpointID: ep.ID, ObservedAt: at, CredentialLabel: c.Account,
			SevenDay: model.Window{Utilization: p7, ResetsAt: nodeQuotaReset(q.Reset7, at)}}
		if ok5 { // an Ultra account has no 5-hour window: left at zero, as the hub's own reader leaves it
			snap.FiveHour = model.Window{Utilization: p5, ResetsAt: nodeQuotaReset(q.Reset5, at)}
		}
		if err := s.Store.InsertLimits(snap); err != nil {
			return err
		}
		if uuid != "" {
			if err := s.hubQuotaEnsureAccount(uuid, model.SourceClaude, c.Account); err != nil {
				return err
			}
			snap.AccountUUID = uuid
			return s.Store.InsertLimits(snap)
		}
	case credvault.Codex:
		qs := model.QuotaSnapshot{Source: model.SourceCodex, AccountUUID: id, EndpointID: ep.ID, ProfileID: NodeQuotaProfile,
			ObservedAt: at, Observation: ObservationProxyHeaders}
		if ok5 {
			qs.Windows = append(qs.Windows, model.QuotaWindow{ID: "codex:primary", LimitID: "codex", Label: "codex · primary",
				Minutes: nodeQuotaMinutes(q.Win5, 300), UsedPercent: p5, ResetsAt: nodeQuotaReset(q.Reset5, at)})
		}
		qs.Windows = append(qs.Windows, model.QuotaWindow{ID: "codex:secondary", LimitID: "codex", Label: "codex · secondary",
			Minutes: nodeQuotaMinutes(q.Win7, 10080), UsedPercent: p7, ResetsAt: nodeQuotaReset(q.Reset7, at)})
		qs.Blocked = p7 >= 100 || (ok5 && p5 >= 100)
		if err := s.Store.InsertQuota(qs); err != nil {
			return err
		}
		if uuid != "" {
			if err := s.hubQuotaEnsureAccount(uuid, model.SourceCodex, c.Account); err != nil {
				return err
			}
			qs.AccountUUID = uuid
			return s.Store.InsertQuota(qs)
		}
	}
	return nil
}

type nodeQuotaError string

func (e nodeQuotaError) Error() string { return string(e) }

const errBadReading = nodeQuotaError("the reading carries no weekly percent")
