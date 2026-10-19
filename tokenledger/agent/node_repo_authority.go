package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A repo's task authority, pushed (claude-fleet#4730).
//
// A cutover run on one host rewrote only that host's overlay, so another host
// of the same repo kept reading legacy. The hub now sends TypeRepoAuthority to
// every capable host when the authority moves, and on each connection's first
// beat; the agent answers by running claude-fleet's
// `fleet-hub-node.sh authority-sync <repo>`, which reads the mode back from the
// hub with this login's own credential and rewrites the repo's overlays. A
// re-read that fails runs again on the next beat until one succeeds; a
// revision already synced is not run again. A claude-fleet that does not list
// repo_authority_sync in its paths is never asked.

// authorityTimeout bounds one re-read: one hub GET plus an overlay rewrite.
const authorityTimeout = 60 * time.Second

// authorityCommand is the injection point for tests.
var authorityCommand = relayCommand

type authorityWant struct {
	want, done int64
	running    bool
	lastLog    string
}

type authorityFollow struct {
	mu     sync.Mutex
	script string
	repos  map[string]*authorityWant
}

// handleRepoAuthority takes the hub's TypeRepoAuthority.
func (a *Agent) handleRepoAuthority(ctx context.Context, script string, m control.Message) {
	var r control.RepoAuthority
	if err := json.Unmarshal(m.Payload, &r); err != nil || r.Repo == "" || r.Revision <= 0 ||
		strings.Count(r.Repo, "/") != 1 || strings.HasPrefix(r.Repo, "-") {
		return
	}
	st := &a.authority
	st.mu.Lock()
	st.script = script
	if st.repos == nil {
		st.repos = map[string]*authorityWant{}
	}
	w := st.repos[r.Repo]
	if w == nil {
		w = &authorityWant{}
		st.repos[r.Repo] = w
	}
	if r.Revision != w.done {
		w.want = r.Revision
	}
	st.mu.Unlock()
	a.authorityKick(ctx)
}

// authorityKick starts a re-read for every repo whose last pushed revision has
// not been synced and none is running. The beat loop calls it: that is the retry.
func (a *Agent) authorityKick(ctx context.Context) {
	st := &a.authority
	st.mu.Lock()
	defer st.mu.Unlock()
	for repo, w := range st.repos {
		if w.running || w.want == 0 || w.want == w.done {
			continue
		}
		w.running = true
		go a.authoritySync(ctx, st.script, repo, w, w.want)
	}
}

func (a *Agent) authoritySync(ctx context.Context, script, repo string, w *authorityWant, rev int64) {
	// Not the connection's: a link that drops mid-write must not cut it short.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), authorityTimeout)
	defer cancel()
	cmd := authorityCommand(ctx, script, "authority-sync", repo)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	msg := ""
	if err != nil {
		msg = strings.TrimSpace(out.String())
		if i := strings.LastIndexByte(msg, '\n'); i >= 0 {
			msg = msg[i+1:]
		}
		if msg == "" {
			msg = err.Error()
		}
	}
	st := &a.authority
	st.mu.Lock()
	defer st.mu.Unlock()
	w.running = false
	if err == nil {
		w.done = rev
	}
	if msg != w.lastLog {
		if msg != "" {
			log.Printf("repo authority %s r%d: re-read failed (retried next beat): %s", repo, rev, msg)
		} else if w.lastLog != "" {
			log.Printf("repo authority %s r%d: synced", repo, rev)
		}
		w.lastLog = msg
	}
}
