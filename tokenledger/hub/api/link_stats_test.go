package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A home link's record (task PNWW): a real node connects (first sight), is
// pinged by the hub, drops and comes back (a network drop with its gap), and
// the admin reads it per link and per Beijing hour; a member reads nothing.
func TestLinkStatsRecordAConnectPingsAndADrop(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.LinkSampleSecs = 1
	tok := h.enroll(t, "linkhome")
	n := dialAdminCaps(t, h, tok, false)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "mac-l", OSUser: "lee"})
	waitFor(t, 5*time.Second, "a ping is booked", func() bool {
		r, _ := h.srv.Store.LinkRTTs(time.Now().Add(-time.Hour))
		return len(r) > 0 && r[0].N > 0
	})
	n.c.Close(websocket.StatusNormalClosure, "")
	time.Sleep(300 * time.Millisecond)
	n2 := dialAdminCaps(t, h, tok, false)
	beat(t, n2.c, control.Proto, control.Heartbeat{Hostname: "mac-l", OSUser: "lee"})
	waitFor(t, 5*time.Second, "the reconnect is booked", func() bool {
		evs, _ := h.srv.Store.LinkEvents(time.Now().Add(-time.Hour))
		ups := 0
		for _, e := range evs {
			if e.Event == linkEventUp {
				ups++
			}
		}
		return ups >= 2
	})
	evs, _ := h.srv.Store.LinkEvents(time.Now().Add(-time.Hour))
	var causes []string
	downs := 0
	for _, e := range evs {
		if e.Event == linkEventUp {
			causes = append(causes, e.Cause)
		} else {
			downs++
		}
	}
	if len(causes) < 2 || causes[0] != linkCauseFirst || causes[1] != linkCauseNetwork {
		t.Fatalf("up causes = %v; want first, then network", causes)
	}
	if downs < 1 {
		t.Fatalf("the drop this hub saw was not booked: %+v", evs)
	}
	rtts, _ := h.srv.Store.LinkRTTs(time.Now().Add(-time.Hour))
	st := linkStatsOf(1, evs, rtts)
	if len(st.Links) != 1 || st.Links[0].Drops[linkCauseNetwork] != 1 || st.Links[0].Pings < 1 || len(st.Hours) != 24 {
		t.Fatalf("stats = %+v", st)
	}
	// The admin's route; a member gets nothing from it.
	if code, _ := asUID(t, h, http.MethodGet, LinkStatsPath, "gh:8201", "", nil); code == http.StatusOK {
		t.Fatalf("a member read the link stats")
	}
	// Off: no ping at all (a server of its own: the live one's watchers read the field).
	if (&Server{LinkSampleSecs: -1}).linkSample() != 0 || (&Server{}).linkSample() != linkSampleDefault {
		t.Fatal("the period: negative is off, zero is the default")
	}
}

// The fold and the read: a failure counts apart, the histogram answers the
// quantiles, first sight and a machine that was off are not drops, and the
// hour is Beijing's.
func TestLinkStatsFold(t *testing.T) {
	at := time.Date(2026, 10, 25, 12, 30, 0, 0, time.UTC) // 20:30 in Beijing
	rtts := []store.LinkRTT{{Hour: at.Unix() / 3600, Host: "m", Login: "u", N: 10, Fails: 1, SumMS: 9 * 160, MaxMS: 900,
		Buckets: [6]int64{0, 8, 0, 0, 1, 0}}}
	evs := []store.LinkEvent{
		{At: at, Host: "m", Login: "u", Event: linkEventUp, Cause: linkCauseFirst},
		{At: at, Host: "m", Login: "u", Event: linkEventUp, Cause: linkCauseNetwork, GapMS: 21000},
		{At: at, Host: "m", Login: "u", Event: linkEventUp, Cause: linkCauseHub, GapMS: 5000},
		{At: at, Host: "m", Login: "u", Event: linkEventUp, Cause: linkCauseOffline, GapMS: 7200000},
		{At: at, Host: "m", Login: "u", Event: linkEventDown, Cause: linkEndClosed},
	}
	st := linkStatsOf(2, evs, rtts)
	one := st.Links[0]
	if one.FailRate != 0.1 || one.RTTP50 != 200 || one.RTTP90 != 200 || one.RTTMax != 900 || one.RTTMean != 160 {
		t.Fatalf("rtt = %+v", one)
	}
	if one.Drops[linkCauseNetwork] != 1 || one.Drops[linkCauseHub] != 1 || len(one.Drops) != 2 || one.PerDay != 1 {
		t.Fatalf("drops = %+v", one)
	}
	if one.Gaps[linkCauseNetwork].P50 != 21000 {
		t.Fatalf("gaps = %+v", one.Gaps)
	}
	if st.Hours[20].Pings != 10 || st.Hours[20].Drops != 2 || st.Hours[12].Pings != 0 {
		t.Fatalf("Beijing hours = %+v / %+v", st.Hours[20], st.Hours[12])
	}
}
