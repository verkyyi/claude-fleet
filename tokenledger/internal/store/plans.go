package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// DefaultCurrency is assumed when a price is recorded without one. It is a
// label, never a conversion: this package does no FX, so a hub holding plans
// in two currencies reports two totals rather than one wrong one.
const DefaultCurrency = "USD"

// averageMonth is a calendar month averaged over the Gregorian cycle
// (365.2425/12 days). Subscription prices are quoted per month and reporting
// periods are not months, so some conversion is unavoidable; this one is at
// least stable, whereas "30 days" drifts a week per year.
const averageMonth = time.Duration(365.2425 / 12 * 24 * float64(time.Hour))

// SetPlanPrice records what a plan costs from a moment onward.
//
// Appends, it does not overwrite: the open row for this plan is closed at the
// new price's start and the new price is inserted after it, so history stays
// priced at what it actually cost. Re-recording an existing start date is the
// one in-place edit allowed — that is a correction to a figure, not a price
// change — and a date BEHIND the newest row is refused rather than silently
// producing overlapping periods that would double-count.
func (s *Store) SetPlanPrice(p model.SubscriptionPlan) error {
	if p.Plan == "" {
		return errors.New("a price needs a plan name (the account's subscription_type)")
	}
	if p.MonthlyCost < 0 {
		return fmt.Errorf("monthly cost for %q is negative (%v)", p.Plan, p.MonthlyCost)
	}
	source := model.UsageSource(p.Source)
	currency := p.Currency
	if currency == "" {
		currency = DefaultCurrency
	}
	from := p.EffectiveFrom.UTC()
	if from.IsZero() {
		return fmt.Errorf("price for %q needs an effective_from: an undated price cannot be applied to a period", p.Plan)
	}

	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var newest sql.NullString
	if err := tx.QueryRow(`SELECT MAX(effective_from) FROM subscription_plans WHERE plan = ? AND source = ?`,
		p.Plan, source).Scan(&newest); err != nil {
		return err
	}
	if newest.Valid {
		latest, err := time.Parse(rfc, newest.String)
		if err != nil {
			return fmt.Errorf("stored effective_from %q for %s/%s is unparseable: %w", newest.String, source, p.Plan, err)
		}
		switch {
		case from.Before(latest):
			return fmt.Errorf(
				"%s/%s already has a price starting %s; effective-dated prices are appended, not inserted behind an existing one",
				source, p.Plan, fmtTime(latest))
		case from.Equal(latest):
			// A correction to the figure for a period already recorded.
			_, err := tx.Exec(`UPDATE subscription_plans SET monthly_cost = ?, currency = ?
				WHERE plan = ? AND source = ? AND effective_from = ?`,
				p.MonthlyCost, currency, p.Plan, source, fmtTime(from))
			if err != nil {
				return err
			}
			return tx.Commit()
		}
	}

	if _, err := tx.Exec(`UPDATE subscription_plans SET effective_to = ?
		WHERE plan = ? AND source = ? AND effective_to IS NULL`,
		fmtTime(from), p.Plan, source); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO subscription_plans
		(plan, source, monthly_cost, currency, effective_from, effective_to) VALUES (?,?,?,?,?,NULL)`,
		p.Plan, source, p.MonthlyCost, currency, fmtTime(from)); err != nil {
		return err
	}
	return tx.Commit()
}

// PlanPriceAt reports what a plan cost at a moment, or nil when nobody has
// said.
//
// nil rather than a zero-cost row, for the same reason UsageEvent.CostUSD is
// nil for an unpriced model: zero is a claim that the plan was free, and a
// subscription silently priced at zero would make every value ratio built on
// it infinite.
func (s *Store) PlanPriceAt(plan, source string, at time.Time) (*model.SubscriptionPlan, error) {
	if plan == "" {
		return nil, nil
	}
	ts := fmtTime(at.UTC())
	row := s.read.QueryRow(`SELECT plan, source, monthly_cost, currency, effective_from, effective_to
		FROM subscription_plans
		WHERE plan = ? AND source = ? AND effective_from <= ?
		  AND (effective_to IS NULL OR effective_to > ?)
		ORDER BY effective_from DESC LIMIT 1`,
		plan, model.UsageSource(source), ts, ts)
	p, err := scanPlan(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// ListPlanPrices returns every recorded price, newest period first. The whole
// history, not just the current row: an operator checking why last quarter's
// figures changed needs to see the price that produced them.
func (s *Store) ListPlanPrices() ([]model.SubscriptionPlan, error) {
	rows, err := s.read.Query(`SELECT plan, source, monthly_cost, currency, effective_from, effective_to
		FROM subscription_plans ORDER BY source, plan, effective_from DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.SubscriptionPlan
	for rows.Next() {
		p, err := scanPlan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// scanner is satisfied by both *sql.Row and *sql.Rows.
type scanner interface{ Scan(...any) error }

func scanPlan(sc scanner) (model.SubscriptionPlan, error) {
	var p model.SubscriptionPlan
	var from string
	var to sql.NullString
	if err := sc.Scan(&p.Plan, &p.Source, &p.MonthlyCost, &p.Currency, &from, &to); err != nil {
		return p, err
	}
	var err error
	if p.EffectiveFrom, err = time.Parse(rfc, from); err != nil {
		return p, fmt.Errorf("effective_from %q for %s/%s: %w", from, p.Source, p.Plan, err)
	}
	if to.Valid {
		t, err := time.Parse(rfc, to.String)
		if err != nil {
			return p, fmt.Errorf("effective_to %q for %s/%s: %w", to.String, p.Source, p.Plan, err)
		}
		p.EffectiveTo = &t
	}
	return p, nil
}

// SubscriptionSpend is what one plan actually cost over a reporting period.
//
// REAL money. It may be added to a metered gateway bill; it must never be
// added to the notional token figure — see the subscription_plans schema
// comment and the guard in plans_test.go.
type SubscriptionSpend struct {
	Plan     string `json:"plan"`
	Source   string `json:"source"`
	Currency string `json:"currency"`

	// Seats is how many accounts on this hub were on the plan during the
	// period, counted at query time rather than stored. A stored count drifts
	// the moment somebody is added, and a drifted count still looks
	// authoritative.
	Seats int64 `json:"seats"`

	// Months is the period's length in average calendar months, summed over
	// however many prices were in effect across it.
	Months float64 `json:"months"`

	// Amount is seats x months x the price in effect for each part of the
	// period. Meaningful only when Priced; zero otherwise, and zero here is
	// not a claim of free — Priced is what says whether the figure exists.
	Amount float64 `json:"amount"`

	// Priced is false when no price covers any part of the period. Such a
	// plan is still reported, so an operator sees the gap rather than a
	// quietly-too-low total.
	Priced bool `json:"priced"`
}

// SubscriptionSpendOver reports real subscription spend per plan over
// [from, to), one row per (source, plan) the scope actually holds accounts for.
//
// account takes a uuid to price ONE subscription, or AllAccounts to price the
// hub. The empty string is refused, matching UsageBy and Filter: this figure is
// real money, and "which subscriptions is this the bill for" is not a question
// a caller may leave to a default.
//
// Every plan with accounts is reported, priced or not. Dropping the unpriced
// ones would hand back a total that is wrong in the one direction nobody
// checks — too low — with nothing on screen to say so.
func (s *Store) SubscriptionSpendOver(account string, from, to time.Time) ([]SubscriptionSpend, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required: pass a uuid, or store.AllAccounts to price every subscription")
	}
	from, to = from.UTC(), to.UTC()
	if !to.After(from) {
		return nil, fmt.Errorf("period must end after it starts: %s..%s", fmtTime(from), fmtTime(to))
	}

	// Which plans this scope holds, and how many accounts were on each during
	// the period. An account counts if its observed lifetime overlaps the
	// period at all: it was being paid for while it was in use.
	where, args := "", []any{fmtTime(to), fmtTime(from)}
	if account != AllAccounts {
		where = " AND account_uuid = ?"
		args = append(args, account)
	}
	rows, err := s.read.Query(`SELECT subscription_type, source, COUNT(*)
		FROM accounts
		WHERE subscription_type <> '' AND first_seen < ? AND last_seen >= ?`+where+`
		GROUP BY subscription_type, source
		ORDER BY source, subscription_type`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SubscriptionSpend
	for rows.Next() {
		var sp SubscriptionSpend
		if err := rows.Scan(&sp.Plan, &sp.Source, &sp.Seats); err != nil {
			return nil, err
		}
		sp.Source = model.UsageSource(sp.Source)
		out = append(out, sp)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for i := range out {
		if err := s.priceOver(&out[i], from, to); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// priceOver fills in the money for one plan by walking every price row that
// overlaps the period, so a period spanning a price change is charged partly
// at each price rather than wholly at one of them.
func (s *Store) priceOver(sp *SubscriptionSpend, from, to time.Time) error {
	rows, err := s.read.Query(`SELECT plan, source, monthly_cost, currency, effective_from, effective_to
		FROM subscription_plans
		WHERE plan = ? AND source = ? AND effective_from < ?
		  AND (effective_to IS NULL OR effective_to > ?)
		ORDER BY effective_from`,
		sp.Plan, sp.Source, fmtTime(to), fmtTime(from))
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		p, err := scanPlan(rows)
		if err != nil {
			return err
		}
		start := p.EffectiveFrom
		if start.Before(from) {
			start = from
		}
		end := to
		if p.EffectiveTo != nil && p.EffectiveTo.Before(end) {
			end = *p.EffectiveTo
		}
		if !end.After(start) {
			continue
		}
		months := end.Sub(start).Seconds() / averageMonth.Seconds()
		if !sp.Priced {
			sp.Priced, sp.Currency = true, p.Currency
		} else if sp.Currency != p.Currency {
			// No FX here, so a plan repriced into another currency cannot be
			// summed. Saying so beats inventing a rate.
			return fmt.Errorf("%s/%s changed currency (%s -> %s) inside the period; "+
				"report the two periods separately", sp.Source, sp.Plan, sp.Currency, p.Currency)
		}
		sp.Months += months
		sp.Amount += p.MonthlyCost * float64(sp.Seats) * months
	}
	return rows.Err()
}
