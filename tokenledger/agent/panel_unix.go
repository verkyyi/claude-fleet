//go:build unix

package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

// panelDial and panelAnswer bound the resident panel's road: a server that is
// not there costs panelDial, one that does not answer within panelAnswer costs
// that long — the Python panel opens instead. The answer gets a whole second: the
// Python panel itself takes 1-3 s on a machine busy enough to stall the server.
var (
	panelDial   = 50 * time.Millisecond
	panelAnswer = time.Second
	panelExec   = syscall.Exec
)

// PanelAttach is `ccquota panel attach -- <fallback…>`: hand stdin, stdout and
// stderr to the 看台's resident panel and exit with its code; no server, a
// refusal or no answer ⇒ exec <fallback…> --view <session> --client <client>
// (the Python panel, which starts the server for the next ⌘P), FLEET_PANEL_T0 =
// this process's start so the panel's clock starts at the key's popup.
func PanelAttach(fallback []string) int {
	t0 := time.Now()
	raw := os.Getenv("FLEET_PANEL_CTX")
	ctx, ok := parsePanelCtx(raw)
	if view := PanelView(ctx.Session); ok && view != "" && os.Getenv("FLEET_PANEL_SERVER") != "0" {
		if rc, served := panelServe(PanelSock(view), raw, t0); served {
			return rc
		}
	}
	return panelFallback(fallback, ctx, ok, t0)
}

func panelServe(sock, ctx string, t0 time.Time) (int, bool) {
	c, err := net.DialTimeout("unix", sock, panelDial)
	if err != nil {
		return 0, false
	}
	conn := c.(*net.UnixConn)
	defer conn.Close()
	env := map[string]string{}
	for _, kv := range os.Environ() {
		for i := 0; i < len(kv); i++ {
			if kv[i] == '=' {
				env[kv[:i]] = kv[i+1:]
				break
			}
		}
	}
	line, err := json.Marshal(map[string]any{"v": 1, "ctx": ctx, "env": env,
		"t0": float64(t0.UnixNano()) / 1e9})
	if err != nil {
		return 0, false
	}
	_ = conn.SetDeadline(time.Now().Add(panelAnswer))
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return 0, false
	}
	rd := bufio.NewReader(conn)
	// the descriptors go only to a server that answered: one that took the
	// connection and hangs never holds this popup's terminal
	var ready struct {
		Ready int `json:"ready"`
	}
	b, err := rd.ReadBytes('\n')
	if err != nil || json.Unmarshal(b, &ready) != nil || ready.Ready != 1 {
		return 0, false
	}
	if _, _, err := conn.WriteMsgUnix([]byte("F"), syscall.UnixRights(0, 1, 2), nil); err != nil {
		return 0, false
	}
	var first struct {
		PID int `json:"pid"`
	}
	b, err = rd.ReadBytes('\n')
	if err != nil || json.Unmarshal(b, &first) != nil || first.PID <= 0 {
		return 0, false
	}
	_ = conn.SetDeadline(time.Time{})
	// the popup's signals go to the panel: a resize, and the popup closing
	sig := make(chan os.Signal, 4)
	signal.Notify(sig, syscall.SIGWINCH, syscall.SIGHUP, syscall.SIGTERM)
	defer signal.Stop(sig)
	done := make(chan int, 1)
	go func() {
		var end struct {
			RC *int `json:"rc"`
		}
		b, err := rd.ReadBytes('\n')
		if err != nil || json.Unmarshal(b, &end) != nil || end.RC == nil {
			done <- 1
			return
		}
		done <- *end.RC
	}()
	for {
		select {
		case rc := <-done:
			return rc, true
		case s := <-sig:
			n := s.(syscall.Signal)
			if n == syscall.SIGWINCH {
				_ = syscall.Kill(first.PID, n)
				continue
			}
			_ = syscall.Kill(first.PID, syscall.SIGHUP)
			return 128 + int(n), true
		}
	}
}

func panelFallback(fallback []string, ctx panelCtx, ok bool, t0 time.Time) int {
	argv := panelFallbackArgv(fallback, ctx, ok)
	if len(argv) == 0 {
		fmt.Fprintln(os.Stderr, "ccquota panel attach: no resident panel and no fallback command")
		return 2
	}
	path, err := exec.LookPath(argv[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "ccquota panel attach: %v\n", err)
		return 127
	}
	env := append(os.Environ(), fmt.Sprintf("FLEET_PANEL_T0=%.3f", float64(t0.UnixNano())/1e9))
	err = panelExec(path, argv, env)
	fmt.Fprintf(os.Stderr, "ccquota panel attach: %v\n", err)
	return 126
}
