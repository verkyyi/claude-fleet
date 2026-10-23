package e2e

import (
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"

	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// installFakeHubNode lays a stand-in for claude-fleet's bin/fleet-hub-node.sh
// beside the fake fleet-control.py: `paths` names an outbox and a worker map
// under home, `deliver` appends the relay to home/delivered (one line each)
// and exits with home/deliver.rc (0 when absent).
func installFakeHubNode(t *testing.T, home string) {
	t.Helper()
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/bash
H=` + shQuote(home) + `
case "$1" in
  paths) printf 'outbox\t%s\nworkers\t%s\n' "$H/outbox" "$H/hub-workers.tsv" ;;
  deliver) { tr -d '\n'; echo; } >> "$H/delivered"; rc=$(cat "$H/deliver.rc" 2>/dev/null); exit "${rc:-0}" ;;
  *) exit 2 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "fleet-hub-node.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// startRelayAgent runs one real agent against the harness hub until the test
// ends (or the returned stop is called).
func startRelayAgent(t *testing.T, h *harness, label, home, token string, every time.Duration) (stop func()) {
	t.Helper()
	a, err := agent.New(agent.Config{
		HubURL: h.HTTP.URL, Token: token, Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: every, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, Version: "it-" + label,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	stopped := false
	stop = func() {
		if !stopped {
			stopped = true
			cancel()
			<-done
		}
	}
	t.Cleanup(stop)
	return stop
}

func dropRelay(t *testing.T, outbox, name string, r control.Relay) string {
	t.Helper()
	if err := os.MkdirAll(outbox, 0o700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(r)
	f := filepath.Join(outbox, name)
	if err := os.WriteFile(f, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

// Two real node agents verify permanent report refusal, including a backlog
// targeting an old receiver, while ordinary messages still deduplicate, wait
// through disconnects, and enforce sender ownership.
func TestRelayIntegrationTwoAgents(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_control.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}
	t.Cleanup(SetWorkersPushEveryForTest(100 * time.Millisecond))

	h := newFleetHarness(t)
	const every = 150 * time.Millisecond
	parentHome, childHome := t.TempDir(), t.TempDir()
	installFakeFleetControl(t, py, bin, parentHome, "fleet-mac-d", "verkyyi/claude-fleet")
	installFakeFleetControl(t, py, bin, childHome, "fleet-mac-c", "verkyyi/claude-fleet")
	// The child's machine: its issue-42 window carries the parent's worker_id
	// as @origin_wid (inventory column 11, issue #1423; column 12 is
	// @claude_needs, #1475) once we know it, and its lifelong identity as
	// column 13 (@fleet_id, claude-fleet#1646).
	const childIdentity = "9d1c6b7e-2f4a-4c3b-8e5d-6a7b8c9d0e1f"
	adapter := filepath.Join(childHome, ".claude", "fleet", "bin", "fleet-control-read.sh")
	b, _ := os.ReadFile(adapter)
	b = []byte(strings.Replace(string(b),
		`workers) printf '@1\t42\t\t/w/x-issue-42\tworking\tclaude\tw1\t\t\n@2\t\t1\t/w/x-scratch-3\tidle\tclaude\tw2\t\t\n' ;;`,
		`workers) printf '@1\t42\t\t/w/x-issue-42\tworking\tclaude\tw1\t\t\tissue-42\t%s\t\t`+childIdentity+`\n' "$(cat `+shQuote(filepath.Join(childHome, "origin"))+` 2>/dev/null)" ;;`, 1))
	if err := os.WriteFile(adapter, b, 0o755); err != nil {
		t.Fatal(err)
	}
	installFakeHubNode(t, parentHome)
	installFakeHubNode(t, childHome)

	parentTok, childTok := h.Enroll(t, "mac-d"), h.Enroll(t, "mac-c")
	stopParent := startRelayAgent(t, h, "mac-d", parentHome, parentTok, every)
	startRelayAgent(t, h, "mac-c", childHome, childTok, every)

	var parentFleet, childFleet string
	waitFor(t, 10*time.Second, "both fleets registered", func() bool {
		for _, f := range getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any) {
			f := f.(map[string]any)
			switch f["endpoint_id"] {
			case "ep_mac-d":
				parentFleet = f["fleet_id"].(string)
			case "ep_mac-c":
				childFleet = f["fleet_id"].(string)
			}
		}
		return parentFleet != "" && childFleet != ""
	})
	parentWID, childWID := parentFleet+"/issue-42", childFleet+"/issue-42"
	if err := os.WriteFile(filepath.Join(childHome, "origin"), []byte(parentWID), 0o644); err != nil {
		t.Fatal(err)
	}
	// …and nudges, as a real spawn's stamp does: fleet_control.py's heartbeat
	// reads reuse the last answer until a nudge (claude-fleet#3514)
	nudge := filepath.Join(childHome, ".config", "claude-fleet", "global", "hub-nudge")
	if err := os.MkdirAll(filepath.Dir(nudge), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(nudge, []byte("origin\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The map: the parent's machine learns its child runs elsewhere, and whose.
	parentMap := filepath.Join(parentHome, "hub-workers.tsv")
	waitFor(t, 10*time.Second, "the parent's map to list the remote child with its parent", func() bool {
		for _, l := range lines(parentMap) {
			if f := strings.Split(l, "\t"); len(f) == 3 && f[0] == childWID && f[1] != "" && f[2] == parentWID {
				return true
			}
		}
		return false
	})

	// …and by its lifelong identity (claude-fleet#1646): the same child, same
	// node, same parent, under <fleet UUID>/<fleet_id>.
	waitFor(t, 10*time.Second, "the parent's map to list the remote child by its identity", func() bool {
		for _, l := range lines(parentMap) {
			if f := strings.Split(l, "\t"); len(f) == 3 && f[0] == childFleet+"/"+childIdentity && f[1] != "" && f[2] == parentWID {
				return true
			}
		}
		return false
	})

	childOutbox := filepath.Join(childHome, "outbox")
	// An old sender's report is permanently refused, never stored or sent to
	// the recipient, even when both nodes still advertise relay capability.
	retired := control.Relay{ID: childWID + "#retired", Kind: control.RelayChildReport, From: childWID, To: parentWID, Payload: json.RawMessage(`{"state":"MERGED"}`)}
	retiredPath := dropRelay(t, childOutbox, "20260101T000000Z-retired.json", retired)
	retiredSaved := filepath.Join(childOutbox, "refused", filepath.Base(retiredPath))
	waitFor(t, 5*time.Second, "old report permanently refused", func() bool { return gone(retiredPath) && !gone(retiredSaved) })
	if why, _ := os.ReadFile(retiredSaved + ".why"); !strings.Contains(string(why), "PARENT_REPORT_RETIRED") {
		t.Fatalf("report refusal: %s", why)
	}
	if _, err := h.Srv.Store.FleetRelay(retired.ID); err == nil {
		t.Fatal("retired report inserted")
	}
	if n := len(lines(filepath.Join(parentHome, "delivered"))); n != 0 {
		t.Fatalf("retired report delivered %d times", n)
	}

	// An ordinary message, sent twice (the outbox's resend): applied once.
	message := control.Relay{ID: childWID + "#1700000000.1", Kind: control.RelayMessage, From: childWID, To: parentWID,
		Payload: json.RawMessage(`{"text":"ordinary message"}`)}
	f1 := dropRelay(t, childOutbox, "20260101T000000Z-1-a.json", message)
	delivered := filepath.Join(parentHome, "delivered")
	waitFor(t, 10*time.Second, "the message applied on the parent's machine", func() bool { return len(lines(delivered)) == 1 })
	waitFor(t, 5*time.Second, "the child's outbox file settled", func() bool { return gone(f1) })
	var got control.Relay
	if err := json.Unmarshal([]byte(lines(delivered)[0]), &got); err != nil || got.ID != message.ID || got.From != childWID ||
		got.To != parentWID || got.FromNode == "" || !strings.Contains(string(got.Payload), `"ordinary message"`) {
		t.Fatalf("delivered %q (%v); want the message, from %s, with the hub naming the sender's machine", lines(delivered)[0], err, childWID)
	}
	waitFor(t, 5*time.Second, "the relay recorded delivered", func() bool {
		r, err := h.Srv.Store.FleetRelay(message.ID)
		return err == nil && r.Status == store.RelayDelivered
	})
	f2 := dropRelay(t, childOutbox, "20260101T000001Z-1-b.json", message)
	waitFor(t, 5*time.Second, "the duplicate acked", func() bool { return gone(f2) })
	time.Sleep(4 * every)
	if n := len(lines(delivered)); n != 1 {
		t.Fatalf("a resent message was applied %d times; want once", n)
	}

	// The parent's machine is offline: the hub keeps it, and delivers on return.
	stopParent()
	// Backlog from the previous version cannot reach an old recipient after
	// reconnect, even if it was pushed very recently and is not due for retry.
	retiredBacklog := store.FleetRelay{ID: childWID + "#old-backlog", Kind: control.RelayChildReport, FromWID: childWID, ToWID: parentWID, FromEndpoint: "ep_mac-c", TargetEndpoint: "ep_mac-d", Payload: `{"state":"MERGED","summary":"historical payload"}`, Created: time.Now()}
	// Install the historical already-sent row atomically. The live dispatcher
	// may retire it immediately; inserting and then MarkSent would race with
	// retirement and leave attempts=0, never establishing the intended fixture.
	sentAt := retiredBacklog.Created.UTC().Format(time.RFC3339Nano)
	if _, err := h.Srv.Store.DB().Exec(`INSERT INTO fleet_relays
		(id, kind, from_wid, to_wid, from_endpoint, target_endpoint, payload,
		status, attempts, created, updated, sent_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		retiredBacklog.ID, retiredBacklog.Kind, retiredBacklog.FromWID, retiredBacklog.ToWID,
		retiredBacklog.FromEndpoint, retiredBacklog.TargetEndpoint, retiredBacklog.Payload,
		store.RelayPending, 1, sentAt, sentAt, sentAt); err != nil {
		t.Fatal(err)
	}
	message2 := message
	message2.ID = childWID + "#1700000001.2"
	f3 := dropRelay(t, childOutbox, "20260101T000002Z-1-c.json", message2)
	waitFor(t, 5*time.Second, "the hub stores it while the parent is away", func() bool {
		r, err := h.Srv.Store.FleetRelay(message2.ID)
		return gone(f3) && err == nil && r.Status == store.RelayPending
	})
	startRelayAgent(t, h, "mac-d-again", parentHome, parentTok, every)
	waitFor(t, 10*time.Second, "the waiting message delivered on reconnect", func() bool { return len(lines(delivered)) == 2 })
	waitFor(t, 5*time.Second, "old backlog settled without delivery", func() bool {
		r, err := h.Srv.Store.FleetRelay(retiredBacklog.ID)
		return err == nil && r.Status == store.RelayFailed && strings.Contains(r.Detail, "PARENT_REPORT_RETIRED")
	})
	retiredRow, err := h.Srv.Store.FleetRelay(retiredBacklog.ID)
	if err != nil || retiredRow.Attempts != 1 || retiredRow.Payload != retiredBacklog.Payload {
		t.Fatalf("backlog history changed: %+v %v", retiredRow, err)
	}
	for _, line := range lines(delivered) {
		var r control.Relay
		_ = json.Unmarshal([]byte(line), &r)
		if r.Kind == control.RelayChildReport {
			t.Fatalf("old recipient received report: %s", line)
		}
	}

	// A node speaks only for workers it hosts: mac-c cannot forge mac-d's.
	forged := control.Relay{ID: parentWID + "#1", Kind: control.RelayMessage, From: parentWID, To: childWID,
		Payload: json.RawMessage(`{"text":"hi"}`)}
	f4 := dropRelay(t, childOutbox, "20260101T000003Z-1-d.json", forged)
	refused := filepath.Join(childOutbox, "refused", filepath.Base(f4))
	waitFor(t, 5*time.Second, "the forged relay refused and kept aside", func() bool { return gone(f4) && !gone(refused) })
	if why, _ := os.ReadFile(refused + ".why"); !strings.Contains(string(why), "FORBIDDEN") {
		t.Fatalf("refusal reason = %q; want FORBIDDEN", why)
	}
	if _, err := h.Srv.Store.FleetRelay(forged.ID); err == nil {
		t.Fatal("a refused relay was stored")
	}
}

func lines(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	out := []string{}
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func gone(path string) bool { _, err := os.Stat(path); return os.IsNotExist(err) }
