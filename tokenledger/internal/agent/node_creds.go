package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/codex"
)

// The node half of "credentials live at the entrance; machines lease the
// short-lived half" (claude-fleet#1415).
//
// The agent leases this login's credentials from the hub ahead of their
// expiry and writes each where its CLI re-reads it — the layout and the
// reasons were measured first (issue #1415, first comment):
//
//   - Claude: <accounts>/<label>.hub/.credentials.json, which a session reads
//     through CLAUDE_SECURESTORAGE_CONFIG_DIR. A running session picks a
//     replaced file up on its very next request; the env var the fleet used to
//     pass tokens in is read once and never again. <accounts>/<label> holds the
//     marker "hub:<label>", so bin/fleet-account.sh keeps one file per label and
//     knows to point the session at the directory instead of exporting a token.
//   - Codex: <codex-homes>/<label>/auth.json. A running Codex re-reads it on
//     its first 401. Its refresh_token is the fixed placeholder below — Codex
//     drops ChatGPT auth entirely when the field is missing — and a refresh
//     attempted with it simply fails at the provider.
//   - GitHub (phase one): the person's existing token, written to gh's
//     hosts.yml. It has no expiry; R1 replaces it with a short-lived one.
//
// The node never receives a refresh token, so nothing it writes can mint
// more: revoke the machine at the hub and what it holds runs out.

// CodexRefreshPlaceholder fills auth.json's refresh_token on a hub-managed
// home. It is not a credential.
const CodexRefreshPlaceholder = codex.HubManagedRefreshToken

// HubMarkerPrefix starts the contents of a hub-managed label file.
const HubMarkerPrefix = "hub:"

const (
	// credRenewLead is how long before expiry a lease is renewed. The hub
	// refreshes anything with less than its MinTTL (3h) left, so a renewal
	// at 2h before expiry always comes back with a fresh token.
	credRenewLead = 2 * time.Hour
	// credMinWait / credMaxWait bound the gap between leases: never a tight
	// loop, never so long a revocation or a newly stored credential goes
	// unnoticed for a day.
	credMinWait = 5 * time.Minute
	credMaxWait = 6 * time.Hour
	// credRefusedWait is the retry after the hub refused this login (revoked,
	// or no account yet): it may be lifted, or the account may land.
	credRefusedWait = 15 * time.Minute
)

// credLease mirrors the hub's NodeCredentialsResponse.
type credLease struct {
	PrincipalID string `json:"principal_id"`
	Credentials []struct {
		Provider  string     `json:"provider"`
		Account   string     `json:"account"`
		ExpiresAt *time.Time `json:"expires_at"`
		Error     string     `json:"error"`
		Access    *struct {
			AccessToken      string   `json:"access_token"`
			IDToken          string   `json:"id_token"`
			AccountID        string   `json:"account_id"`
			Scopes           []string `json:"scopes"`
			SubscriptionType string   `json:"subscription_type"`
			Token            string   `json:"token"`
			User             string   `json:"user"`
		} `json:"access"`
	} `json:"credentials"`
}

// errLeaseRefused is a 403 from the hub: revoked, or no fleet account.
type errLeaseRefused struct{ reason, message string }

func (e errLeaseRefused) Error() string {
	return "hub refused the lease: " + e.reason + ": " + e.message
}

func (a *Agent) nodeReadyCh() chan struct{} {
	a.nodeReadyInit.Do(func() { a.nodeReady = make(chan struct{}) })
	return a.nodeReady
}

// markNodeReady records that a heartbeat has reached the hub.
func (a *Agent) markNodeReady() {
	ch := a.nodeReadyCh()
	a.nodeReadyDone.Do(func() { close(ch) })
}

// runCredLeases keeps this login's leases current until ctx ends. The first
// lease waits for the first heartbeat: the hub answers a lease for the person
// whose account this (machine, login) is, and learns the pair from the beat.
func (a *Agent) runCredLeases(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-a.nodeReadyCh():
	}
	var bo nodeBackoff
	var lastErr string
	for {
		wait, err := a.credCycle(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			var refused errLeaseRefused
			if errors.As(err, &refused) {
				wait = credRefusedWait
			} else {
				wait = bo.next()
			}
			if err.Error() != lastErr {
				log.Printf("credentials: %v", err)
				lastErr = err.Error()
			}
		} else {
			bo.reset()
			lastErr = ""
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

// credCycle leases once, writes what came back, and returns how long to wait
// before the next lease.
func (a *Agent) credCycle(ctx context.Context) (time.Duration, error) {
	lease, err := a.fetchCredLease(ctx)
	if err != nil {
		return 0, err
	}
	now := time.Now()
	wait := credMaxWait
	for _, c := range lease.Credentials {
		if c.Error != "" || c.Access == nil {
			log.Printf("credentials: hub could not lease %s/%s: %s", c.Provider, c.Account, c.Error)
			if credMinWait < wait {
				wait = credMinWait
			}
			continue
		}
		var werr error
		switch c.Provider {
		case "claude":
			werr = writeClaudeCred(a.credAccountsDir(), c.Account, c.Access.AccessToken, c.ExpiresAt, c.Access.Scopes, c.Access.SubscriptionType)
		case "codex":
			werr = writeCodexAuth(a.codexHomeFor(c.Account), c.Access.AccessToken, c.Access.IDToken, c.Access.AccountID, now)
		case "github":
			werr = writeGHHosts(a.ghConfigDir(), c.Access.User, c.Access.Token)
		default:
			continue
		}
		if werr != nil {
			log.Printf("credentials: write %s/%s: %v", c.Provider, c.Account, werr)
			continue
		}
		if c.ExpiresAt != nil {
			if d := c.ExpiresAt.Add(-credRenewLead).Sub(now); d < wait {
				wait = d
			}
		}
	}
	if wait < credMinWait {
		wait = credMinWait
	}
	return wait, nil
}

func (a *Agent) fetchCredLease(ctx context.Context) (*credLease, error) {
	rctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(rctx, http.MethodPost, a.cfg.HubURL+"/v1/node/credentials", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	resp, err := a.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == http.StatusForbidden {
		var r struct{ Error, Message string }
		_ = json.Unmarshal(body, &r)
		return nil, errLeaseRefused{reason: r.Error, message: r.Message}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("lease: HTTP %d: %s", resp.StatusCode, bytes.TrimSpace(body))
	}
	var l credLease
	if err := json.Unmarshal(body, &l); err != nil {
		return nil, fmt.Errorf("lease: %w", err)
	}
	return &l, nil
}

func (a *Agent) credAccountsDir() string {
	if a.cfg.AccountsDir != "" {
		return a.cfg.AccountsDir
	}
	return filepath.Join(a.cfg.Home, ".config", "claude-fleet", "accounts")
}

func (a *Agent) codexHomeFor(account string) string {
	if account == "default" {
		return filepath.Join(a.cfg.Home, ".codex")
	}
	dir := a.cfg.FleetCodexHomesDir
	if dir == "" {
		dir = filepath.Join(a.cfg.Home, ".codex-accounts")
	}
	return filepath.Join(dir, account)
}

func (a *Agent) ghConfigDir() string {
	if d := os.Getenv("GH_CONFIG_DIR"); d != "" {
		return d
	}
	return filepath.Join(a.cfg.Home, ".config", "gh")
}

// safeLabel is the shape the hub enforces on account names; checked again
// here because it becomes a path.
var safeLabel = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$`)

// writeAtomic writes data to path with mode via a same-directory rename, so a
// CLI reading mid-write sees the old file or the new one, never half of one.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// writeClaudeCred writes one Claude account's short-lived token and its label
// marker. The JSON is the shape Claude Code itself stores (claudeAiOauth),
// with no refresh token.
func writeClaudeCred(dir, label, accessToken string, expires *time.Time, scopes []string, subType string) error {
	if !safeLabel.MatchString(label) {
		return fmt.Errorf("unsafe account label %q", label)
	}
	if accessToken == "" || expires == nil {
		return errors.New("lease carried no access token or expiry")
	}
	if len(scopes) == 0 {
		scopes = []string{"user:inference"}
	}
	oauth := map[string]any{
		"accessToken":  accessToken,
		"refreshToken": nil,
		"expiresAt":    expires.UnixMilli(),
		"scopes":       scopes,
	}
	if subType != "" {
		oauth["subscriptionType"] = subType
	}
	b, _ := json.Marshal(map[string]any{"claudeAiOauth": oauth})
	credDir := filepath.Join(dir, label+".hub")
	if err := os.MkdirAll(credDir, 0o700); err != nil {
		return err
	}
	if err := writeAtomic(filepath.Join(credDir, ".credentials.json"), b, 0o600); err != nil {
		return err
	}
	marker := []byte(HubMarkerPrefix + label + "\n")
	markerPath := filepath.Join(dir, label)
	if cur, err := os.ReadFile(markerPath); err == nil && bytes.Equal(cur, marker) {
		return nil
	} else if err == nil && !bytes.HasPrefix(cur, []byte(HubMarkerPrefix)) {
		// A long-lived token the operator stored here by hand: the hub
		// now owns this account, and the point is that no long-lived
		// token stays on the machine.
		log.Printf("credentials: %s now comes from the hub; replacing the local token file", label)
	}
	return writeAtomic(markerPath, marker, 0o600)
}

// writeCodexAuth writes one Codex home's auth.json, and makes sure that home
// stores credentials in the file (not a keyring the hub cannot write).
func writeCodexAuth(home, accessToken, idToken, accountID string, now time.Time) error {
	if !safeLabel.MatchString(filepath.Base(home)) && filepath.Base(home) != ".codex" {
		return fmt.Errorf("unsafe codex home %q", home)
	}
	if accessToken == "" || accountID == "" {
		return errors.New("lease carried no access token or account id")
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		return err
	}
	auth := map[string]any{
		"auth_mode":      "chatgpt",
		"OPENAI_API_KEY": nil,
		"tokens": map[string]any{
			"id_token":      idToken,
			"access_token":  accessToken,
			"refresh_token": CodexRefreshPlaceholder,
			"account_id":    accountID,
		},
		"last_refresh": now.UTC().Format(time.RFC3339),
	}
	b, _ := json.MarshalIndent(auth, "", "  ")
	if err := writeAtomic(filepath.Join(home, "auth.json"), b, 0o600); err != nil {
		return err
	}
	return ensureCodexFileStore(filepath.Join(home, "config.toml"))
}

var codexStoreKey = regexp.MustCompile(`(?m)^\s*cli_auth_credentials_store\s*=`)

// ensureCodexFileStore makes config.toml say cli_auth_credentials_store =
// "file". The line is PREPENDED when missing: a top-level TOML key must come
// before the first [table], so appending could land it inside one.
func ensureCodexFileStore(path string) error {
	cur, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if codexStoreKey.Match(cur) {
		return nil
	}
	return writeAtomic(path, append([]byte("cli_auth_credentials_store = \"file\"\n"), cur...), 0o600)
}

// writeGHHosts writes gh's hosts.yml for github.com with the person's token.
func writeGHHosts(dir, user, token string) error {
	if token == "" {
		return errors.New("lease carried no token")
	}
	if strings.ContainsAny(user+token, "\n\r:\"'") {
		return errors.New("refusing a user or token that would break hosts.yml")
	}
	var b strings.Builder
	b.WriteString("github.com:\n")
	if user != "" {
		fmt.Fprintf(&b, "    users:\n        %s:\n            oauth_token: %s\n", user, token)
	}
	fmt.Fprintf(&b, "    git_protocol: https\n    oauth_token: %s\n", token)
	if user != "" {
		fmt.Fprintf(&b, "    user: %s\n", user)
	}
	return writeAtomic(filepath.Join(dir, "hosts.yml"), []byte(b.String()), 0o600)
}

// hubAccountToken resolves an accounts-dir label file that holds the hub
// marker to the short-lived token the agent last wrote for it — so the
// account probe reads the same meter it always did.
func hubAccountToken(dir, label, contents string) string {
	if !strings.HasPrefix(contents, HubMarkerPrefix) {
		return contents
	}
	raw, err := os.ReadFile(filepath.Join(dir, label+".hub", ".credentials.json"))
	if err != nil {
		return ""
	}
	var f struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &f) != nil {
		return ""
	}
	return f.ClaudeAiOauth.AccessToken
}
