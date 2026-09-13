// internal/api/history.go
package api

import (
	"fmt"
	"sort"
	"strconv"

	"github.com/verkyyi/ccquota/internal/store"
)

// Series is one bucket of a time series, optionally stacked by model.
type Series struct {
	Key    string `json:"key"`
	Events int64  `json:"events"`
	Tokens int64  `json:"tokens"`

	// Cost stays split all the way through the fold. Folding hours into days
	// is where a per-source split is easiest to lose -- the arithmetic is
	// "+=" and a float64 would have accepted every source into one accumulator
	// without complaint.
	Cost      store.CostBySource `json:"cost"`
	Unpriced  int64              `json:"unpriced_events"`
	Sidechain int64              `json:"sidechain_tokens"`
	Stack     []store.Bucket     `json:"stack,omitempty"`
}

// bucketKey maps an hour key 'YYYY-MM-DDTHH:00:00Z' to the bucket it falls in.
func bucketKey(hour, g string) (string, error) {
	if len(hour) < 13 {
		return "", fmt.Errorf("bad hour key %q", hour)
	}
	switch g {
	case "hour":
		return hour[:13] + ":00", nil
	case "6h":
		h, err := strconv.Atoi(hour[11:13])
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%sT%02d", hour[:10], (h/6)*6), nil
	case "day":
		return hour[:10], nil
	}
	return "", fmt.Errorf("unknown granularity %q (want hour, 6h or day)", g)
}

// topModels ranks models by tokens, most first.
func topModels(rows []store.HourRow, n int) []string {
	tot := map[string]int64{}
	for _, r := range rows {
		tot[r.Model] += r.Tokens
	}
	names := make([]string, 0, len(tot))
	for m := range tot {
		names = append(names, m)
	}
	sort.Slice(names, func(i, j int) bool {
		if tot[names[i]] != tot[names[j]] {
			return tot[names[i]] > tot[names[j]]
		}
		return names[i] < names[j]
	})
	if len(names) > n {
		names = names[:n]
	}
	return names
}

// FoldHours sums hourly rows into buckets of granularity g ("hour", "6h" or
// "day"), oldest first. With stack, every bucket carries one entry per model
// in top plus "other", in that order and zero-filled, so a client can draw
// the stack without joining.
//
// Exported so internal/mcp's usage_history can fold the SAME way
// /v1/history's handleHistory does, rather than maintaining a second
// hand-written fold of this bucketing arithmetic that could silently drift
// from it -- see the 2026-09-02 pre-deploy review of commit 1ff1bfc, which
// introduced (and this replaced) exactly that second implementation.
func FoldHours(rows []store.HourRow, g string, stack bool, top []string) ([]Series, error) {
	if _, err := bucketKey("2000-01-01T00:00:00Z", g); err != nil {
		return nil, err
	}
	idx := map[string]int{}
	var out []Series
	pos := map[string]int{}
	for i, m := range top {
		pos[m] = i
	}
	for _, r := range rows {
		k, err := bucketKey(r.Hour, g)
		if err != nil {
			return nil, err
		}
		i, ok := idx[k]
		if !ok {
			i = len(out)
			idx[k] = i
			s := Series{Key: k}
			if stack {
				for _, m := range top {
					s.Stack = append(s.Stack, store.Bucket{Key: m})
				}
				s.Stack = append(s.Stack, store.Bucket{Key: "other"})
			}
			out = append(out, s)
		}
		s := &out[i]
		s.Events += r.Events
		s.Tokens += r.Tokens
		s.Cost.Add(r.Cost)
		s.Unpriced += r.Unpriced
		s.Sidechain += r.Sidechain
		if stack {
			j, ok := pos[r.Model]
			if !ok {
				j = len(top)
			}
			s.Stack[j].Tokens += r.Tokens
			s.Stack[j].Events += r.Events
			s.Stack[j].Cost.Add(r.Cost)
			s.Stack[j].Unpriced = s.Stack[j].Cost.Unpriced()
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
