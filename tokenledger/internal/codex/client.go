// Package codex manages isolated Codex profiles and reads official account APIs.
// Usage queries use disposable access-only snapshots; credential maintenance
// delegates refresh and persistence to the official CLI. Neither starts a turn.
package codex

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

type Auth struct {
	Identity        model.Identity
	Mode            string
	AccountID       string
	ExpiresAt       time.Time
	LastRefresh     *time.Time
	HasRefreshToken bool
	fingerprint     string
	snapshot        []byte
}

// ProfileID is local-directory identity, not a claim about a subscription.
func ProfileID(home string) string {
	p, err := filepath.Abs(home)
	if err != nil {
		p = home
	}
	if resolved, err := filepath.EvalSymlinks(p); err == nil {
		p = resolved
	}
	return fmt.Sprintf("%x", sha256.Sum256([]byte(p)))[:20]
}

func ReadAuth(home string) (*Auth, error) {
	f, err := os.Open(filepath.Join(home, "auth.json"))
	if err != nil {
		return nil, errors.New("no readable Codex file credentials (log collection remains available)")
	}
	defer f.Close()
	var doc struct {
		Mode        string     `json:"auth_mode"`
		APIKey      *string    `json:"OPENAI_API_KEY"`
		LastRefresh *time.Time `json:"last_refresh"`
		Tokens      struct {
			ID      string `json:"id_token"`
			Access  string `json:"access_token"`
			Account string `json:"account_id"`
			Refresh string `json:"refresh_token"`
		} `json:"tokens"`
	}
	if err := json.NewDecoder(io.LimitReader(f, 2<<20)).Decode(&doc); err != nil {
		return nil, errors.New("invalid Codex credential file")
	}
	a := &Auth{Mode: "unknown", LastRefresh: doc.LastRefresh, HasRefreshToken: doc.Tokens.Refresh != ""}
	a.fingerprint = fmt.Sprintf("%x", sha256.Sum256([]byte(doc.Tokens.Access+"\x00"+doc.Tokens.Refresh)))
	if doc.Mode == "apikey" || (doc.APIKey != nil && *doc.APIKey != "") {
		a.Mode = "api"
		return a, nil
	}
	if doc.Tokens.Access == "" {
		return a, errors.New("Codex account access token unavailable")
	}
	claims := decodeClaims(doc.Tokens.Access)
	idClaims := decodeClaims(doc.Tokens.ID)
	meta, _ := claims["https://api.openai.com/auth"].(map[string]any)
	account, user := str(meta["chatgpt_account_id"]), str(meta["chatgpt_user_id"])
	if user == "" {
		user = str(meta["user_id"])
	}
	if account == "" || user == "" {
		return a, errors.New("Codex credentials lack a stable account/member identity")
	}
	if doc.Tokens.Account != "" && doc.Tokens.Account != account {
		return a, errors.New("Codex credential account identifiers disagree")
	}
	a.Mode, a.AccountID = "subscription", account
	if exp, ok := claims["exp"].(float64); ok {
		a.ExpiresAt = time.Unix(int64(exp), 0).UTC()
	}
	// A workspace ID alone is not a seat's quota. Keep the member in the key.
	key := fmt.Sprintf("%x", sha256.Sum256([]byte(account+"\x00"+user)))
	email := str(idClaims["email"])
	if profile, ok := claims["https://api.openai.com/profile"].(map[string]any); ok && email == "" {
		email = str(profile["email"])
	}
	a.Identity = model.Identity{Source: model.SourceCodex, AccountUUID: "codex:account:" + key[:32], Email: email,
		OrgUUID: account, SubscriptionType: str(meta["chatgpt_plan_type"]), DisplayName: "Codex account"}
	// refresh_token is a required string in some CLI versions. Empty disables
	// refresh without making the entire credential file fail deserialization.
	a.snapshot, _ = json.Marshal(map[string]any{"auth_mode": "chatgpt", "OPENAI_API_KEY": nil, "last_refresh": doc.LastRefresh,
		"tokens": map[string]string{"id_token": doc.Tokens.ID, "access_token": doc.Tokens.Access, "refresh_token": "", "account_id": account}})
	return a, nil
}

func decodeClaims(token string) map[string]any {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil
	}
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return out
}

func Binary(home, configured string) string {
	if configured != "" {
		return configured
	}
	for _, p := range []string{filepath.Join(home, ".local", "bin", "codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex"} {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0111 != 0 {
			return p
		}
	}
	p, _ := lookPath("codex")
	return p
}

type Result struct {
	Quota           *model.QuotaSnapshot
	Usage           *model.AccountUsage
	Version         string
	LimitsError     string
	UsageError      string
	refreshRequired bool
}

func Query(ctx context.Context, binary string, auth *Auth) (Result, error) {
	var out Result
	if auth == nil || auth.Mode != "subscription" {
		return out, errors.New("subscription login required for Codex account queries")
	}
	if !auth.ExpiresAt.IsZero() && time.Now().After(auth.ExpiresAt) {
		return out, errors.New("Codex access token expired; refresh it through Codex")
	}
	if binary == "" {
		return out, errors.New("Codex CLI not found; passive log collection remains available")
	}
	home, err := os.MkdirTemp("", "ccquota-codex-")
	if err != nil {
		return out, err
	}
	defer os.RemoveAll(home)
	if err := os.WriteFile(filepath.Join(home, "auth.json"), auth.snapshot, 0600); err != nil {
		return out, err
	}
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte("cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n"), 0600); err != nil {
		return out, err
	}
	c, err := openRPC(ctx, binary, home)
	if err != nil {
		return out, err
	}
	defer c.Close()
	out.Version = c.Version
	rpc := c.Call
	var acct struct {
		Account *struct {
			Type string `json:"type"`
		} `json:"account"`
	}
	if err := rpc(2, "account/read", map[string]bool{"refreshToken": false}, &acct); err != nil {
		return out, err
	}
	if acct.Account == nil || acct.Account.Type != "chatgpt" {
		out.refreshRequired = true
		return out, errors.New("Codex account reader could not use the credential snapshot")
	}
	var raw json.RawMessage
	if err := rpc(3, "account/rateLimits/read", nil, &raw); err != nil {
		out.LimitsError = err.Error()
		out.refreshRequired = unauthorized(err)
	} else {
		var response map[string]json.RawMessage
		if err := json.Unmarshal(raw, &response); err != nil {
			return out, err
		}
		var accountID string
		_ = json.Unmarshal(response["accountId"], &accountID)
		if accountID != "" && accountID != auth.AccountID {
			return out, errors.New("Codex usage response belongs to a different account")
		}
		q, err := ParseLimits(raw, time.Now().UTC())
		if err != nil {
			out.LimitsError = err.Error()
			out.refreshRequired = unauthorized(err)
		} else {
			q.Observation = "app_server"
			out.Quota = q
		}
	}
	var usage struct {
		Summary struct {
			Lifetime *int64 `json:"lifetimeTokens"`
			Peak     *int64 `json:"peakDailyTokens"`
		} `json:"summary"`
		Daily []struct {
			Date   string `json:"startDate"`
			Tokens int64  `json:"tokens"`
		} `json:"dailyUsageBuckets"`
	}
	if err := rpc(4, "account/usage/read", nil, &usage); err != nil {
		out.UsageError = err.Error()
		out.refreshRequired = out.refreshRequired || unauthorized(err)
	} else {
		u := &model.AccountUsage{Source: model.SourceCodex, ObservedAt: time.Now().UTC(), LifetimeTokens: usage.Summary.Lifetime, PeakDailyTokens: usage.Summary.Peak}
		for _, d := range usage.Daily {
			if _, err := time.Parse("2006-01-02", d.Date); err == nil && d.Tokens >= 0 {
				u.Daily = append(u.Daily, model.DailyUsage{Date: d.Date, Tokens: d.Tokens})
			}
		}
		out.Usage = u
	}
	return out, nil
}

func str(v any) string { s, _ := v.(string); return s }

func unauthorized(err error) bool {
	var re *rpcError
	return errors.As(err, &re) && (re.unauthorized || re.reauth)
}

func NeedsRefresh(result Result, err error) bool { return result.refreshRequired || unauthorized(err) }
