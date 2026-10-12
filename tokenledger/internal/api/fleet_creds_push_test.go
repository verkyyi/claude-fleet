package api

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A changed credential, pushed (claude-fleet#3744).

func nextCreds(t *testing.T, c *websocket.Conn, why, what string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m control.Message
	if err := wsjson.Read(ctx, c, &m); err != nil {
		t.Fatalf("%s: no message: %v", what, err)
	}
	var cr control.Creds
	_ = json.Unmarshal(m.Payload, &cr)
	if m.Type != control.TypeCreds || cr.Why != why {
		t.Fatalf("%s: got %s %s, want creds (%s)", what, m.Type, m.Payload, why)
	}
}

// TestCredsPushOnDeletePauseRevoke: the moment a pool subscription is stored,
// deleted, paused or resumed, or a machine revoked, every node that listed
// CapCreds hears TypeCreds — and the next lease no longer lists what went.
// A node without the capability hears nothing.
func TestCredsPushOnDeletePauseRevoke(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	other := h.enroll(t, "old")
	hb := func(host string) control.Heartbeat { return control.Heartbeat{Hostname: host, OSUser: "alice"} }
	a := teamNode(t, h, tok, control.CapRead, control.CapCreds)
	b := teamNode(t, h, other, control.CapRead) // an older agent: no CapCreds
	beat(t, a, control.Proto, hb("m4")) // oss-ok: the host newVaultHarness enrolled alice on
	beat(t, b, control.Proto, hb("host-b"))

	put := FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal, Provider: credvault.Claude,
		Account: "icloud", Secret: credvault.Secret{RefreshToken: "sk-ant-ort01-SECRET"}}
	if code, out := h.post(t, "/v1/fleet/credentials", put); code != http.StatusOK {
		t.Fatalf("put: %d %v", code, out)
	}
	nextCreds(t, a, "credential put", "after put")
	if code, l, _ := lease(t, h, tok); code != http.StatusOK || !leasesAccount(l, "icloud") {
		t.Fatalf("lease after put: %d %+v", code, l.Credentials)
	}

	if code, out := h.srv.putHubSetting("op", PoolPausedPrefix+"icloud", "on", time.Now()); code != http.StatusOK {
		t.Fatalf("pause: %d %s", code, out)
	}
	nextCreds(t, a, "pool pause", "after pause")
	if code, _ := h.srv.putHubSetting("op", PoolPausedPrefix+"icloud", "on", time.Now()); code != http.StatusOK {
		t.Fatal("pause again")
	}
	time.Sleep(200 * time.Millisecond) // pausing a paused account sends nothing: the next one is the delete's

	del := FleetCredentialRequest{Action: "delete", PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "icloud"}
	if code, out := h.post(t, "/v1/fleet/credentials", del); code != http.StatusOK {
		t.Fatalf("delete: %d %v", code, out)
	}
	nextCreds(t, a, "credential delete", "after delete")
	if code, l, _ := lease(t, h, tok); code != http.StatusOK || leasesAccount(l, "icloud") {
		t.Fatalf("lease after delete still lists icloud: %d %+v", code, l.Credentials)
	}

	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m9"}); code != http.StatusOK {
		t.Fatalf("revoke: %d %v", code, out)
	}
	nextCreds(t, a, store.CredRevoke, "after revoke")
	silent(t, a, "one push each")
	silent(t, b, "no CapCreds")
}

func leasesAccount(l NodeCredentialsResponse, account string) bool {
	for _, c := range l.Credentials {
		if c.Account == account {
			return true
		}
	}
	return false
}
