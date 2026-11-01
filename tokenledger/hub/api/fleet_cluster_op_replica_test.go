package api

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The ops link ends in one replica (task APVZ): a cluster op asked on the other
// one is handed to the holder and answered as if local — a claim, a bind or a
// roll no longer depends on which replica took it. With no link anywhere it is
// still errNoOpsLink.
func TestClusterOpForwardsToTheHolder(t *testing.T) {
	ha, hb := newReplicaPair(t)
	pub, key, _ := ed25519.GenerateKey(nil)
	ha.srv.SetAccountKey(key)
	hb.srv.SetAccountKey(key)
	ctx := context.Background()
	tk := control.ClusterTicket{Op: control.ClusterRollUserPod, Pod: "u-abcd1234"}
	if _, err := ha.srv.clusterOp(ctx, testCluster, tk); !errors.Is(err, errNoOpsLink) {
		t.Fatalf("no ops link anywhere: err = %v; want errNoOpsLink", err)
	}
	ops := startFakeOps(t, hb, pub) // hub-b holds the link
	waitFor(t, 3*time.Second, "hub-a sees hub-b's ops link", func() bool {
		_, ok := ha.srv.peerOpsLink(testCluster)
		return ok
	})
	if _, c := ha.srv.nodes.opsFor(testCluster); c != nil {
		t.Fatal("hub-a holds the ops link too; the test needs it on hub-b alone")
	}
	before := ha.srv.forwarded.Load()
	res, err := ha.srv.clusterOp(ctx, testCluster, tk)
	if err != nil || res.RC != 0 {
		t.Fatalf("roll asked on hub-a: res %+v err %v; want the holder's answer", res, err)
	}
	if got := ops.expect(control.ClusterRollUserPod); got.Pod != tk.Pod || got.Cluster != testCluster {
		t.Fatalf("the ops link got %+v", got)
	}
	if ha.srv.forwarded.Load() != before+1 {
		t.Fatalf("forwarded %d; want 1", ha.srv.forwarded.Load()-before)
	}
	// on the holder itself: no forward
	before = hb.srv.forwarded.Load()
	if _, err := hb.srv.clusterOp(ctx, testCluster, tk); err != nil {
		t.Fatalf("roll on hub-b: %v", err)
	}
	ops.expect(control.ClusterRollUserPod)
	if hb.srv.forwarded.Load() != before {
		t.Fatal("the holder forwarded its own op")
	}
}
