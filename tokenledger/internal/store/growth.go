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
// A BLOCK-level upsert keyed by (source, day): a block the push carries
// replaces that block wholly, and a block it omits is left exactly as it was.
//
// Not field by field, and the distinction is the whole design. Within a block,
// every column is replaced — a figure that dropped out of the shipper's query
// must not keep its old value while the row's timestamp advances, which is a
// stale number wearing a fresh date. Between blocks, absence means "I have
// nothing to say about this one": the queried half and the hand-filled half
// have different authors and different clocks, and making one of them
// overwrite the other with zeros is how "nobody has updated this lately"
// becomes "somebody confirmed it is 0".
//
// Last write wins, with no guard on received_at. The contract carries no
// observation timestamp, so the hub genuinely cannot tell a late retry from a
// correction, and a guard built on the hub's own clock would only pretend to.
func (s *Store) UpsertGrowthFacts(push model.GrowthPush, receivedAt time.Time) error {
	h5, ai, okr := push.H5, push.AI, push.OKR
	if h5 == nil {
		h5 = &model.GrowthH5{}
	}
	if ai == nil {
		ai = &model.GrowthAI{}
	}
	if okr == nil {
		okr = &model.GrowthOKR{}
	}
	// The presence flags drive the CASE arms below. Done in one statement
	// rather than read-then-write on purpose: two shippers filing the same day
	// (one the queried half, one the hand-filled half) would otherwise be a
	// lost update whenever their pushes interleaved -- and a lost update here
	// is a figure quietly reverting to last week's while the row's timestamp
	// goes on advancing.
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
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
		  h5_arr_cny                = CASE WHEN :h5 THEN excluded.h5_arr_cny                ELSE growth_facts.h5_arr_cny                END,
		  h5_expiring_in_window_cny = CASE WHEN :h5 THEN excluded.h5_expiring_in_window_cny ELSE growth_facts.h5_expiring_in_window_cny END,
		  h5_expiring_accounts      = CASE WHEN :h5 THEN excluded.h5_expiring_accounts      ELSE growth_facts.h5_expiring_accounts      END,
		  h5_churned_accounts       = CASE WHEN :h5 THEN excluded.h5_churned_accounts       ELSE growth_facts.h5_churned_accounts       END,
		  h5_active_accounts        = CASE WHEN :h5 THEN excluded.h5_active_accounts        ELSE growth_facts.h5_active_accounts        END,
		  ai_signed_deals           = CASE WHEN :ai THEN excluded.ai_signed_deals           ELSE growth_facts.ai_signed_deals           END,
		  ai_qualified_leads        = CASE WHEN :ai THEN excluded.ai_qualified_leads        ELSE growth_facts.ai_qualified_leads        END,
		  ai_arr_cny                = CASE WHEN :ai THEN excluded.ai_arr_cny                ELSE growth_facts.ai_arr_cny                END,
		  ai_updated_at             = CASE WHEN :ai THEN excluded.ai_updated_at             ELSE growth_facts.ai_updated_at             END,
		  okr_focus                 = CASE WHEN :okr THEN excluded.okr_focus                 ELSE growth_facts.okr_focus                 END,
		  okr_quarter               = CASE WHEN :okr THEN excluded.okr_quarter               ELSE growth_facts.okr_quarter               END,
		  okr_target_annualized     = CASE WHEN :okr THEN excluded.okr_target_annualized     ELSE growth_facts.okr_target_annualized     END,
		  okr_days_to_kill_switch   = CASE WHEN :okr THEN excluded.okr_days_to_kill_switch   ELSE growth_facts.okr_days_to_kill_switch   END,
		  received_at = excluded.received_at`,
		push.Source, push.Day,
		h5.ARRCNY, h5.ExpiringInWindowCNY, h5.ExpiringAccounts,
		h5.ChurnedAccounts, h5.ActiveAccounts,
		ai.SignedDeals, ai.QualifiedLeads, ai.ARRCNY, fmtTime(ai.UpdatedAt),
		okr.Focus, okr.Quarter, okr.TargetAnnualized, okr.DaysToKillSwitch,
		fmtTime(receivedAt),
		sql.Named("h5", b(push.H5 != nil)),
		sql.Named("ai", b(push.AI != nil)),
		sql.Named("okr", b(push.OKR != nil)))
	if err != nil {
		return fmt.Errorf("upsert growth facts %s/%s: %w", push.Source, push.Day, err)
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
