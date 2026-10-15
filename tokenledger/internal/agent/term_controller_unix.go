//go:build unix

package agent

import (
	"encoding/json"
	"errors"
	"os"
	"syscall"
	"time"
)

// The Python helper's takeover, menu selection and cleanup use THIS flock.
// Checking an epoch then releasing the lock before the write is not fencing.
func (c termController) apply(f func() error) error {
	if c.Lock == "" {
		return f()
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
	if lease.Selected != "" {
		path, epoch := lease.Selected, lease.SelectedEpoch
		if !read(path) || lease.Epoch != epoch {
			return errors.New("open_elsewhere")
		}
	}
	return f()
}
