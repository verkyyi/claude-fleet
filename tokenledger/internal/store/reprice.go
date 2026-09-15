// internal/store/reprice.go — applying today's rate table to events already stored.
package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// Pricer is the part of the rate table that repricing needs.
//
// An interface, so this package keeps not importing internal/pricing: a rate is
// policy, and this package is storage. More importantly it means repricing runs
// the SAME function ingest runs (pricing.Table.Apply) instead of a second
// implementation of the pricing rules — a parallel copy would drift, and the
// drift would show up as two different prices for one event with nothing to say
// which was right.
type Pricer interface {
	Apply([]model.UsageEvent)
}

// RepriceResult says what a reprice did, in the terms an operator checks.
//
// Changed is deliberately not the same as NewlyPriced + Unpriced: a figure can
// move without crossing between priced and unpriced, which is what a corrected
// rate does to every event it touches.
type RepriceResult struct {
	Scanned     int64
	Changed     int64
	NewlyPriced int64 // had no figure, now has one
	Unpriced    int64 // had a figure, now has none (a rate was removed)
	RollupRows  int64

	// NetUSD is how much the total moved: the sum of every change, treating an
	// absent figure as nothing. MaxAbsUSD is the largest single move.
	//
	// Both exist because Changed is a row count, and a row count cannot tell a
	// correction from a catastrophe: 25k figures that shifted in the last bits of
	// a float and 25k figures that doubled report the identical number.
	//
	// Measured against a snapshot of production (443,452 events, 2026-09-13):
	// Changed was 24,926 of which only 38 were newly priced, NetUSD was +0.007194
	// — matching, to six decimals, a gateway-only delta measured independently
	// from the API — and MaxAbsUSD was 0.000589, itself one of those 38. So the
	// other 24,888 rows moved by amounts too small to reach any total: they are
	// events stored by an older build whose arithmetic rounded a hair differently,
	// not money changing hands. An operator seeing only "changed 24,926" against a
	// real ledger would reasonably stop the rollout; with the net and the maximum
	// beside it, the same run reads as the few-cent correction it is.
	//
	// Deliberately NOT a threshold that hides small changes: the row still gets
	// written, because stored figures should be what the current table computes.
	// These two numbers report honestly instead of deciding what counts as real.
	NetUSD    float64
	MaxAbsUSD float64
}

// repriceBatch bounds how many events are held in memory at once. The whole
// operation is still one transaction — this only caps the working set, because
// a hub with 400k+ events should not need 400k events' worth of RAM to apply a
// rate correction.
const repriceBatch = 5000

// repriceColumns are the event fields any pricing path reads.
//
// Not the whole row: the columns a rate can depend on are the tokens, the model,
// the provider, the timestamp and the details. If that ever stops being true —
// a rate keyed on something not listed here — TestReprice_IsANoOpOnFreshlyPricedEvents
// goes red, because reprice would then compute a different figure than ingest
// did from the same row. That test is the real guard; this list is just what it
// guards.
const repriceColumns = `id, source, model, provider, ts, input_tokens, output_tokens,
	  cache_create_5m_tokens, cache_create_1h_tokens, cache_read_tokens, cost_usd, details_json`

// Reprice recomputes cost_usd, and the price basis beside it, for stored events
// using the rate table as it stands now — then refolds the rollup so every
// aggregate agrees with the rows underneath it.
//
// It exists because pricing happens at ingest. A rate added today reaches only
// the events that arrive after it, so an operator who fills in a contract they
// could not state last month has no way to price the month they already have:
// the figures stay unpriced forever, and "unpriced" is indistinguishable from
// "free" in every total that skips it. --rebuild-rollup does not help — it
// refolds the per-event figures already stored, so it rebuilds exactly the same
// stale money.
//
// since bounds the work to events at or after that instant; the zero time means
// every event. Supplied-cost sources are checked, never rewritten — see the
// guard below.
func (s *Store) Reprice(p Pricer, since time.Time) (RepriceResult, error) {
	var out RepriceResult
	tx, err := s.write.Begin()
	if err != nil {
		return out, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()

	upd, err := tx.Prepare(`UPDATE usage_events SET cost_usd = ?, details_json = ? WHERE id = ?`)
	if err != nil {
		return out, fmt.Errorf("prepare update: %w", err)
	}
	defer upd.Close()

	sinceArg := "" // every event
	if !since.IsZero() {
		sinceArg = since.UTC().Format(time.RFC3339)
	}

	var lastID int64
	for {
		batch, ids, raw, err := readRepriceBatch(tx, lastID, sinceArg)
		if err != nil {
			return out, err
		}
		if len(batch) == 0 {
			break
		}
		lastID = ids[len(ids)-1]
		out.Scanned += int64(len(batch))

		before := make([]*float64, len(batch))
		for i := range batch {
			before[i] = batch[i].CostUSD
		}
		p.Apply(batch)

		for i := range batch {
			old, now := before[i], batch[i].CostUSD

			// ── THE GUARD ────────────────────────────────────────────────
			// A supplied figure is an invoice, not a derivation: no rate table
			// could reproduce it, and repricing must never be the thing that
			// edits one. Today the pricing functions for these sources return
			// the event's own CostUSD, so this holds by construction — which is
			// exactly why it is asserted rather than assumed. If a later change
			// makes one of them derive a number, the failure mode without this
			// check is silent and unrecoverable: an invoice overwritten by an
			// estimate, in the ledger whose whole job is to be the real one.
			if model.CostIsSupplied(batch[i].Source) && !sameCost(old, now) {
				return out, fmt.Errorf(
					"refusing to reprice: source %q carries a supplied cost that must not be recomputed, "+
						"but repricing event id %d (%s) moved it from %s to %s — "+
						"a rate table has started deriving a figure that is an invoice",
					batch[i].Source, ids[i], batch[i].MessageUUID, fmtCost(old), fmtCost(now))
			}

			details := raw[i]
			if batch[i].Details != nil {
				b, err := json.Marshal(batch[i].Details)
				if err != nil {
					return out, fmt.Errorf("marshal details for event id %d: %w", ids[i], err)
				}
				details = string(b)
			}
			if sameCost(old, now) && details == raw[i] {
				continue
			}
			if _, err := upd.Exec(now, details, ids[i]); err != nil {
				return out, fmt.Errorf("update event id %d: %w", ids[i], err)
			}
			if !sameCost(old, now) {
				d := deref(now) - deref(old)
				out.Changed++
				out.NetUSD += d
				if math.Abs(d) > out.MaxAbsUSD {
					out.MaxAbsUSD = math.Abs(d)
				}
				switch {
				case old == nil && now != nil:
					out.NewlyPriced++
				case old != nil && now == nil:
					out.Unpriced++
				}
			}
		}
		if len(batch) < repriceBatch {
			break
		}
	}

	// Refold in the same transaction. force is true because scoping is not this
	// operation's decision to make: rebuildRollupTx never touches hours the raw
	// events can no longer reconstruct, and refusing the whole reprice over
	// hours it was never going to rewrite would block a rate correction for a
	// reason that does not apply to it.
	rows, err := rebuildRollupTx(tx, true)
	if err != nil {
		return out, fmt.Errorf("refold rollup after reprice: %w", err)
	}
	out.RollupRows = rows

	if err := tx.Commit(); err != nil {
		return out, fmt.Errorf("commit: %w", err)
	}
	return out, nil
}

// readRepriceBatch reads the next page of events, fully, before anything is
// written. Returns the events, their row ids, and their details_json exactly as
// stored — the raw copy is what decides whether a row needs writing at all.
//
// Read-then-write rather than writing while a cursor is open: the same
// transaction is doing both, and a statement still streaming rows from a table
// being updated underneath it is not a position worth being in.
func readRepriceBatch(tx *sql.Tx, afterID int64, since string) ([]model.UsageEvent, []int64, []string, error) {
	q := `SELECT ` + repriceColumns + ` FROM usage_events WHERE id > ?`
	args := []any{afterID}
	if since != "" {
		q += ` AND ts >= ?`
		args = append(args, since)
	}
	q += ` ORDER BY id LIMIT ?`
	args = append(args, repriceBatch)

	rows, err := tx.Query(q, args...)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("read events to reprice: %w", err)
	}
	defer rows.Close()

	var (
		evs []model.UsageEvent
		ids []int64
		raw []string
	)
	for rows.Next() {
		var (
			id      int64
			e       model.UsageEvent
			ts      string
			cost    sql.NullFloat64
			details string
		)
		if err := rows.Scan(&id, &e.Source, &e.Model, &e.Provider, &ts,
			&e.InputTokens, &e.OutputTokens, &e.CacheCreate5m, &e.CacheCreate1h,
			&e.CacheRead, &cost, &details); err != nil {
			return nil, nil, nil, fmt.Errorf("scan event to reprice: %w", err)
		}
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			e.TS = t
		}
		if cost.Valid {
			c := cost.Float64
			e.CostUSD = &c
		}
		// Preserve whether the row HAS details. A row stored without them must
		// not acquire an empty set here: gateway and Codex pricing return
		// unpriced when Details is nil, so inventing one would make reprice
		// compute a figure ingest would not have — a different answer to the
		// same question, from the same data.
		if details != "" && details != "null" {
			var d model.UsageDetails
			if err := json.Unmarshal([]byte(details), &d); err != nil {
				return nil, nil, nil, fmt.Errorf("parse details_json for event id %d: %w", id, err)
			}
			e.Details = &d
		}
		evs = append(evs, e)
		ids = append(ids, id)
		raw = append(raw, details)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, nil, fmt.Errorf("read events to reprice: %w", err)
	}
	return evs, ids, raw, nil
}

// sameCost compares two optional figures, absence included. Exact comparison is
// the point: a reprice that produces the same rate's arithmetic on the same
// tokens must land on the same bits, and anything else is a change worth
// reporting.
func sameCost(a, b *float64) bool {
	switch {
	case a == nil && b == nil:
		return true
	case a == nil || b == nil:
		return false
	}
	return *a == *b
}

// deref reads an optional figure as a number, absent counting as nothing. Only
// for totalling a delta: everywhere else the difference between "no figure" and
// "zero" is the whole point, which is why this is not a general helper.
func deref(c *float64) float64 {
	if c == nil {
		return 0
	}
	return *c
}

func fmtCost(c *float64) string {
	if c == nil {
		return "unpriced"
	}
	return fmt.Sprintf("%.6f", *c)
}
