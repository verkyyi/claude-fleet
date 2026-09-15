// internal/store/growth.go
package store

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// GrowthRow is one stored day of the business ledger.
type GrowthRow struct {
	model.GrowthSnapshot
	// ReceivedAt is when the hub took the push — the answer to "did tonight's
	// job run?", which Day cannot give because a shipper may file any day.
	ReceivedAt time.Time `json:"received_at"`
}

// UpsertGrowthFacts stores one day of the business ledger.
//
// A whole-document upsert keyed by (source, day): every column is replaced,
// including the ones this push happens to leave at zero. Merging field by
// field would be worse than useless here — a figure that dropped out of the
// shipper's query would keep its old value forever while the row's timestamp
// went on advancing, which is a stale number wearing a fresh date.
//
// Last write wins, with no guard on received_at. The contract carries no
// observation timestamp, so the hub genuinely cannot tell a late retry from a
// correction, and a guard built on the hub's own clock would only pretend to.
func (s *Store) UpsertGrowthFacts(snap model.GrowthSnapshot, receivedAt time.Time) error {
	_, err := s.write.Exec(`
		INSERT INTO growth_facts
		  (source, day,
		   h5_arr_cny, h5_expiring_in_window_cny, h5_expiring_accounts,
		   h5_churned_accounts, h5_active_accounts,
		   ai_signed_deals, ai_qualified_leads, ai_arr_cny, ai_updated_at,
		   okr_focus, okr_quarter, okr_target_annualized, okr_days_to_kill_switch,
		   received_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(source, day) DO UPDATE SET
		  h5_arr_cny = excluded.h5_arr_cny,
		  h5_expiring_in_window_cny = excluded.h5_expiring_in_window_cny,
		  h5_expiring_accounts = excluded.h5_expiring_accounts,
		  h5_churned_accounts = excluded.h5_churned_accounts,
		  h5_active_accounts = excluded.h5_active_accounts,
		  ai_signed_deals = excluded.ai_signed_deals,
		  ai_qualified_leads = excluded.ai_qualified_leads,
		  ai_arr_cny = excluded.ai_arr_cny,
		  ai_updated_at = excluded.ai_updated_at,
		  okr_focus = excluded.okr_focus,
		  okr_quarter = excluded.okr_quarter,
		  okr_target_annualized = excluded.okr_target_annualized,
		  okr_days_to_kill_switch = excluded.okr_days_to_kill_switch,
		  received_at = excluded.received_at`,
		snap.Source, snap.Day,
		snap.H5.ARRCNY, snap.H5.ExpiringInWindowCNY, snap.H5.ExpiringAccounts,
		snap.H5.ChurnedAccounts, snap.H5.ActiveAccounts,
		snap.AI.SignedDeals, snap.AI.QualifiedLeads, snap.AI.ARRCNY, fmtTime(snap.AI.UpdatedAt),
		snap.OKR.Focus, snap.OKR.Quarter, snap.OKR.TargetAnnualized, snap.OKR.DaysToKillSwitch,
		fmtTime(receivedAt))
	if err != nil {
		return fmt.Errorf("upsert growth facts %s/%s: %w", snap.Source, snap.Day, err)
	}
	return nil
}

// LatestGrowth returns the most recent day the hub holds, or nil when no
// shipper has ever pushed one.
//
// Nil is a real answer: a hub nobody pointed a growth shipper at is a working
// hub, and the board has to say "nothing has been shipped" rather than draw an
// empty ledger that reads like a business with no revenue.
//
// The newest DAY wins, and ties break on the newest push. Two shippers are not
// blended — each row names its own source, and mixing two teams' books into
// one line is the mistake the source key exists to prevent.
func (s *Store) LatestGrowth() (*GrowthRow, error) {
	var (
		r       GrowthRow
		updated string
		recv    string
	)
	err := s.read.QueryRow(`
		SELECT source, day,
		       h5_arr_cny, h5_expiring_in_window_cny, h5_expiring_accounts,
		       h5_churned_accounts, h5_active_accounts,
		       ai_signed_deals, ai_qualified_leads, ai_arr_cny, ai_updated_at,
		       okr_focus, okr_quarter, okr_target_annualized, okr_days_to_kill_switch,
		       received_at
		FROM growth_facts
		ORDER BY day DESC, received_at DESC
		LIMIT 1`).
		Scan(&r.Source, &r.Day,
			&r.H5.ARRCNY, &r.H5.ExpiringInWindowCNY, &r.H5.ExpiringAccounts,
			&r.H5.ChurnedAccounts, &r.H5.ActiveAccounts,
			&r.AI.SignedDeals, &r.AI.QualifiedLeads, &r.AI.ARRCNY, &updated,
			&r.OKR.Focus, &r.OKR.Quarter, &r.OKR.TargetAnnualized, &r.OKR.DaysToKillSwitch,
			&recv)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("latest growth: %w", err)
	}
	r.AI.UpdatedAt, _ = time.Parse(rfc, updated)
	r.ReceivedAt, _ = time.Parse(rfc, recv)
	return &r, nil
}
