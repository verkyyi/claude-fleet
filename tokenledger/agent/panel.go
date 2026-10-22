package agent

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// PanelCmd is `ccquota panel` (claude-fleet T890): the connector the 看台's ⌘P
// runs inside its popup — hand this terminal to the 看台's resident panel
// (bin/fleet-panel-server.py), else exec the Python panel here.
const PanelCmd = "panel"

// panelCtx is FLEET_PANEL_CTX, the keypress's context the key's
// `set-environment -F` put in the 看台 session (fleet-popup-lib.sh
// fleet_popup_bind): session · client · window · @peer_cur · @view_shell ·
// @view_lang_set · @view_lang · client width.
type panelCtx struct {
	Session, Client string
}

func parsePanelCtx(s string) (panelCtx, bool) {
	f := strings.Split(s, "|")
	if len(f) < 8 || f[0] == "" {
		return panelCtx{}, false
	}
	return panelCtx{Session: f[0], Client: f[1]}, true
}

// PanelView is the 看台's id a session name `<fleet>@view-<id>` carries, "" when
// it carries none (fleet_view.py view_id's rule).
func PanelView(session string) string {
	i := strings.LastIndex(session, "@view-")
	if i < 0 {
		return ""
	}
	v := session[i+len("@view-"):]
	if v == "" || len(v) > 64 {
		return ""
	}
	for _, c := range v {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
			return ""
		}
	}
	return v
}

// PanelSock is the resident panel's socket for a 看台 — fleet-panel-server.py
// sock_path's: $FLEET_PANEL_SOCK_DIR (else /tmp/fleet-panel-<uid>) /
// <sha1(view)[:16]>.sock.
func PanelSock(view string) string {
	dir := os.Getenv("FLEET_PANEL_SOCK_DIR")
	if dir == "" {
		dir = fmt.Sprintf("/tmp/fleet-panel-%d", os.Getuid())
	}
	sum := sha1.Sum([]byte(view))
	return filepath.Join(dir, hex.EncodeToString(sum[:])[:16]+".sock")
}

// panelFallbackArgv is the Python panel's argv: the command given after `--`
// with the keypress's --view <session> --client <client> appended.
func panelFallbackArgv(fallback []string, ctx panelCtx, ok bool) []string {
	argv := append([]string{}, fallback...)
	if ok {
		argv = append(argv, "--view", ctx.Session)
		if ctx.Client != "" {
			argv = append(argv, "--client", ctx.Client)
		}
	}
	return argv
}
