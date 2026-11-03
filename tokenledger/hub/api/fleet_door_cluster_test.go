package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/dns"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Each pod goes through its own cluster's door (task P0D4, BREAK-IT
// door-wrong-cluster): a pod of cluster A sent to cluster B's door meets a
// door that cannot resolve u-<nonce>.<ns>.svc.cluster.local — 「your pod does
// not answer」.

// clusterPod records a spare pod of cluster: its name.
func clusterPod(t *testing.T, h *harness, cluster string) string {
	t.Helper()
	a, err := h.srv.Store.CreateClusterSpare(cluster, control.ValidLogin, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return a.Hostname
}

func setSettings(t *testing.T, h *harness, kv ...string) {
	t.Helper()
	for i := 0; i+1 < len(kv); i += 2 {
		if err := h.srv.Store.SetFleetSetting(kv[i], kv[i+1], time.Now()); err != nil {
			t.Fatal(err)
		}
	}
}

// Two clusters, one door each: every pod is reached at its own cluster's
// door — its address, its DNS name, its public port — and each door's table
// holds its own cluster's pods alone.
func TestDoorPerClusterTwoDoors(t *testing.T) {
	h := entryHarness(t)
	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	now := time.Now().UTC()
	sz, aws := clusterPod(t, h, "ack-sz"), clusterPod(t, h, "aws-usw2")
	setSettings(t, h, DoorKey, "fleet-door,fleet-door-aws",
		DoorClusterPrefix+"fleet-door", "ack-sz", DoorClusterPrefix+"fleet-door-aws", "aws-usw2")
	_, szTok := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	_, awsTok := rootNode(t, h, "door-aws", "fleet-door-aws", control.CapEntryKeys)
	dnsReach(t, h, "fleet-door", now, true, "119.23.75.134")
	dnsReach(t, h, "fleet-door-aws", now, true, "44.242.37.244")
	doorHome(t, h, pAlice, sz, "alice")
	doorHome(t, h, pBob, aws, "bob")
	for _, n := range []struct{ p, name string }{{pAlice, "alice"}, {pBob, "bob"}} {
		if _, err := h.srv.Store.SetEntryName(n.p, n.name, now); err != nil {
			t.Fatal(err)
		}
	}

	if m := h.srv.entryAddrMachine(sz, now); m != "fleet-door" {
		t.Fatalf("the ack-sz pod is reached at %s, want fleet-door", m)
	}
	if m := h.srv.entryAddrMachine(aws, now); m != "fleet-door-aws" {
		t.Fatalf("door-wrong-cluster: the aws-usw2 pod is reached at %s, want fleet-door-aws", m)
	}
	for tok, want := range map[string]string{szTok: sz, awsTok: aws} {
		_, list, raw := doorRoutes(t, h, tok)
		if len(list.Routes) != 1 || list.Routes[0].Service != want || len(list.Logins) != 1 {
			t.Fatalf("door-wrong-cluster: a door's table holds another cluster's pod (want only %s): %s", want, raw)
		}
	}
	h.srv.EntryDNSTick(context.Background(), now.Add(time.Minute))
	if got, want := dnsZone(f), "A alice.cf 119.23.75.134 | A bob.cf 44.242.37.244"; got != want {
		t.Fatalf("zone:\n%s\nwant\n%s", got, want)
	}
}

// One cluster (no door says its cluster): byte for byte as before — the first
// reachable door for every pod, every pod in every door's table.
func TestDoorPerClusterUnlabeledAsBefore(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	sz, aws := clusterPod(t, h, "ack-sz"), clusterPod(t, h, "aws-usw2")
	setSettings(t, h, DoorKey, "fleet-door,fleet-door-b")
	_, tokA := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	_, tokB := rootNode(t, h, "door-b", "fleet-door-b", control.CapEntryKeys)
	doorHome(t, h, pAlice, sz, "alice")
	doorHome(t, h, pBob, aws, "bob")
	buf := captureLog(t)

	// none reachable: the first named
	for _, p := range []string{sz, aws} {
		if m := h.srv.entryAddrMachine(p, now); m != "fleet-door" {
			t.Fatalf("%s is reached at %s, want fleet-door", p, m)
		}
	}
	dnsReach(t, h, "fleet-door-b", now, true, "203.0.113.20")
	for _, p := range []string{sz, aws} {
		if m := h.srv.entryAddrMachine(p, now); m != "fleet-door-b" {
			t.Fatalf("%s is reached at %s, want the first reachable fleet-door-b", p, m)
		}
	}
	want, err := h.srv.entryRouteList()
	if err != nil {
		t.Fatal(err)
	}
	wb, _ := json.Marshal(want)
	for _, tok := range []string{tokA, tokB} {
		_, _, raw := doorRoutes(t, h, tok)
		if strings.TrimSpace(raw) != string(wb) || len(want.Routes) != 2 {
			t.Fatalf("an unlabeled door's table changed:\n%s\nwant\n%s", raw, wb)
		}
	}
	if strings.Contains(buf.String(), "door: ") {
		t.Fatalf("no cluster said, yet a log line: %s", buf)
	}
}

// A cluster's door unreachable for now: the pod stays on its own cluster's
// door (another cluster's door cannot reach it) and the hub says so; a pod of
// a cluster with no door at all falls back to the old pick, said once.
func TestDoorPerClusterFallbackLogged(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	sz, aws, other := clusterPod(t, h, "ack-sz"), clusterPod(t, h, "aws-usw2"), clusterPod(t, h, "gcp-x")
	setSettings(t, h, DoorKey, "fleet-door,fleet-door-aws",
		DoorClusterPrefix+"fleet-door", "ack-sz", DoorClusterPrefix+"fleet-door-aws", "aws-usw2")
	_, szTok := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	dnsReach(t, h, "fleet-door", now, true, "119.23.75.134")
	doorHome(t, h, pAlice, aws, "alice")
	doorHome(t, h, pBob, other, "bob")
	buf := captureLog(t)

	if m := h.srv.entryAddrMachine(aws, now); m != "fleet-door-aws" {
		t.Fatalf("door-wrong-cluster: the aws pod with its door down is reached at %s, want fleet-door-aws", m)
	}
	if !strings.Contains(buf.String(), aws) || !strings.Contains(buf.String(), "aws-usw2") {
		t.Fatalf("the unreachable cluster door was not logged: %q", buf)
	}
	if m := h.srv.entryAddrMachine(other, now); m != "fleet-door" {
		t.Fatalf("a pod of a cluster with no door is reached at %s, want the old pick fleet-door", m)
	}
	if !strings.Contains(buf.String(), other) || !strings.Contains(buf.String(), "gcp-x") {
		t.Fatalf("the fallback was not logged: %q", buf)
	}
	n := strings.Count(buf.String(), "\n")
	h.srv.entryAddrMachine(other, now)
	h.srv.entryAddrMachine(aws, now)
	if strings.Count(buf.String(), "\n") != n {
		t.Fatalf("the same reason logged twice: %q", buf)
	}
	// the ack-sz door carries the doorless cluster's pod (the old pick), never the aws one
	_, list, raw := doorRoutes(t, h, szTok)
	if len(list.Routes) != 1 || list.Routes[0].Service != other {
		t.Fatalf("door-wrong-cluster: fleet-door's table: %s (want %s alone)", raw, other)
	}
	_ = sz
}

func kvBody(k, v string) map[string]string { return map[string]string{"key": k, "value": v} }

func TestDoorClusterSetting(t *testing.T) {
	h := entryHarness(t)
	for _, v := range []string{"ack-sz", " AWS-usw2 ", ""} {
		if code, raw := h.post(t, "/v1/fleet/settings", kvBody(DoorClusterPrefix+"fleet-door", v)); code != 200 {
			t.Fatalf("%s=%q: HTTP %d %s", DoorClusterPrefix, v, code, raw)
		}
	}
	for _, v := range []string{"bad name", "u-k3x9q2"} {
		if code, _ := h.post(t, "/v1/fleet/settings", kvBody(DoorClusterPrefix+"fleet-door", v)); code != 400 {
			t.Fatalf("%s=%q taken: HTTP %d", DoorClusterPrefix, v, code)
		}
	}
	if code, _ := h.post(t, "/v1/fleet/settings", kvBody(DoorClusterPrefix+"u-k3x9q2", "ack-sz")); code != 400 {
		t.Fatalf("a pod named as a door: HTTP %d", code)
	}
}
