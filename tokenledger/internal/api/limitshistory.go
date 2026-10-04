// internal/api/limitshistory.go
package api

import (
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

const criticalPct = 90.0

// maxCriticalGap caps how much time one snapshot can vouch for. Agents poll
// every two minutes; a gap far longer than that is an outage, not ten hours
// of critical.
const maxCriticalGap = 600 * time.Second

// LimitSeries is one subscription's utilization over a period.
type LimitSeries struct {
	AccountUUID         string             `json:"account_uuid"`
	Label               string             `json:"label"`
	Points              []store.LimitPoint `json:"points"`
	CriticalSeconds     int64              `json:"critical_seconds"`
	PrevCriticalSeconds int64              `json:"prev_critical_seconds"`
	CriticalEpisodes    int                `json:"critical_episodes"`
}

// criticalTime sums the time spent at or above criticalPct on the 5-hour
// window, and counts entries into that state.
func criticalTime(pts []store.LimitPoint) (int64, int) {
	var secs time.Duration
	episodes := 0
	in := false
	for i, p := range pts {
		hot := p.FiveHour >= criticalPct
		if hot && !in {
			episodes++
		}
		in = hot
		if hot && i+1 < len(pts) {
			gap := pts[i+1].T.Sub(p.T)
			if gap > maxCriticalGap {
				gap = maxCriticalGap
			}
			if gap > 0 {
				secs += gap
			}
		}
	}
	return int64(secs / time.Second), episodes
}

// downsample keeps at most n points: the range is cut into n slots and the
// point with the highest 5-hour reading in each slot survives, so a spike is
// never averaged away.
func downsample(pts []store.LimitPoint, start, end time.Time, n int) []store.LimitPoint {
	if n <= 0 || len(pts) <= n {
		return pts
	}
	slot := end.Sub(start) / time.Duration(n)
	if slot <= 0 {
		return pts
	}
	best := make([]*store.LimitPoint, n)
	for i := range pts {
		k := int(pts[i].T.Sub(start) / slot)
		if k < 0 {
			k = 0
		}
		if k >= n {
			k = n - 1
		}
		if best[k] == nil || pts[i].FiveHour > best[k].FiveHour {
			best[k] = &pts[i]
		}
	}
	out := make([]store.LimitPoint, 0, n)
	for _, b := range best {
		if b != nil {
			out = append(out, *b)
		}
	}
	return out
}
