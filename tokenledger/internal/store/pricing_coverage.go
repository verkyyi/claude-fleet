package store

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
)

type UnpricedReason struct {
	Source string `json:"source"`
	Model  string `json:"model"`
	Reason string `json:"reason"`
	Events int64  `json:"events"`

	// Code names WHICH reason this is, so a surface can restate it in another
	// language without matching on the English sentence. Unserialised: the
	// wire contract is still the prose, and a second field saying the same
	// thing in two forms is one more thing to keep in step.
	//
	// It is NOT the price_basis it was derived from. That string is written at
	// ingest and is an audit record of which rate priced the event; these codes
	// are a presentation concern and several basis strings map onto one.
	Code string `json:"-"`
}

// SummaryWithPricing reads totals and their explanation in one SQLite
// snapshot. Pruned raw details remain in the denominator through the rollup.
func (s *Store) SummaryWithPricing(f Filter) (*Summary, []UnpricedReason, error) {
	f = f.AlignHours()
	tx, err := s.read.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback()
	sum, err := readSummary(tx, f)
	if err != nil {
		return nil, nil, err
	}
	out := []UnpricedReason{}
	if sum.Unpriced == 0 {
		return sum, out, nil
	}
	where, args, err := f.where("ts")
	if err != nil {
		return nil, nil, err
	}
	rows, err := tx.Query(`SELECT source,model,COALESCE(json_extract(details_json,'$.price_basis'),''),COUNT(*) FROM usage_events `+where+` AND cost_usd IS NULL GROUP BY source,model,3`, args...)
	if err != nil {
		return nil, nil, err
	}
	known := map[string]int64{}
	for rows.Next() {
		var r UnpricedReason
		var basis string
		if err := rows.Scan(&r.Source, &r.Model, &basis, &r.Events); err != nil {
			rows.Close()
			return nil, nil, err
		}
		switch basis {
		case "unpriced: cache-write breakdown unavailable":
			r.Code = UnpricedCacheWriteUnavailable
		case "unpriced: unsupported cache-write breakdown":
			r.Code = UnpricedCacheWriteUnsupported
		case "unpriced: unknown provider or model":
			r.Code = UnpricedUnknownModel
		case "unpriced: legacy Fast rate not verified":
			r.Code = UnpricedLegacyFast
		case "unpriced: unsupported service tier", "unpriced: unknown service tier":
			r.Code = UnpricedServiceTier
		case "unpriced: no gateway rate configured":
			r.Code = UnpricedNoGatewayRate
		case "unpriced: gateway rates cover input and output only":
			r.Code = UnpricedGatewayCacheToken
		case "unpriced: no usable CNY/USD rate":
			r.Code = UnpricedGatewayFX
		case "unpriced: implausible token counts":
			r.Code = UnpricedImplausibleTokens
		default:
			r.Code = UnpricedNoPriceData
		}
		r.Reason = UnpricedReasonIn(r.Code, "en")
		out = append(out, r)
		known[r.Source+"\x00"+r.Model] += r.Events
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, nil, err
	}
	rows.Close()
	where, args, err = f.where("hour")
	if err != nil {
		return nil, nil, err
	}
	rows, err = tx.Query(`SELECT source,model,SUM(unpriced_events) FROM usage_hourly `+where+` GROUP BY source,model HAVING SUM(unpriced_events)>0`, args...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var r UnpricedReason
		if err := rows.Scan(&r.Source, &r.Model, &r.Events); err != nil {
			return nil, nil, err
		}
		r.Events -= known[r.Source+"\x00"+r.Model]
		if r.Events < 0 {
			return nil, nil, fmt.Errorf("pricing detail count exceeds rollup")
		}
		if r.Events > 0 {
			r.Code = UnpricedPruned
			r.Reason = UnpricedReasonIn(r.Code, "en")
			out = append(out, r)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Events != out[j].Events {
			return out[i].Events > out[j].Events
		}
		if out[i].Source != out[j].Source {
			return out[i].Source < out[j].Source
		}
		if out[i].Model != out[j].Model {
			return out[i].Model < out[j].Model
		}
		return out[i].Reason < out[j].Reason
	})
	return sum, out, nil
}
