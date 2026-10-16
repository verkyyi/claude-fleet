//go:build unix

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// The Python helper's takeover, menu selection and cleanup use THIS flock.
// Checking an epoch then releasing the lock before the write is not fencing.
func (c termController) apply(f func() error) error {
	check := func() error {
		if c.ctx != nil && c.ctx.Err() != nil {
			return c.ctx.Err()
		}
		return f()
	}
	if c.Lock == "" {
		return check()
	} // in-process isolated PTY test seam only
	lock, err := os.OpenFile(c.Lock, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	var lease struct {
		Socket        string  `json:"socket"`
		View          string  `json:"view"`
		Window        string  `json:"window"`
		Identity      string  `json:"identity"`
		Conn          string  `json:"conn"`
		Epoch         uint64  `json:"epoch"`
		TS            float64 `json:"ts"`
		Selected      string  `json:"selected_lease"`
		SelectedEpoch uint64  `json:"selected_epoch"`
	}
	ttl := c.TTL
	if ttl < 5 {
		ttl = 30
	}
	read := func(path string) bool {
		b, e := os.ReadFile(path)
		return e == nil && json.Unmarshal(b, &lease) == nil && lease.Conn == c.Conn && time.Since(time.Unix(int64(lease.TS), 0)) < time.Duration(ttl)*time.Second
	}
	if !read(c.Lease) || lease.Epoch != c.Epoch {
		return errors.New("open_elsewhere")
	}
	primary := lease
	if lease.Selected != "" {
		path, epoch := lease.Selected, lease.SelectedEpoch
		if !read(path) || lease.Epoch != epoch {
			return errors.New("open_elsewhere")
		}
	}
	// Check the actual selected process while holding the same lock as menu
	// switching. A respawn keeps the window's fleet_id, but must not receive
	// an old connection's already queued input or resize.
	if primary.View != "" {
		ctx := c.ctx
		if ctx == nil {
			ctx = context.Background()
		}
		ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "tmux", "-L", primary.Socket, "display-message", "-p", "-t", primary.View+":", "#{window_id}|#{pane_id}|#{pane_pid}|#{pane_dead}|#{@fleet_id}|#{@cc_session_id}|#{@codex_session_id}|#{@claude_state}")
		b, err := cmd.Output()
		parts := strings.Split(strings.TrimSpace(string(b)), "|")
		if err != nil || len(parts) != 8 || parts[0] != primary.Window || strings.Join(parts[1:7], "|") != primary.Identity || parts[7] == "exited" {
			return errors.New("ended")
		}
	}
	return check()
}
