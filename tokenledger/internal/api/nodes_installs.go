package api

import (
	"regexp"
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A machine's 「安装」 (claude-fleet#2697): every heard login's beat carries
// its own reading of fleet-installs.sh — the machine runtime, its login
// install, its client shell and client install. The machine folds them: the
// runtime from the newest reading that has one, each login from
// its own newest, then every item judged against the stable this hub follows.

type installsLogin struct {
	at time.Time
	li control.LoginInstall
}

type installsPick struct {
	stable    string
	runtime   *control.InstallItem
	runtimeAt time.Time
	at        time.Time
	logins    map[string]installsLogin
}

func (p *installsPick) add(in *control.Installs) {
	var at time.Time
	if in.At != nil {
		at = *in.At
	}
	if at.After(p.at) || p.at.IsZero() {
		p.at = at
		if in.Stable != "" {
			p.stable = in.Stable
		}
	}
	if in.Runtime != nil && (p.runtime == nil || !at.Before(p.runtimeAt)) {
		p.runtime, p.runtimeAt = in.Runtime, at
	}
	for _, l := range in.Logins {
		if old, ok := p.logins[l.Login]; !ok || !at.Before(old.at) {
			p.logins[l.Login] = installsLogin{at: at, li: l}
		}
	}
}

// judged is the machine's installs with every at_stable the hub's own:
// stable, on every platform (one release line, claude-fleet#4671). With no
// stable here the scripts' own word stands.
func (p *installsPick) judged(stable string) *control.Installs {
	want := stable
	if want == "" {
		want = p.stable
	}
	out := &control.Installs{Stable: want}
	if !p.at.IsZero() {
		at := p.at
		out.At = &at
	}
	// the script's 落后 counts from when it saw ITS stable: kept only when
	// that is the one judged here
	keep := p.stable != "" && sameCommit(p.stable, want) != nil && *sameCommit(p.stable, want)
	j := func(it *control.InstallItem) *control.InstallItem { return judgeInstall(it, want, stable != "", keep) }
	out.Runtime = j(p.runtime)
	names := make([]string, 0, len(p.logins))
	for n := range p.logins {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		l := p.logins[n].li
		out.Logins = append(out.Logins, control.LoginInstall{
			Login:   l.Login,
			Install: j(l.Install),
			Shell:   j(l.Shell),
			Client:  j(l.Client),
		})
	}
	return out
}

// judgeInstall copies one item with at_stable judged against want; with no
// hub stable (own false) the script's word is kept. Its behind_secs stays
// only on an item still behind, and only when keep (the same stable).
func judgeInstall(it *control.InstallItem, want string, own, keep bool) *control.InstallItem {
	if it == nil {
		return nil
	}
	c := *it
	if own && want != "" {
		c.AtStable = sameCommit(c.Version, want)
	}
	if c.AtStable == nil || *c.AtStable || (own && !keep) {
		c.BehindSecs = nil
	}
	return &c
}

var installCommitRe = regexp.MustCompile(`^[0-9a-f]{7,40}$`)

// sameCommit compares two shas on their common prefix (≥ 7); nil when either
// is not a commit (a "-" version, an unknown stable).
func sameCommit(a, b string) *bool {
	if !installCommitRe.MatchString(a) || !installCommitRe.MatchString(b) {
		return nil
	}
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	if n < 7 {
		return nil
	}
	eq := a[:n] == b[:n]
	return &eq
}
