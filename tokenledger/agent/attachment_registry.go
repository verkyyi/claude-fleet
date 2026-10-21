package agent

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

type attachmentEntry struct {
	grant  control.AttachmentGrant
	cancel context.CancelFunc
	done   chan struct{}
}
type attachmentRegistry struct {
	mu       sync.Mutex
	active   map[string]*attachmentEntry
	replaced map[string]replacement
}

// replacement is who took a predecessor's place, and when.
type replacement struct {
	at time.Time
	by string
}

// A late transport failure needs a fresh authorization. Its successor first
// cancels and WAITS for the old adapter's cleanup. Closing an old connection
// removes only its own entry; two replacements cannot both win one predecessor.
func (r *attachmentRegistry) begin(ctx context.Context, g control.AttachmentGrant, cancel context.CancelFunc) (func(), error) {
	r.mu.Lock()
	if r.active == nil {
		r.active = map[string]*attachmentEntry{}
		r.replaced = map[string]replacement{}
	}
	for k, rp := range r.replaced {
		if time.Since(rp.at) > termGrantSpentTTL {
			delete(r.replaced, k)
		}
	}
	if r.active[g.Conn] != nil {
		r.mu.Unlock()
		return nil, errors.New("attachment already active")
	}
	var old *attachmentEntry
	if g.Previous != "" {
		// Two successors never both win one predecessor. A successor that is
		// gone already (its try answered interrupted / ended) won nothing: the
		// page retrying with the same predecessor gets through (RMVE).
		if rp, used := r.replaced[g.Previous]; used && r.active[rp.by] != nil {
			r.mu.Unlock()
			return nil, errors.New("attachment already replaced")
		}
		old = r.active[g.Previous]
		if old != nil && (old.grant.Person != g.Person || old.grant.Home != g.Home || old.grant.Login != g.Login || old.grant.Service != g.Service || old.grant.Target != g.Target || old.grant.Generation != g.Generation) {
			r.mu.Unlock()
			return nil, errors.New("replacement target differs")
		}
		r.replaced[g.Previous] = replacement{at: time.Now(), by: g.Conn}
	}
	e := &attachmentEntry{grant: g, cancel: cancel, done: make(chan struct{})}
	r.active[g.Conn] = e
	r.mu.Unlock()
	var once sync.Once
	finish := func() {
		once.Do(func() {
			r.mu.Lock()
			if r.active[g.Conn] == e {
				delete(r.active, g.Conn)
			}
			close(e.done)
			r.mu.Unlock()
		})
	}
	if old != nil {
		old.cancel()
		select {
		case <-old.done:
		case <-ctx.Done():
			finish()
			return nil, ctx.Err()
		case <-time.After(8 * time.Second):
			finish()
			return nil, errors.New("previous attachment cleanup timed out")
		}
	}
	return finish, nil
}
