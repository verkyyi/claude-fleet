package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func peerRelayDial(t *testing.T, h *harness, token, host string) (*websocket.Conn, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	u := "ws" + strings.TrimPrefix(h.http.URL, "http") + "/v1/node/peer-relay?node=" + host
	c, res, err := websocket.Dial(ctx, u, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
	if err != nil {
		if res != nil {
			return nil, res.StatusCode
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { c.CloseNow() })
	return c, http.StatusSwitchingProtocols
}

func TestPeerRelayOwnerGate(t *testing.T) {
	h, _, nodes := peerHarness(t)
	for _, tc := range []struct {
		token, host string
		status      int
	}{
		{"", "mac-e-mac-c", 401},
		{viewerToken, "mac-e-mac-c", 401},
		{nodes["bob4"].token, "mac-e", 403},
		{nodes["alice5"].token, "mac-e", 400},
		{nodes["alice5"].token, "missing", 422},
	} {
		if _, status := peerRelayDial(t, h, tc.token, tc.host); status != tc.status {
			t.Fatalf("target %s: status %d, want %d", tc.host, status, tc.status)
		}
	}
	// An owned target with no capable agent is explicit, never redirected to
	// the other person's login on the same machine.
	c, status := peerRelayDial(t, h, nodes["alice5"].token, "mac-e-mac-c")
	if status != 101 {
		t.Fatalf("status %d", status)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var hello control.SSHRelayHello
	if err := wsjson.Read(ctx, c, &hello); err != nil || hello.Code != "NODE_OFFLINE" {
		t.Fatalf("offline: %+v %v", hello, err)
	}
}

func TestPeerRelayStreamTargetsOwnerLogin(t *testing.T) {
	h, _, nodes := peerHarness(t)
	n := nodes["alice4"]
	// Reconnect with the actual capability negotiation, rather than mutating
	// the server's connection flags under its reader.
	n.c.CloseNow()
	n.tnode = dialAdminCaps(t, h, n.token, false, control.CapSSHRelay, control.CapPodRelay)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "mac-e-mac-c", OSUser: "alice"})
	waitFor(t, 3*time.Second, "relay ready", func() bool { return h.srv.podRelayReady("mac-e-mac-c") })
	c, status := peerRelayDial(t, h, nodes["alice5"].token, "mac-e-mac-c")
	if status != 101 {
		t.Fatalf("status %d", status)
	}
	var request control.SSHRelayOpen
	for {
		m, ok := readMsg(n.tnode, 5*time.Second)
		if !ok {
			t.Fatal("owner's login received no relay request")
		}
		if m.Type == control.TypeSSHRelayOpen {
			if err := json.Unmarshal(m.Payload, &request); err != nil {
				t.Fatal(err)
			}
			break
		}
	}
	if request.Target != "" {
		t.Fatalf("must reach pod sshd, got %q", request.Target)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	u := "ws" + strings.TrimPrefix(h.http.URL, "http") + control.SSHRelayDataPath + "?id=" + request.RelayID
	d, _, err := websocket.Dial(ctx, u, &websocket.DialOptions{HTTPHeader: http.Header{
		"Authorization": {"Bearer " + n.token}, "X-Relay-Secret": {request.Secret}}})
	if err != nil {
		t.Fatal(err)
	}
	defer d.CloseNow()
	var hello control.SSHRelayHello
	if err := wsjson.Read(ctx, c, &hello); err != nil || hello.Type != "ready" {
		t.Fatalf("ready: %+v %v", hello, err)
	}
	for _, stream := range []struct {
		from, to *websocket.Conn
		text     string
	}{
		{c, d, "SSH-2.0-client\r\n"}, {d, c, "SSH-2.0-pod\r\n"},
	} {
		if err := stream.from.Write(ctx, websocket.MessageBinary, []byte(stream.text)); err != nil {
			t.Fatal(err)
		}
		_, b, err := stream.to.Read(ctx)
		if err != nil || string(b) != stream.text {
			t.Fatalf("stream: %q %v", b, err)
		}
	}
	rows, err := h.srv.Store.SSHRelays(10)
	if err != nil || len(rows) != 1 || rows[0].EndpointID != n.id || rows[0].Actor != "peer:"+nodes["alice5"].id {
		t.Fatalf("audit: %+v %v", rows, err)
	}
}
