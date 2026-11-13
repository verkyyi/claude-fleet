package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
)

// A Codex profile's credential work — renewal (codex.Maintain) and the account
// read (codex.Query) — starts the Codex CLI and writes the profile's lock and
// records. A plain agent does it in process, as its own login. A machine
// tenant (claude-fleet#2333) does it AS the login: `ccquota codex machine-op`,
// this same binary, started through prepCmd with the login's credential and a
// clean environment, reads its request on stdin and answers on stdout. Root
// then never starts a program found in a login's home, and never writes there
// for Codex. Root itself only picks the Codex the release ships (or the one the
// machine's own configuration names); with neither, the login's command picks
// as the login would.

// codexAccount maintains and queries one profile's credential.
type codexAccount interface {
	maintain(ctx context.Context, binary, home string, force bool) (*codex.Auth, error)
	// query reads the account with auth's credential and records the
	// upstream's verdict; refresh: renewed and read again once when the
	// upstream refused the access token.
	query(ctx context.Context, binary, home string, auth *codex.Auth, refresh bool) (codex.Result, error)
}

func (a *Agent) newCodexAccount() codexAccount {
	if a.cfg.RunAs != nil {
		return loginCodex{ra: a.cfg.RunAs}
	}
	return localCodex{}
}

// codexBinary is the Codex CLI the account work is handed: a plain agent's as
// before (configured, else ~/.local/bin, Homebrew, PATH); a machine tenant's
// only from the machine's own side (see machineCodexBinary).
func (a *Agent) codexBinary() string {
	if a.cfg.RunAs != nil {
		return machineCodexBinary(a.cfg.CodexBinary)
	}
	return codex.Binary(a.cfg.Home, a.cfg.CodexBinary)
}

// machineCodexBinary is what root names for a login's Codex: the machine's
// configured CCQUOTA_CODEX_BINARY, else the release's own tools/bin/codex
// beside this program's bin/, else "" — the login's own command resolves it.
// Never a path looked up in a login's home or on a login's PATH.
func machineCodexBinary(configured string) string {
	if configured != "" {
		return configured
	}
	if p := releaseCodex(); p != "" {
		return p
	}
	return ""
}

// releaseTools is the release's tools/bin (beside this program's bin/), "" when
// there is none.
func releaseTools() string {
	self, err := codexOpSelf()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(self); err == nil {
		self = r
	}
	dir := filepath.Join(filepath.Dir(filepath.Dir(self)), "tools", "bin")
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return ""
	}
	return dir
}

func releaseCodex() string {
	dir := releaseTools()
	if dir == "" {
		return ""
	}
	p := filepath.Join(dir, "codex")
	if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode()&0o111 != 0 {
		return p
	}
	return ""
}

// localCodex is the plain agent's: in process, as itself.
type localCodex struct{}

func (localCodex) maintain(ctx context.Context, binary, home string, force bool) (*codex.Auth, error) {
	return codex.Maintain(ctx, binary, home, force)
}

func (localCodex) query(ctx context.Context, binary, home string, auth *codex.Auth, refresh bool) (codex.Result, error) {
	return queryCodex(ctx, binary, home, auth, refresh)
}

func queryCodex(ctx context.Context, binary, home string, auth *codex.Auth, refresh bool) (codex.Result, error) {
	result, err := codex.Query(ctx, binary, auth)
	// The upstream's word on this exact access token (claude-fleet#1920):
	// a refusal before exp is what the clock in LoginHealth cannot see.
	_ = codex.RecordUpstream(home, auth, result, err)
	if refresh && codex.NeedsRefresh(result, err) {
		fresh, refreshErr := codex.Maintain(ctx, binary, home, true)
		if refreshErr == nil && fresh != nil && fresh.Identity.AccountUUID == auth.Identity.AccountUUID {
			result, err = codex.Query(ctx, binary, fresh)
			_ = codex.RecordUpstream(home, fresh, result, err)
		}
	}
	return result, err
}

// loginCodex is a machine tenant's: `ccquota codex machine-op` as the login.
type loginCodex struct{ ra *RunAs }

func (l loginCodex) maintain(ctx context.Context, binary, home string, force bool) (*codex.Auth, error) {
	ans, err := runCodexOp(ctx, l.ra, codexOpRequest{Op: "maintain", Home: home, Binary: binary, Force: force})
	if err != nil {
		return nil, err
	}
	return ans.Auth, ans.err()
}

func (l loginCodex) query(ctx context.Context, binary, home string, auth *codex.Auth, refresh bool) (codex.Result, error) {
	req := codexOpRequest{Op: "query", Home: home, Binary: binary, Refresh: refresh}
	if auth != nil {
		req.Account = auth.Identity.AccountUUID
	}
	ans, err := runCodexOp(ctx, l.ra, req)
	if err != nil {
		return codex.Result{}, err
	}
	var r codex.Result
	if ans.Result != nil {
		r = *ans.Result
	}
	return r, ans.err()
}

// CodexOpAction is `ccquota codex machine-op` (agent/cli/codex.go).
const CodexOpAction = "machine-op"

type codexOpRequest struct {
	Op      string `json:"op"` // maintain | query
	Home    string `json:"home"`
	Binary  string `json:"binary,omitempty"`
	Force   bool   `json:"force,omitempty"`
	Refresh bool   `json:"refresh,omitempty"`
	Account string `json:"account,omitempty"` // query: the account the caller read in Home
}

// codexOpAnswer carries what codex's own functions return. Their errors are
// already credential-free (shared/codex keeps no upstream message).
type codexOpAnswer struct {
	Auth   *codex.Auth   `json:"auth,omitempty"`
	Result *codex.Result `json:"result,omitempty"`
	Error  string        `json:"error,omitempty"`
}

func (a codexOpAnswer) err() error {
	if a.Error == "" {
		return nil
	}
	return errors.New(a.Error)
}

// codexOpTimeout bounds one machine-op: a renewal and two account reads, each
// bounded by codex's own 25 s.
const codexOpTimeout = 3 * time.Minute

// codexOpSelf is this program (a seam for the tests).
var codexOpSelf = os.Executable

// codexOpCmd is the command a machine tenant's Codex work runs in: this
// program, as ra (prepCmd: ra's uid/gid, HOME, USER, FLEET_CONF_DIR), on the
// environment codexOpEnv builds — nothing of root's PATH or HOME.
func codexOpCmd(ctx context.Context, ra *RunAs) (*exec.Cmd, error) {
	if ra == nil {
		return nil, errNoLogin
	}
	self, err := codexOpSelf()
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, self, "codex", CodexOpAction)
	cmd.Env = codexOpEnv(ra)
	cmd.WaitDelay = 2 * time.Second
	if err := prepCmd(withRunAs(ctx, ra), cmd); err != nil {
		return nil, err
	}
	return cmd, nil
}

// codexOpPassEnv are the variables of the agent's own that a login's Codex
// still needs to reach its upstream (a proxy, a CA bundle, the locale).
var codexOpPassEnv = []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy",
	"NO_PROXY", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "LANG", "LC_ALL"}

// codexOpEnv is a machine-op's environment before prepCmd adds the login's
// HOME/USER/LOGNAME: a PATH of the release's tools, the login's own
// ~/.local/bin and the system's.
func codexOpEnv(ra *RunAs) []string {
	var path []string
	if t := releaseTools(); t != "" {
		path = append(path, t)
	}
	if ra.Home != "" {
		path = append(path, filepath.Join(ra.Home, ".local", "bin"))
	}
	path = append(path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	env := []string{"PATH=" + strings.Join(path, string(os.PathListSeparator))}
	for _, k := range codexOpPassEnv {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	return env
}

// runCodexOp runs req as ra and reads its answer (a seam for the tests).
var runCodexOp = func(ctx context.Context, ra *RunAs, req codexOpRequest) (codexOpAnswer, error) {
	var ans codexOpAnswer
	ctx, cancel := context.WithTimeout(ctx, codexOpTimeout)
	defer cancel()
	cmd, err := codexOpCmd(ctx, ra)
	if err != nil {
		return ans, err
	}
	in, err := json.Marshal(req)
	if err != nil {
		return ans, err
	}
	cmd.Stdin = bytes.NewReader(in)
	var stdout bytes.Buffer
	var stderr strings.Builder
	cmd.Stdout = &limitedWriter{w: &stdout, n: 4 << 20}
	cmd.Stderr = &limitedWriter{w: &stderr, n: 512}
	runErr := startWhy(ctx, cmd, cmd.Run())
	if json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &ans) != nil {
		if runErr == nil {
			runErr = errors.New("no answer")
		}
		return codexOpAnswer{}, fmt.Errorf("Codex account work as %s: %v %s", ra.Login, runErr, oneLine(stderr.String()))
	}
	return ans, nil
}

// RunCodexOp is `ccquota codex machine-op`: one Codex profile's renewal or
// account read, as the login it was started as (a machine agent's tenant —
// never root), the request on in, the answer on out.
func RunCodexOp(in io.Reader, out io.Writer) error {
	if os.Geteuid() == 0 {
		return errors.New("machine-op runs as a login, never as root")
	}
	var req codexOpRequest
	if err := json.NewDecoder(io.LimitReader(in, 64<<10)).Decode(&req); err != nil {
		return fmt.Errorf("machine-op: request: %w", err)
	}
	if !filepath.IsAbs(req.Home) {
		return errors.New("machine-op: the profile home must be an absolute path")
	}
	binary := req.Binary
	if binary == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		binary = codex.Binary(home, "")
	}
	ctx, cancel := context.WithTimeout(context.Background(), codexOpTimeout)
	defer cancel()
	var ans codexOpAnswer
	var err error
	switch req.Op {
	case "maintain":
		ans.Auth, err = codex.Maintain(ctx, binary, req.Home, req.Force)
	case "query":
		var auth *codex.Auth
		auth, err = codex.ReadAuth(req.Home)
		switch {
		case err != nil:
		case auth.Identity.AccountUUID != req.Account:
			err = errors.New("Codex profile account changed; waiting for the next scan")
		default:
			var r codex.Result
			r, err = queryCodex(ctx, binary, req.Home, auth, req.Refresh)
			ans.Result = &r
		}
	default:
		return fmt.Errorf("machine-op: unknown op %q", req.Op)
	}
	if err != nil {
		ans.Error = err.Error()
	}
	return json.NewEncoder(out).Encode(ans)
}
