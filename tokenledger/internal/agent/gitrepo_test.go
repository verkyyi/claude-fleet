package agent

import (
	"context"
	"os"
	"os/exec"
	"sync"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// The shapes a real `git remote get-url origin` comes back with, and every
// shape that must NOT become an owner/name. The refusals are the half that
// matters: a wrong repository is indistinguishable from a right one once it is
// a column, and it puts one team's money on another team's issue number.
func TestRepoFromRemote(t *testing.T) {
	for _, tc := range []struct {
		name, url, want string
	}{
		// The forms git actually emits.
		{"scp", "git@github.com:verkyyi/tokenledger.git", "verkyyi/tokenledger"},
		{"scp no user", "github.com:verkyyi/tokenledger.git", "verkyyi/tokenledger"},
		{"scp no suffix", "git@github.com:verkyyi/tokenledger", "verkyyi/tokenledger"},
		{"https", "https://github.com/verkyyi/tokenledger.git", "verkyyi/tokenledger"},
		{"https no suffix", "https://github.com/verkyyi/tokenledger", "verkyyi/tokenledger"},
		{"https with token user", "https://x-token@github.com/verkyyi/tokenledger.git", "verkyyi/tokenledger"},
		{"ssh scheme with port", "ssh://git@github.com:22/verkyyi/tokenledger.git", "verkyyi/tokenledger"},
		{"git scheme", "git://github.com/verkyyi/tokenledger.git", "verkyyi/tokenledger"},
		{"trailing slash", "https://github.com/verkyyi/tokenledger/", "verkyyi/tokenledger"},
		{"trailing newline", "git@github.com:verkyyi/tokenledger.git\n", "verkyyi/tokenledger"},
		{"enterprise host", "git@git.corp.example.com:platform/api.git", "platform/api"},
		{"ssh config alias", "gh:verkyyi/tokenledger.git", "verkyyi/tokenledger"},

		// A local remote is a real remote and names no repository. Splitting
		// it on "/" yields something that LOOKS like owner/name, which is the
		// whole danger: nothing downstream could tell it from a real one.
		{"absolute path", "/srv/git/repos/app.git", ""},
		{"relative path", "../sibling", ""},
		{"file scheme", "file:///srv/git/repos/app.git", ""},
		{"windows path", `C:\src\app`, ""},
		{"windows mixed separators", `C:\src/app`, ""},

		// Nothing to join on, or more than the key can hold.
		{"single segment", "https://github.com/tokenledger.git", ""},
		{"nested group", "https://gitlab.com/group/sub/app.git", ""},
		{"host only", "https://github.com/", ""},
		{"empty", "", ""},
		{"blank", "   \n", ""},
		{"space in name", "git@github.com:verkyyi/token ledger.git", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := RepoFromRemote(tc.url)
			if tc.want == "" {
				if ok || got != "" {
					t.Fatalf("RepoFromRemote(%q) = %q, %v; want refusal", tc.url, got, ok)
				}
				return
			}
			if !ok || got != tc.want {
				t.Fatalf("RepoFromRemote(%q) = %q, %v; want %q", tc.url, got, ok, tc.want)
			}
		})
	}
}

// Whatever this emits has to be a key the repo side could actually hold —
// otherwise the column fills with strings that join with nothing and look, to
// a reader, exactly like a repository nobody shipped progress for.
func TestRepoFromRemote_EmitsOnlyJoinableNames(t *testing.T) {
	for _, url := range []string{
		"git@github.com:verkyyi/tokenledger.git",
		"https://github.com/a/b",
		"ssh://git@git.corp.example.com:2222/platform/api.git",
	} {
		repo, ok := RepoFromRemote(url)
		if !ok {
			t.Fatalf("RepoFromRemote(%q) refused", url)
		}
		if err := model.ValidRepoName(repo); err != nil {
			t.Fatalf("RepoFromRemote(%q) = %q, which the repo side rejects: %v", url, repo, err)
		}
	}
}

// fakeGit replaces the git call with a scripted one, and counts how often each
// path was asked about.
func fakeGit(t *testing.T, answers map[string]string) (restore func(), calls func(string) int) {
	t.Helper()
	var mu sync.Mutex
	seen := map[string]int{}
	prev := gitCommand
	gitCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
		// `git -C <cwd> remote get-url origin`
		cwd := arg[1]
		mu.Lock()
		seen[cwd]++
		out, ok := answers[cwd]
		mu.Unlock()
		if !ok {
			return exec.CommandContext(ctx, "false")
		}
		return exec.CommandContext(ctx, "printf", "%s", out)
	}
	return func() { gitCommand = prev }, func(cwd string) int {
		mu.Lock()
		defer mu.Unlock()
		return seen[cwd]
	}
}

// Once per distinct cwd, not once per event. A first scan carries tens of
// thousands of turns across a few hundred paths; a git process per turn would
// make declaring the repository cost more than collecting the usage.
func TestResolveAsksGitOncePerPath(t *testing.T) {
	restore, calls := fakeGit(t, map[string]string{
		"/w/tokenledger": "git@github.com:verkyyi/tokenledger.git\n",
	})
	defer restore()

	var r repoResolver
	for i := 0; i < 5; i++ {
		if got := r.Resolve(context.Background(), "/w/tokenledger"); got != "verkyyi/tokenledger" {
			t.Fatalf("Resolve = %q", got)
		}
	}
	if n := calls("/w/tokenledger"); n != 1 {
		t.Fatalf("asked git %d times for one path; want 1", n)
	}
}

// A path that is not a checkout is cached too — for a while. The whole point of
// the TTL is that a first scan's hundreds of dead paths cost one process each,
// while a `git clone` that lands in a directory this already saw is not
// permanently undeclared.
func TestResolveCachesTheRefusalToo(t *testing.T) {
	restore, calls := fakeGit(t, nil)
	defer restore()

	var r repoResolver
	for i := 0; i < 3; i++ {
		if got := r.Resolve(context.Background(), "/w/not-a-checkout"); got != "" {
			t.Fatalf("Resolve = %q; want the empty declaration", got)
		}
	}
	if n := calls("/w/not-a-checkout"); n != 1 {
		t.Fatalf("asked git %d times; want 1 inside the negative TTL", n)
	}

	// Past the TTL it asks again, and can now see what was cloned meanwhile.
	r.mu.Lock()
	a := r.cache["/w/not-a-checkout"]
	a.at = a.at.Add(-2 * repoNegativeTTL)
	r.cache["/w/not-a-checkout"] = a
	r.mu.Unlock()
	if got := r.Resolve(context.Background(), "/w/not-a-checkout"); got != "" {
		t.Fatalf("Resolve = %q", got)
	}
	if n := calls("/w/not-a-checkout"); n != 2 {
		t.Fatalf("asked git %d times; want a retry once the TTL lapsed", n)
	}
}

// Two cwds are two repositories, and neither borrows the other's answer. This
// is the fleet's own shape: a worktree per issue, several repositories at once.
func TestStampReposDeclaresPerDirectory(t *testing.T) {
	restore, _ := fakeGit(t, map[string]string{
		"/w/tokenledger":  "git@github.com:verkyyi/tokenledger.git\n",
		"/w/claude-fleet": "https://github.com/verkyyi/claude-fleet.git\n",
	})
	defer restore()

	evs := []model.UsageEvent{
		{CWD: "/w/tokenledger"},
		{CWD: "/w/claude-fleet"},
		{CWD: "/w/scratch"}, // not a checkout
		{CWD: ""},           // no cwd at all
		{CWD: "/w/tokenledger", GitRepo: "someone/else"}, // already declared
	}
	var r repoResolver
	r.stampRepos(context.Background(), evs)

	want := []string{"verkyyi/tokenledger", "verkyyi/claude-fleet", "", "", "someone/else"}
	for i := range evs {
		if evs[i].GitRepo != want[i] {
			t.Errorf("event %d (cwd %q): GitRepo = %q; want %q", i, evs[i].CWD, evs[i].GitRepo, want[i])
		}
	}
}

// The declaration is the endpoint's own reading of its own checkout, so the
// real git has to agree with the parser. Skipped where git is absent.
func TestResolveAgainstRealGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"remote", "add", "origin", "git@github.com:verkyyi/tokenledger.git"},
	} {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Skipf("git %v: %v (%s)", args, err, out)
		}
	}
	var r repoResolver
	if got := r.Resolve(context.Background(), dir); got != "verkyyi/tokenledger" {
		t.Fatalf("Resolve(%s) = %q; want verkyyi/tokenledger", dir, got)
	}
	// A directory that is not a checkout declares nothing, and does not
	// inherit the answer from the one beside it.
	if got := r.Resolve(context.Background(), t.TempDir()); got != "" {
		t.Fatalf("Resolve(non-checkout) = %q; want the empty declaration", got)
	}
}
