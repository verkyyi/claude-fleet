package agent

import (
	"context"
	"log"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// The repository a turn was spent in, declared at the source.
//
// Design: docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md §6.
//
// §5 of that design left cost-per-issue gated behind a refusal: a spend row
// carries an issue NUMBER and no repository, every repository starts its issues
// at #1, and `owner/name` appears nowhere on the spend side because the hub was
// never told which repository a `cwd` is. So the read could only answer while
// the hub happened to hold exactly the one repository being asked about.
//
// This is the binding that removes it, and the reason it belongs HERE rather
// than on the hub: the agent runs inside the checkout. `git -C <cwd> remote
// get-url origin` is a local fact at the source, resolved once per distinct
// cwd, and it travels as one more field the reporter recorded. The hub still
// shells out to nothing -- it stores what it was told, which is the existing
// stance and not a new exception to it.
//
// Resolved AT SCAN TIME, which is the honest caveat: a path that has since been
// re-cloned as a different repository stamps today's answer onto yesterday's
// turns. That is the same denormalisation `cwd` and `os_user` already make, and
// the alternative -- asking git what a directory used to be -- does not exist.

// repoNegativeTTL is how long "this cwd is not a repository" is trusted before
// asking again.
//
// Positive answers are cached for the life of the process: a checkout's origin
// is the most stable thing about it. Negatives are not symmetrical -- a
// directory that was not a checkout five minutes ago is exactly what a fresh
// `git clone` or a new worktree looks like, and this fleet makes one per issue.
// Retrying every cycle would instead spawn a process per dead path on every
// scan, and a first scan can carry hundreds of paths that no longer exist.
const repoNegativeTTL = 10 * time.Minute

// repoCacheMax bounds the cache. A long-lived agent on a machine that creates a
// worktree per issue accumulates paths forever; past this the cache is dropped
// whole rather than grown, which costs one re-resolution round and cannot leak.
const repoCacheMax = 4096

// gitCommand is the injection point for tests, mirroring internal/codex/rpc.go.
var gitCommand = exec.CommandContext

// repoResolver answers "which repository is this working directory" once per
// distinct path.
//
// The zero value is ready to use and is safe for concurrent use: the Claude and
// Codex collectors run in the same process and see overlapping paths.
type repoResolver struct {
	mu      sync.Mutex
	cache   map[string]repoAnswer
	noGit   bool // git is not on PATH; stop asking and say so once
	checked bool
}

type repoAnswer struct {
	repo string    // "" = no answer
	at   time.Time // when the answer was taken, for the negative TTL
}

// stampRepos fills GitRepo on a batch of events, one git call per distinct cwd.
//
// A turn whose cwd is not a checkout, or whose origin is something
// RepoFromRemote will not read, stays UNDECLARED. It is never guessed at and
// never borrowed from a neighbouring event: two directories on one machine are
// routinely two different repositories, and a wrong repo is worse than none --
// it puts one team's money on another team's issue number.
func (r *repoResolver) stampRepos(ctx context.Context, evs []model.UsageEvent) {
	for i := range evs {
		if evs[i].CWD == "" || evs[i].GitRepo != "" {
			continue
		}
		evs[i].GitRepo = r.Resolve(ctx, evs[i].CWD)
	}
}

// Resolve returns `owner/name` for a working directory, or "" when it cannot
// say. It shells out at most once per path per TTL.
func (r *repoResolver) Resolve(ctx context.Context, cwd string) string {
	if cwd == "" {
		return ""
	}
	now := time.Now()

	r.mu.Lock()
	if r.noGit {
		r.mu.Unlock()
		return ""
	}
	if a, ok := r.cache[cwd]; ok && (a.repo != "" || now.Sub(a.at) < repoNegativeTTL) {
		r.mu.Unlock()
		return a.repo
	}
	if !r.checked {
		r.checked = true
		if _, err := exec.LookPath("git"); err != nil {
			r.noGit = true
			r.mu.Unlock()
			log.Printf("git is not on PATH: turns will not declare which repository they were spent in (%v)", err)
			return ""
		}
	}
	r.mu.Unlock()

	repo := r.ask(ctx, cwd)

	r.mu.Lock()
	if r.cache == nil || len(r.cache) >= repoCacheMax {
		r.cache = make(map[string]repoAnswer, 64)
	}
	r.cache[cwd] = repoAnswer{repo: repo, at: now}
	r.mu.Unlock()
	return repo
}

// ask runs the one git command, under a deadline.
//
// A hung git is not hypothetical: `origin` can point at a path on an unmounted
// network share, and `remote get-url` still stats it. The collector loop must
// not be the thing that waits.
func (r *repoResolver) ask(ctx context.Context, cwd string) string {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	cmd := gitCommand(ctx, "git", "-C", cwd, "remote", "get-url", "origin")
	// No terminal, no credential helper, no config from anywhere but the
	// checkout: this is a read of one local string, and it must not become an
	// interactive prompt on a headless machine.
	cmd.Env = append(cmd.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0")
	out, err := cmd.Output()
	if err != nil {
		// Not a checkout, no origin, deleted path, or git said no. All of them
		// mean the same thing downstream: undeclared.
		return ""
	}
	repo, _ := RepoFromRemote(string(out))
	return repo
}

// RepoFromRemote reads `owner/name` out of a git remote URL.
//
// The rule is anchored on a URL that names a HOST, and nothing else:
//
//	scheme://[user@]host[:port]/owner/name[.git]   (ssh, git, https, http)
//	[user@]host:owner/name[.git]                   (the scp-like form)
//
// Everything it declines is undeclared. The refusals are the point, and they
// are the same stance IssueFromBranch takes on branch names -- a wrong reading
// here is indistinguishable from a right one once it is a column:
//
//   - A filesystem path (`/srv/git/repos/app.git`, `../sibling`, `C:\src\app`)
//     is a real remote and names no repository. Splitting it on `/` yields
//     `repos/app`, which is a plausible `owner/name` and a fabrication.
//   - `file://` is that same fabrication with a scheme in front of it.
//   - A single-segment path has no owner. There is nothing to join on.
//   - A path with MORE than two segments -- a nested GitLab group,
//     `group/sub/app` -- is not an `owner/name` and is not truncated into one.
//     `sub/app` is exactly the plausible fabrication above wearing a better
//     suit: it is a valid-looking key that no shipper sends. Such a checkout
//     stays undeclared until the repo ingest protocol has a key that can hold
//     it, and changing that protocol is explicitly out of scope here.
//
// The HOST is read and then dropped, deliberately. `repo_issues` is keyed
// `(repo, number)` with repo as a bare `owner/name` (that is what a shipper
// sends), so emitting a host-qualified name here would join with nothing. The
// ambiguity that leaves -- github.com/a/b and gitlab.com/a/b are one key --
// already exists in the repo ingest protocol, in the same way and for the same
// reason.
//
// No case folding and no other normalisation: the string has to be byte-equal
// to what the shipper sends, and inventing a canonical form here would be this
// side guessing at the other side's. The result is checked by the SAME
// model.ValidRepoName the repo ingest uses, so this side cannot emit a key the
// other side would have rejected.
func RepoFromRemote(url string) (string, bool) {
	s := strings.TrimSpace(url)
	if s == "" {
		return "", false
	}

	var path string
	if scheme, rest, ok := strings.Cut(s, "://"); ok {
		switch strings.ToLower(scheme) {
		case "ssh", "git", "https", "http":
		default:
			// file://, and anything else that does not carry a host.
			return "", false
		}
		host, p, ok := strings.Cut(rest, "/")
		if !ok {
			return "", false
		}
		// Userinfo only counts before the first slash; an `@` further along is
		// part of the path, not a login.
		if _, after, ok := strings.Cut(host, "@"); ok {
			host = after
		}
		if host == "" {
			return "", false
		}
		path = p
	} else {
		// scp-like. The colon must come before any slash, otherwise this is a
		// path that merely contains one.
		host, p, ok := strings.Cut(s, ":")
		if !ok || strings.Contains(host, "/") {
			return "", false
		}
		if _, after, ok := strings.Cut(host, "@"); ok {
			host = after
		}
		if host == "" {
			return "", false
		}
		path = p
	}

	path = strings.Trim(path, "/")
	path = strings.TrimSuffix(path, ".git")
	path = strings.Trim(path, "/")
	if path == "" {
		return "", false
	}
	if strings.ContainsAny(path, " \t\r\n\\") {
		return "", false
	}
	if err := model.ValidRepoName(path); err != nil {
		return "", false
	}
	return path, true
}
