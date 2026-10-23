package store

// Capacity is part of the subscription plan catalog, separate from its prices.
// No vendor multipliers ship here. An operator must register comparable work
// units with evidence; dollars and notional API tokens are never capacity.
import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
)

type PlanCapacityWindow struct {
	Minutes int64   `json:"minutes"`
	Units   float64 `json:"units"`
	Source  string  `json:"source,omitempty"`
}

type PlanCapacityProfile struct {
	Plan          string               `json:"plan"`
	Tier          string               `json:"tier"`
	Pool          string               `json:"pool"`
	Unit          string               `json:"unit"`
	Basis         string               `json:"basis"`
	Source        string               `json:"source"`
	Version       string               `json:"version"`
	Confidence    string               `json:"confidence"`
	EffectiveFrom time.Time            `json:"effective_from"`
	EffectiveTo   *time.Time           `json:"effective_to,omitempty"`
	Windows       []PlanCapacityWindow `json:"windows"`
}

type PlanCapacityCatalog struct {
	Mode     string                `json:"mode"` // off, shadow (preview only), active
	Profiles []PlanCapacityProfile `json:"profiles"`
	// Legacy mode/profiles remain exclusively Codex. Omitted provider entries
	// mean off on reads and preserve existing entries on a legacy PUT.
	Providers map[string]ProviderCapacityCatalog `json:"providers,omitempty"`
}

type ProviderCapacityCatalog struct {
	Mode     string                `json:"mode"`
	Profiles []PlanCapacityProfile `json:"profiles"`
}

func (c PlanCapacityCatalog) Provider(provider string) ProviderCapacityCatalog {
	if provider == "codex" {
		return ProviderCapacityCatalog{Mode: c.Mode, Profiles: c.Profiles}
	}
	if p, ok := c.Providers[provider]; ok {
		return p
	}
	return ProviderCapacityCatalog{Mode: "off", Profiles: []PlanCapacityProfile{}}
}

type PlanCapacityRevision struct {
	Revision int64               `json:"revision"`
	Catalog  PlanCapacityCatalog `json:"catalog"`
	Actor    string              `json:"actor"`
	At       time.Time           `json:"at"`
}

var capacityName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,95}$`)
var ErrCapacityConflict = errors.New("capacity catalog changed; reload before saving")

func (c PlanCapacityCatalog) Validate() error {
	if c.Mode != "off" && c.Mode != "shadow" && c.Mode != "active" {
		return errors.New("mode must be off, shadow or active")
	}
	for provider, catalog := range c.Providers {
		if provider != "claude" {
			return errors.New("providers supports claude; legacy mode/profiles are Codex")
		}
		if catalog.Mode != "off" && catalog.Mode != "shadow" && catalog.Mode != "active" {
			return errors.New("provider mode must be off, shadow or active")
		}
		if len(catalog.Profiles) > 100 {
			return errors.New("at most 100 provider profiles")
		}
		seen := map[string]bool{}
		for _, p := range catalog.Profiles {
			key := provider + "\x00" + p.Pool + "\x00" + p.Plan + "\x00" + p.Tier
			if p.Pool != "claude" || seen[key] {
				return errors.New("Claude profiles require unique provider/pool/plan/tier")
			}
			seen[key] = true
			// Reuse numeric/evidence validation without relaxing Codex's surface.
			copy := p
			copy.Pool = "codex"
			if err := (PlanCapacityCatalog{Mode: "off", Profiles: []PlanCapacityProfile{copy}}).Validate(); err != nil {
				return err
			}
			five := false
			for _, w := range p.Windows {
				five = five || w.Minutes == 300
				if w.Minutes == 10080 && !capacityText(w.Source, 512) {
					return errors.New("Claude weekly units require separately evidenced window source; 5h Max multipliers do not establish weekly capacity")
				}
			}
			if !five {
				return errors.New("Claude estimates require a 5h baseline; weekly remains a separate eligibility gate")
			}
		}
	}
	if len(c.Profiles) > 100 {
		return errors.New("at most 100 capacity profiles")
	}
	seen := map[string]bool{}
	for _, p := range c.Profiles {
		key := p.Plan + "\x00" + p.Tier
		if !capacityName.MatchString(p.Plan) || (p.Tier != "" && !capacityName.MatchString(p.Tier)) || seen[key] {
			return errors.New("profiles require unique exact plan/tier names")
		}
		seen[key] = true
		// Only the observed general Codex pool is supported. Adding a model pool
		// needs a request-to-pool resolver, not an administrator guessing its size.
		if p.Pool != "codex" || !capacityName.MatchString(p.Unit) || !capacityText(p.Basis, 256) || !capacityText(p.Source, 512) || !capacityName.MatchString(p.Version) {
			return errors.New("profile needs pool codex, unit, basis, source and version")
		}
		if p.Confidence != "verified" && p.Confidence != "provisional" {
			return errors.New("confidence must be verified or provisional")
		}
		if p.EffectiveFrom.IsZero() || (p.EffectiveTo != nil && !p.EffectiveTo.After(p.EffectiveFrom)) {
			return errors.New("effective_from is required; effective_to must be later")
		}
		if len(p.Windows) == 0 || len(p.Windows) > 2 {
			return errors.New("profile needs its actual expected windows")
		}
		windows := map[int64]bool{}
		for _, w := range p.Windows {
			if (w.Minutes != 300 && w.Minutes != 10080) || windows[w.Minutes] {
				return errors.New("expected windows must be unique 300 or 10080 minute windows")
			}
			windows[w.Minutes] = true
			if math.IsNaN(w.Units) || math.IsInf(w.Units, 0) || w.Units < 0.000001 || w.Units > 1e9 {
				return errors.New("capacity units must be finite and between 0.000001 and 1000000000")
			}
		}
	}
	return nil
}

func capacityText(v string, max int) bool {
	return strings.TrimSpace(v) == v && len(v) > 0 && len(v) <= max && !strings.ContainsAny(v, "\r\n\x00")
}

// The head is revision-CAS protected. History and actor are written in the same
// transaction, including clears and rollbacks. Readers use the shared writer DB
// so replicas see a committed config, never a per-process routing override.
func (s *Store) PlanCapacities() (PlanCapacityRevision, error) {
	out := PlanCapacityRevision{Catalog: PlanCapacityCatalog{Mode: "off", Profiles: []PlanCapacityProfile{}}}
	var doc, at string
	err := s.write.QueryRow(`SELECT h.revision, r.document, r.actor, r.at FROM subscription_capacity_head h JOIN subscription_capacity_revisions r ON r.revision=h.revision WHERE h.id=1`).Scan(&out.Revision, &doc, &out.Actor, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	if err = json.Unmarshal([]byte(doc), &out.Catalog); err != nil {
		return out, err
	}
	if err = out.Catalog.Validate(); err != nil {
		return out, err
	}
	out.At, err = time.Parse(time.RFC3339Nano, at)
	return out, err
}

func (s *Store) SetPlanCapacities(c PlanCapacityCatalog, expected int64, actor string, at time.Time) (PlanCapacityRevision, error) {
	if err := c.Validate(); err != nil {
		return PlanCapacityRevision{}, err
	}
	if expected < 0 || expected > 1e12 || !capacityText(actor, 256) {
		return PlanCapacityRevision{}, errors.New("invalid revision or actor")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return PlanCapacityRevision{}, err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`INSERT INTO subscription_capacity_head(id,revision) VALUES(1,0) ON CONFLICT(id) DO NOTHING`); err != nil {
		return PlanCapacityRevision{}, err
	}
	res, err := tx.Exec(`UPDATE subscription_capacity_head SET revision=? WHERE id=1 AND revision=?`, expected+1, expected)
	if err != nil {
		return PlanCapacityRevision{}, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return PlanCapacityRevision{}, err
	}
	if n != 1 {
		return PlanCapacityRevision{}, ErrCapacityConflict
	}
	// A legacy client only knows mode/profiles. Merge provider keys while
	// holding the same revision CAS; omission can never erase Claude config.
	var priorDoc string
	if err := tx.QueryRow(`SELECT document FROM subscription_capacity_revisions WHERE revision=?`, expected).Scan(&priorDoc); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return PlanCapacityRevision{}, err
	}
	if priorDoc != "" {
		var prior PlanCapacityCatalog
		if err := json.Unmarshal([]byte(priorDoc), &prior); err != nil {
			return PlanCapacityRevision{}, err
		}
		if c.Providers == nil && len(prior.Providers) > 0 {
			c.Providers = map[string]ProviderCapacityCatalog{}
		}
		for provider, value := range prior.Providers {
			if _, present := c.Providers[provider]; !present {
				c.Providers[provider] = value
			}
		}
	}
	doc, err := json.Marshal(c)
	if err != nil {
		return PlanCapacityRevision{}, err
	}
	if _, err = tx.Exec(`INSERT INTO subscription_capacity_revisions(revision,document,actor,at) VALUES(?,?,?,?)`, expected+1, string(doc), actor, at.UTC().Format(time.RFC3339Nano)); err != nil {
		return PlanCapacityRevision{}, err
	}
	if err = tx.Commit(); err != nil {
		return PlanCapacityRevision{}, fmt.Errorf("commit capacity catalog: %w", err)
	}
	return PlanCapacityRevision{Revision: expected + 1, Catalog: c, Actor: actor, At: at.UTC()}, nil
}

func (s *Store) PlanCapacityHistory() ([]PlanCapacityRevision, error) {
	rows, err := s.write.Query(`SELECT revision,document,actor,at FROM subscription_capacity_revisions ORDER BY revision DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PlanCapacityRevision{}
	for rows.Next() {
		var r PlanCapacityRevision
		var doc, at string
		if err := rows.Scan(&r.Revision, &doc, &r.Actor, &at); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(doc), &r.Catalog); err != nil {
			return nil, err
		}
		r.At, err = time.Parse(time.RFC3339Nano, at)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// CodexLiveBindLoads counts distinct workers with unexpired, unrevoked passes,
// excluding the evaluated worker. This is a session reservation measurement,
// not a claim about in-flight requests, CPU load or measured token throughput.
func (s *Store) CodexLiveBindLoads(exclude string, now time.Time) (map[string]int, error) {
	rows, err := s.write.Query(`SELECT b.owner,b.account,COUNT(DISTINCT b.worker_id)
 FROM fleet_session_binds b JOIN fleet_session_creds c ON c.worker_id=b.worker_id
 WHERE b.provider='codex' AND b.worker_id<>? AND c.revoked_at IS NULL AND c.expires_at>? AND (',' || c.providers || ',') LIKE '%,codex,%'
 GROUP BY b.owner,b.account`, exclude, now.UTC().Format(sessRFC))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var owner, account string
		var n int
		if err := rows.Scan(&owner, &account, &n); err != nil {
			return nil, err
		}
		out[owner+"\x00"+account] = n
	}
	return out, rows.Err()
}
