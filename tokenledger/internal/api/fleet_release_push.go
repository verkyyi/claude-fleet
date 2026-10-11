package api

import (
	"context"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A new stable, pushed (claude-fleet#3146, EPIC #3139 C7).
//
// A managed machine asked the hub for stable every 5 minutes and a login of
// its own every 30, so the last leg of a release — merged, published, and then
// waiting for every machine's clock — took minutes for no reason. Now the
// moment the stable pointer moves (a publish, or the GitHub follower), every
// connection whose hello listed CapRelease hears TypeRelease {sha, seq}, and
// each connection's first beat tells it the stable it has not heard. The node
// only wakes the update it would have run anyway; its clock stays as the
// fallback. No capability → nothing sent, byte for byte as before.

// pushRelease tells one connection the stable release p (zero = the store's
// pointer now) when it has not been told that seq or a later one. No store,
// no pointer → no message. A failed write is not recorded: the next
// connection's first beat, or the next promote, tells it again.
func (s *Server) pushRelease(endpointID string, nc *nodeConn, p stablePointer) {
	if !nc.canRelease {
		return
	}
	if p.SHA == "" {
		if s.Releases == nil {
			return
		}
		p = s.Releases.stable()
	}
	if p.SHA == "" || p.Seq < 1 || nc.releaseSent.Load() >= p.Seq {
		return
	}
	msg, err := control.New(control.TypeRelease, control.Release{SHA: p.SHA, Seq: p.Seq})
	if err != nil {
		return
	}
	wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if s.nodes.get(endpointID) != nc {
		return // a newer link took over; it hears the release on its own first beat
	}
	if err := s.SendNodeWrite(wctx, endpointID, msg); err != nil {
		return
	}
	for {
		old := nc.releaseSent.Load()
		if old >= p.Seq || nc.releaseSent.CompareAndSwap(old, p.Seq) {
			return
		}
	}
}

// BroadcastRelease pushes the stable release sha (seq) to every connection
// that wakes on one — ReleaseStore.OnPromote.
func (s *Server) BroadcastRelease(sha string, seq int64) {
	p := stablePointer{SHA: sha, Seq: seq}
	if p.SHA == "" || p.Seq < 1 {
		return
	}
	s.nodes.each(func(id string, c *nodeConn) {
		if c.canRelease {
			go s.pushRelease(id, c, p)
		}
	})
}
