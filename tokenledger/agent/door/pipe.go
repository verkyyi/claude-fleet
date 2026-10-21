package door

// The door's browser listener (XX79): a browser terminal's bytes through the
// nearest door instead of the hub's region. The hub admits the person, picks
// the door and signs one ticket per half (control.SignDoorPipe, keyed with this
// door's token hash); the browser and the person's home each dial
// control.DoorPipePath with theirs, and the door joins the two and copies
// message for message. It reads no frame, keeps no byte and decides nothing:
// the home starts the terminal only on the hub's signed select and ends it at
// its lease's end, which closes the pipe from the home's side.

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/attachment"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// PipeConfig is the browser listener's part of a door.
type PipeConfig struct {
	// ID is this door's name in the hub's fleet.term_doors (tickets name it).
	ID string
	// Key is the door's token hash (control.ChatTokenHash of its token).
	Key string
	// Origins are the pages a browser half may come from (the console's
	// https://host). Empty = any; the ticket is the admission either way.
	Origins []string
	// Wait bounds how long a half waits for the other (default 10 s).
	Wait time.Duration
	// Max is how many pipes may be open or waiting at once (default 256).
	Max int
	// Now is the clock (tests).
	Now func() time.Time
}

// Pipes serves control.DoorPipePath and /healthz.
type Pipes struct {
	cfg   PipeConfig
	audit func(any)
	mu    sync.Mutex
	open  map[string]*pipeSlot // pipe → its waiting half
	spent map[string]time.Time // pipe/role → when its ticket expires
	live  int
}

type pipeSlot struct {
	role string
	conn *websocket.Conn
	peer chan *websocket.Conn // buffered 1: the second half hands itself over
	done chan struct{}        // closed when the joined pipe ends
}

// PipeLine is one pipe's record: never a byte of the terminal or a ticket.
type PipeLine struct {
	At     string `json:"at"`
	Door   string `json:"door"`
	Pipe   string `json:"pipe"`
	Result string `json:"result"`
	Why    string `json:"why,omitempty"`
	Up     int64  `json:"bytes_up,omitempty"`
	Down   int64  `json:"bytes_down,omitempty"`
	Secs   int64  `json:"secs,omitempty"`
}

// NewPipes is the browser listener; audit gets one PipeLine per pipe (nil = the log).
func NewPipes(cfg PipeConfig, audit func(any)) (*Pipes, error) {
	if !control.ValidDoorID(cfg.ID) || cfg.Key == "" {
		return nil, errors.New("door pipes: a door id (fleet.term_doors) and its token are required")
	}
	if cfg.Wait <= 0 {
		cfg.Wait = 10 * time.Second
	}
	if cfg.Max <= 0 {
		cfg.Max = 256
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if audit == nil {
		audit = func(v any) { b, _ := json.Marshal(v); log.Printf("door: %s", b) }
	}
	return &Pipes{cfg: cfg, audit: audit, open: map[string]*pipeSlot{}, spent: map[string]time.Time{}}, nil
}

// PipeAudit is a Server's audit sink for its pipes.
func (s *Server) PipeAudit(v any) {
	b, _ := json.Marshal(v)
	if s.cfg.Audit == nil {
		log.Printf("door: %s", b)
		return
	}
	s.auditMu.Lock()
	defer s.auditMu.Unlock()
	_, _ = s.cfg.Audit.Write(append(b, '\n'))
}

// Handler serves the pipe and the browser's probe.
func (p *Pipes) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz":
			// the browser's round-trip probe: no credential, nothing said
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte("ok\n"))
		case control.DoorPipePath:
			p.serve(w, r)
		default:
			http.NotFound(w, r)
		}
	})
}

func (p *Pipes) line(pipe, result, why string) PipeLine {
	return PipeLine{At: p.cfg.Now().UTC().Format(time.RFC3339), Door: p.cfg.ID, Pipe: pipe, Result: result, Why: why}
}

func (p *Pipes) originOK(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" || len(p.cfg.Origins) == 0 {
		return true
	}
	for _, want := range p.cfg.Origins {
		if strings.EqualFold(strings.TrimRight(want, "/"), o) {
			return true
		}
	}
	return false
}

// spend takes a ticket once: false for one already used.
func (p *Pipes) spend(t control.DoorPipeTicket, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for k, exp := range p.spent {
		if now.After(exp) {
			delete(p.spent, k)
		}
	}
	k := t.Pipe + "/" + t.Role
	if _, used := p.spent[k]; used {
		return false
	}
	p.spent[k] = time.Unix(t.Exp, 0)
	return true
}

func (p *Pipes) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		http.Error(w, "a websocket is required", http.StatusBadRequest)
		return
	}
	now := p.cfg.Now()
	t, err := control.VerifyDoorPipe(r.URL.Query().Get("t"), p.cfg.Key, p.cfg.ID, now)
	if err != nil {
		p.audit(p.line("", "refused", "ticket"))
		http.Error(w, "no such pipe", http.StatusForbidden)
		return
	}
	if t.Role == control.DoorPipeBrowser && !p.originOK(r) {
		p.audit(p.line(t.Pipe, "refused", "origin"))
		http.Error(w, "origin", http.StatusForbidden)
		return
	}
	if !p.spend(t, now) {
		p.audit(p.line(t.Pipe, "refused", "replayed"))
		http.Error(w, "no such pipe", http.StatusForbidden)
		return
	}
	// the browser half is a cross-origin page by design (the console is on
	// the hub's name): the ticket, not the origin, admits it
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	c.SetReadLimit(attachment.FrameMax + 1024)
	p.mu.Lock()
	slot := p.open[t.Pipe]
	switch {
	case slot == nil:
		if p.live >= p.cfg.Max {
			p.mu.Unlock()
			p.audit(p.line(t.Pipe, "refused", "full"))
			c.Close(websocket.StatusTryAgainLater, "door full")
			return
		}
		p.live++
		slot = &pipeSlot{role: t.Role, conn: c, peer: make(chan *websocket.Conn, 1), done: make(chan struct{})}
		p.open[t.Pipe] = slot
		p.mu.Unlock()
		p.first(r.Context(), t.Pipe, slot)
	case slot.role == t.Role:
		// both tickets are spent once each, so this cannot be a second
		// browser of the same pipe; refuse it all the same
		p.mu.Unlock()
		c.Close(websocket.StatusPolicyViolation, "half already here")
	default:
		delete(p.open, t.Pipe)
		p.mu.Unlock()
		slot.peer <- c
		<-slot.done
	}
}

// first holds the pipe's first half until the second arrives, then copies.
func (p *Pipes) first(ctx context.Context, pipe string, slot *pipeSlot) {
	defer close(slot.done)
	defer func() { p.mu.Lock(); p.live--; p.mu.Unlock() }()
	timer := time.NewTimer(p.cfg.Wait)
	defer timer.Stop()
	var other *websocket.Conn
	select {
	case other = <-slot.peer:
	case <-timer.C:
	case <-ctx.Done():
	}
	if other == nil {
		p.mu.Lock()
		if p.open[pipe] == slot {
			delete(p.open, pipe)
		}
		p.mu.Unlock()
		// the second half may have been handed over just now
		select {
		case other = <-slot.peer:
		default:
		}
	}
	if other == nil {
		p.audit(p.line(pipe, "unpaired", "the other half never came"))
		slot.conn.Close(websocket.StatusGoingAway, "the other half never came")
		return
	}
	browser, home := slot.conn, other
	if slot.role == control.DoorPipeHome {
		browser, home = other, slot.conn
	}
	start := p.cfg.Now()
	up, down, why := splicePipe(browser, home)
	l := p.line(pipe, "joined", why)
	l.Up, l.Down, l.Secs = up, down, int64(p.cfg.Now().Sub(start).Seconds())
	p.audit(l)
}

// splicePipe copies messages both ways until either side ends; each side is
// pinged so a half-open one goes within 20 s.
func splicePipe(browser, home *websocket.Conn) (up, down int64, why string) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var once sync.Once
	end := func(w string) { once.Do(func() { why = w; cancel() }) }
	var wg sync.WaitGroup
	copyOne := func(from, to *websocket.Conn, n *int64, name string) {
		defer wg.Done()
		for {
			t, b, err := from.Read(ctx)
			if err != nil {
				end(name + " closed")
				return
			}
			if len(b) > attachment.FrameMax {
				end("oversized frame")
				return
			}
			wctx, wcancel := context.WithTimeout(ctx, 30*time.Second)
			err = to.Write(wctx, t, b)
			wcancel()
			if err != nil {
				end(name + " stopped reading")
				return
			}
			if t == websocket.MessageBinary {
				*n += int64(len(b))
			}
		}
	}
	ping := func(c *websocket.Conn, name string) {
		defer wg.Done()
		tk := time.NewTicker(10 * time.Second)
		defer tk.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tk.C:
				pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
				err := c.Ping(pctx)
				pcancel()
				if err != nil {
					end(name + " stopped answering")
					return
				}
			}
		}
	}
	wg.Add(4)
	go copyOne(browser, home, &up, "browser")
	go copyOne(home, browser, &down, "home")
	go ping(browser, "browser")
	go ping(home, "home")
	<-ctx.Done()
	browser.Close(websocket.StatusNormalClosure, "")
	home.Close(websocket.StatusNormalClosure, "")
	wg.Wait()
	return up, down, why
}
