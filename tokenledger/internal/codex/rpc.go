package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

var lookPath = exec.LookPath
var codexCommand = exec.CommandContext

// ProfileEnv removes ambient authentication overrides so a named profile is
// always the credential source. No credential is placed in argv or diagnostics.
func ProfileEnv(home string) []string {
	var env []string
	for _, e := range os.Environ() {
		k, _, _ := strings.Cut(e, "=")
		switch k {
		case "CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT":
			continue
		}
		if strings.HasPrefix(k, "CODEX_INTERNAL_") {
			continue
		}
		if k == "PATH" {
			e += string(os.PathListSeparator) + "/opt/homebrew/bin" + string(os.PathListSeparator) + "/usr/local/bin"
		}
		env = append(env, e)
	}
	return append(env, "CODEX_HOME="+home)
}

type rpcError struct {
	code         int
	reauth       bool
	unauthorized bool
}

func (e *rpcError) Error() string {
	if e.reauth {
		return "Codex refresh credential rejected; sign in again for this profile"
	}
	return fmt.Sprintf("Codex account API unavailable (protocol error %d)", e.code)
}

// Only classify recognized authentication errors. Never retain or propagate
// the server's arbitrary error message, which can contain secrets or URLs.
func classifyRPC(code int, message string) *rpcError {
	m := strings.ToLower(message)
	e := &rpcError{code: code, unauthorized: code == 401 || strings.Contains(m, "401 unauthorized")}
	for _, marker := range []string{"401 (unauthorized)", "status: 401", "status code: 401", "status code 401", "http 401"} {
		if strings.Contains(m, marker) {
			e.unauthorized = true
		}
	}
	for _, marker := range []string{"refresh_token_reused", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_revoked", "invalid_grant", "refresh token has expired", "refresh token has already been used", "refresh token has been revoked"} {
		if strings.Contains(m, marker) {
			e.reauth = true
		}
	}
	if strings.Contains(m, "refresh token") && (strings.Contains(m, "already used") || strings.Contains(m, "invalidated") || strings.Contains(m, "revoked")) {
		e.reauth = true
	}
	return e
}

type rpcClient struct {
	diagnostics *authDiagnostics
	cmd         *exec.Cmd
	in          io.WriteCloser
	enc         *json.Encoder
	dec         *json.Decoder
	cancel      context.CancelFunc
	Version     string
}

func openRPC(ctx context.Context, binary, home string) (*rpcClient, error) {
	if binary == "" {
		return nil, errors.New("Codex CLI not found; passive log collection remains available")
	}
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	cmd := codexCommand(ctx, binary, "-c", `cli_auth_credentials_store="file"`, "app-server", "--listen", "stdio://")
	for _, e := range ProfileEnv(home) {
		if !strings.HasPrefix(e, "RUST_LOG=") {
			cmd.Env = append(cmd.Env, e)
		}
	}
	cmd.Env = append(cmd.Env, "RUST_LOG=warn")
	diagnostics := &authDiagnostics{}
	cmd.Dir, cmd.WaitDelay, cmd.Stderr = os.TempDir(), 2*time.Second, diagnostics
	in, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, errors.New("could not open Codex account reader")
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		in.Close()
		cancel()
		return nil, errors.New("could not open Codex account reader")
	}
	if err := cmd.Start(); err != nil {
		in.Close()
		cancel()
		return nil, errors.New("could not start Codex account reader")
	}
	c := &rpcClient{cmd: cmd, in: in, enc: json.NewEncoder(in), dec: json.NewDecoder(io.LimitReader(out, 8<<20)), cancel: cancel, diagnostics: diagnostics}
	var init struct {
		UserAgent string `json:"userAgent"`
	}
	if err := c.Call(1, "initialize", map[string]any{"clientInfo": map[string]string{"name": "ccquota", "version": "1"}}, &init); err != nil {
		c.Close()
		return nil, err
	}
	if fields := strings.Fields(init.UserAgent); len(fields) > 0 {
		_, c.Version, _ = strings.Cut(fields[0], "/")
	}
	if err := c.enc.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		c.Close()
		return nil, errors.New("Codex account reader disconnected")
	}
	return c, nil
}

func (c *rpcClient) Close() { _ = c.in.Close(); c.cancel(); _ = c.cmd.Wait() }

func (c *rpcClient) Call(id int, method string, params, target any) error {
	if err := c.enc.Encode(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		return errors.New("Codex account reader disconnected")
	}
	for {
		var msg struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Code    int    `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := c.dec.Decode(&msg); err != nil {
			return errors.New("Codex account reader timed out or disconnected")
		}
		if msg.ID != id {
			continue
		}
		if msg.Error != nil {
			return classifyRPC(msg.Error.Code, msg.Error.Message)
		}
		if err := json.Unmarshal(msg.Result, target); err != nil {
			return errors.New("invalid Codex account response")
		}
		return nil
	}
}

// Bounded streaming classification handles markers split across writes.
// Raw diagnostics never reach callers, health JSON, or a ccquota log file.
type authDiagnostics struct {
	mu     sync.Mutex
	tail   string
	reauth bool
}

func (d *authDiagnostics) Write(p []byte) (int, error) {
	count := len(p)
	d.mu.Lock()
	defer d.mu.Unlock()
	for len(p) > 0 {
		n := min(len(p), 4096)
		s := d.tail + strings.ToLower(string(p[:n]))
		// Generic invalid_grant can belong to an unrelated MCP login in
		// startup diagnostics. Only OpenAI refresh codes identify this login.
		for _, marker := range []string{"refresh_token_reused", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_revoked"} {
			if strings.Contains(s, marker) {
				d.reauth = true
			}
		}
		d.tail = s[max(0, len(s)-128):]
		p = p[n:]
	}
	return count, nil
}
func (d *authDiagnostics) reauthenticationRequired() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.reauth
}
