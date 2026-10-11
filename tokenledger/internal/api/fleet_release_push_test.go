package api

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A new stable, pushed (claude-fleet#3146, EPIC #3139 C7).

// setStable writes the store's stable pointer, as a promote leaves it.
func setStable(t *testing.T, rs *ReleaseStore, sha string, seq int64) {
	t.Helper()
	b, _ := json.Marshal(stablePointer{SHA: sha, Seq: seq})
	must(t, os.WriteFile(filepath.Join(rs.Dir, releaseStable), b, 0o644))
}

// nextRelease reads the next message and wants a TypeRelease of sha #seq.
func nextRelease(t *testing.T, c *websocket.Conn, sha string, seq int64, what string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m control.Message
	if err := wsjson.Read(ctx, c, &m); err != nil {
		t.Fatalf("%s: no message: %v", what, err)
	}
	var r control.Release
	_ = json.Unmarshal(m.Payload, &r)
	if m.Type != control.TypeRelease || r.SHA != sha || r.Seq != seq {
		t.Fatalf("%s: got %s %s, want release %.7s #%d", what, m.Type, m.Payload, sha, seq)
	}
}

func TestReleasePushOnPromoteBeatAndReconnect(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.Releases = &ReleaseStore{Dir: t.TempDir()}
	tokA, tokB, tokC := h.enroll(t, "a"), h.enroll(t, "b"), h.enroll(t, "c")
	hb := func(host string) control.Heartbeat { return control.Heartbeat{Hostname: host, OSUser: "op"} }

	// No stable yet: a node that follows hears nothing on its first beat.
	c := teamNode(t, h, tokC, control.CapRelease)
	beat(t, c, control.Proto, hb("m3"))
	silent(t, c, "no stable")

	a := teamNode(t, h, tokA, control.CapRead, control.CapRelease)
	b := teamNode(t, h, tokB, control.CapRead) // an older agent: no CapRelease
	beat(t, a, control.Proto, hb("m5"))
	beat(t, b, control.Proto, hb("m4"))

	// A promote reaches the connected node at once — no beat needed.
	setStable(t, h.srv.Releases, shaA, 1)
	h.srv.BroadcastRelease(shaA, 1)
	nextRelease(t, a, shaA, 1, "after promote #1")

	// Beats and a repeat of #1 push nothing; neither does an older seq after
	// a newer one — the next message is the next stable.
	beat(t, a, control.Proto, hb("m5"))
	h.srv.BroadcastRelease(shaA, 1)
	time.Sleep(200 * time.Millisecond)
	setStable(t, h.srv.Releases, shaB, 2)
	h.srv.BroadcastRelease(shaB, 2)
	nextRelease(t, a, shaB, 2, "after promote #2 (repeats in between send nothing)")
	h.srv.BroadcastRelease(shaA, 1) // an old one, late: never sent
	time.Sleep(200 * time.Millisecond)
	setStable(t, h.srv.Releases, shaC, 3)
	h.srv.BroadcastRelease(shaC, 3)
	nextRelease(t, a, shaC, 3, "after promote #3 (the old #1 was not sent)")

	// A machine that was offline hears the current stable on its first beat back.
	a.CloseNow()
	a2 := teamNode(t, h, tokA, control.CapRead, control.CapRelease)
	beat(t, a2, control.Proto, hb("m5"))
	nextRelease(t, a2, shaC, 3, "reconnect")
	silent(t, a2, "one first beat, one message")

	// The node without the capability was never sent one.
	silent(t, b, "no CapRelease")
}

// TestReleasePushOffAddsNothing: no node lists CapRelease → a promote and a
// first beat send nothing at all, byte for byte as before; a hub with no
// stable yet sends nothing to a node that does list it.
func TestReleasePushOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	// The store is set before any link is up: a first beat reads it.
	h.srv.Releases = &ReleaseStore{Dir: t.TempDir()}
	tokA, tokB := h.enroll(t, "a"), h.enroll(t, "b")
	hb := func(host string) control.Heartbeat { return control.Heartbeat{Hostname: host, OSUser: "op"} }

	// No stable pointer yet, a node that would follow: nothing.
	b := teamNode(t, h, tokB, control.CapRelease)
	beat(t, b, control.Proto, hb("m4"))
	silent(t, b, "no stable")

	setStable(t, h.srv.Releases, shaA, 1)
	a := teamNode(t, h, tokA, control.CapRead, control.CapTeam)
	beat(t, a, control.Proto, hb("m5"))
	h.srv.BroadcastRelease(shaA, 1)
	beat(t, a, control.Proto, hb("m5"))
	silent(t, a, "no CapRelease")
}

// A promote tells OnPromote the new stable and its seq — the road a publish
// and the GitHub follower both take.
func TestReleasePromoteCallsOnPromote(t *testing.T) {
	r := newReleaseRig(t)
	got := make(chan string, 2)
	r.rs.OnPromote = func(sha string, seq int64) { got <- fmt.Sprintf("%s#%d", sha, seq) }
	if err := r.rs.promote(context.Background(), shaA); err != nil {
		t.Fatal(err)
	}
	select {
	case s := <-got:
		if s != shaA+"#1" {
			t.Fatalf("OnPromote %s, want %s#1", s, shaA)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("stable moved but OnPromote was not called")
	}
	// The pointer already there: a no-op, nothing told again.
	if err := r.rs.promote(context.Background(), shaA); err != nil {
		t.Fatal(err)
	}
	select {
	case s := <-got:
		t.Fatalf("a repeated promote told OnPromote %s", s)
	case <-time.After(300 * time.Millisecond):
	}
}
