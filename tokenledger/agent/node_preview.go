package agent

import (
	"context"
	"encoding/json"
	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"time"
)

func (a *Agent) openPreviewRelay(ctx context.Context, m control.Message, generation string) {
	var ro control.ChatRelayOpen
	if json.Unmarshal(m.Payload, &ro) != nil || ro.Login != a.chatLogin() || ro.RelayID == "" || !a.previewRelays.take(32) {
		return
	}
	defer a.previewRelays.give()
	dctx, cancel := context.WithTimeout(ctx, sshRelayDialTimeout)
	defer cancel()
	ws, err := a.dialRelayData(dctx, control.PreviewDataPath, ro.RelayID, ro.Secret)
	if err != nil {
		return
	}
	defer ws.CloseNow()
	var hello control.PreviewHello
	if readRelayHello(ctx, ws, &hello) != nil {
		return
	}
	g, err := control.VerifyPreview(hello.Grant, control.ChatTokenHash(a.cfg.Token), ro.Login, ro.RelayID, generation, time.Now())
	if err != nil || !a.previewSpent.spend(ro.RelayID, time.Now()) {
		ws.Close(websocket.StatusPolicyViolation, "preview grant refused")
		return
	}
	// Always a helper, including a per-login agent: chdir is process-global.
	sock, err := startSocketPipe(dctx, "preview-pipe", g.Socket)
	if err != nil {
		ws.Close(websocket.StatusPolicyViolation, "preview socket refused")
		return
	}
	cancel()
	splice(ctx, ws, sock)
}
