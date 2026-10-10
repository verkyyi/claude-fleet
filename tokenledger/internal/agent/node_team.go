package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The team layer, pushed (claude-fleet#1899, EPIC #1906 C6).
//
// The hub sends TypeTeam with the current team version on the first beat of a
// connection, whenever it moves, and the moment the operator PUTs one. The
// agent answers by running this login's claude-fleet
// bin/fleet-agent-team.py sync --hub-version N — the same entry install-sync's
// tick runs, so the composing, the credential checks and the record are
// claude-fleet's, never re-done here. A sync that fails is run again on the
// next beat, until one succeeds; a version already synced on this agent is not
// run again when a reconnect repeats it. Without the script the agent never
// lists CapTeam, so the hub sends nothing and nothing changes.
//
// A person's own layer follows the same way (claude-fleet#2784, EPIC #2781
// C3): TypePerson carries the version of the person this login is bound to,
// and the same sync runs with --person-version N — one follower per layer,
// each with its own want / done, so neither one's retry holds the other.

var fleetTeamScript = filepath.Join(".claude", "fleet", "bin", "fleet-agent-team.py")

// fleetTeamTimeout bounds one sync: a fetch (8 s by default) plus composing
// the login's files.
const fleetTeamTimeout = 90 * time.Second

// teamCommand is the injection point for tests, like fleetCommand.
var teamCommand = fleetCommand

type teamFollow struct {
	// flag and name say which layer: --hub-version / team, --person-version / person.
	flag, name string

	mu      sync.Mutex
	want    int // the version the hub last said
	done    int // the version a sync last finished for
	running bool
	lastLog string
}

func (a *Agent) team() *teamFollow {
	a.teamOnce.Do(func() { a.teamState = &teamFollow{flag: "--hub-version", name: "team"} })
	return a.teamState
}

func (a *Agent) person() *teamFollow {
	a.personOnce.Do(func() { a.personState = &teamFollow{flag: "--person-version", name: "person"} })
	return a.personState
}

// teamCapable reports whether this login can follow a pushed team version.
func (a *Agent) teamCapable() bool {
	_, err := os.Stat(filepath.Join(a.cfg.Home, fleetTeamScript))
	return err == nil
}

// handleTeam takes the hub's TypeTeam.
func (a *Agent) handleTeam(ctx context.Context, m control.Message) {
	var t control.Team
	if err := json.Unmarshal(m.Payload, &t); err != nil || t.TeamVersion <= 0 {
		return
	}
	st := a.team()
	st.mu.Lock()
	st.want = t.TeamVersion
	st.mu.Unlock()
	a.kickLayer(ctx, st)
}

// handlePerson takes the hub's TypePerson (claude-fleet#2784).
func (a *Agent) handlePerson(ctx context.Context, m control.Message) {
	var p control.Person
	if err := json.Unmarshal(m.Payload, &p); err != nil || p.Version <= 0 {
		return
	}
	st := a.person()
	st.mu.Lock()
	st.want = p.Version
	st.mu.Unlock()
	a.kickLayer(ctx, st)
}

// teamKick starts a sync when the hub's version has not been synced and none
// is running — for the team layer and the person's. The beat loop calls it
// every tick: that is the retry.
func (a *Agent) teamKick(ctx context.Context) {
	a.kickLayer(ctx, a.team())
	a.kickLayer(ctx, a.person())
}

func (a *Agent) kickLayer(ctx context.Context, st *teamFollow) {
	st.mu.Lock()
	if st.running || st.want <= 0 || st.want == st.done {
		st.mu.Unlock()
		return
	}
	st.running = true
	v := st.want
	st.mu.Unlock()
	go func() {
		ok, note := a.teamSync(ctx, st.flag, v)
		st.mu.Lock()
		st.running = false
		if ok {
			st.done = v
		}
		msg := ""
		if !ok {
			msg = note
		}
		if msg != st.lastLog {
			// A failure once per distinct reason; the success after it once.
			if msg != "" {
				log.Printf("%s v%d: sync failed (retried next beat): %s", st.name, v, msg)
			} else if st.lastLog != "" {
				log.Printf("%s v%d: synced", st.name, v)
			}
			st.lastLog = msg
		}
		st.mu.Unlock()
	}()
}

// teamSync runs fleet-agent-team.py sync <flag> v. ok = exit 0, or 3 (no
// hub configured on this login: nothing to retry until its conf changes).
func (a *Agent) teamSync(ctx context.Context, flag string, v int) (bool, string) {
	script := filepath.Join(a.cfg.Home, fleetTeamScript)
	if _, err := os.Stat(script); err != nil {
		return true, ""
	}
	// Not the connection's: a link that drops mid-sync must not kill a
	// compose halfway through the login's files.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), fleetTeamTimeout)
	defer cancel()
	cmd := teamCommand(ctx, script, "sync", flag, strconv.Itoa(v))
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	if err == nil {
		return true, ""
	}
	if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 3 {
		return true, ""
	}
	last := strings.TrimSpace(out.String())
	if i := strings.LastIndexByte(last, '\n'); i >= 0 {
		last = last[i+1:]
	}
	if last == "" {
		last = err.Error()
	}
	return false, last
}
