package api

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

func lp(min int, pct float64) store.LimitPoint {
	return store.LimitPoint{AccountUUID: "a", T: time.Date(2026, 9, 1, 10, min, 0, 0, time.UTC), FiveHour: pct, SevenDay: 1}
}

func TestCriticalTimeCapsGapsAndCountsEpisodes(t *testing.T) {
	pts := []store.LimitPoint{lp(0, 95), lp(2, 96), lp(30, 50), lp(31, 92), lp(33, 10)}
	secs, eps := criticalTime(pts)
	// 0→2 = 120s, 2→30 capped at 600s (a 28-minute polling hole is not 28 minutes of critical),
	// 31→33 = 120s; two episodes.
	if secs != 840 || eps != 2 {
		t.Fatalf("secs=%d eps=%d", secs, eps)
	}
	if s, e := criticalTime(nil); s != 0 || e != 0 {
		t.Fatal("empty")
	}
	if s, e := criticalTime([]store.LimitPoint{lp(0, 95)}); s != 0 || e != 1 {
		t.Fatalf("single critical point: secs=%d eps=%d", s, e)
	}
}

func TestDownsampleKeepsPeaks(t *testing.T) {
	var pts []store.LimitPoint
	for m := 0; m < 60; m++ {
		p := lp(m, 10)
		if m == 37 {
			p.FiveHour = 99
		}
		pts = append(pts, p)
	}
	start, end := pts[0].T, pts[0].T.Add(time.Hour)
	out := downsample(pts, start, end, 6)
	if len(out) != 6 {
		t.Fatalf("want 6 points, got %d", len(out))
	}
	if out[3].FiveHour != 99 || out[3].T.Minute() != 37 {
		t.Fatalf("peak lost: %+v", out[3])
	}
	if got := downsample(pts, start, end, 1000); len(got) != 60 {
		t.Fatalf("fewer points than slots must pass through: %d", len(got))
	}
}
