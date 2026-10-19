package api

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// GitHubApp is the hub's GitHub App, used for its GitHub reads — the legacy
// task settle's issue states and 我的用量's titles (claude-fleet#4881): the
// cluster's anonymous reads share one address and run out of GitHub's 60 an
// hour. Each mint signs a ten-minute JWT with the App's private key and trades
// it for a one-hour installation token, kept in memory only. The key is read
// once from the mounted Secret's files (CCQUOTA_FLEET_FEEDBACK_GH_DIR: app-id ·
// installation-id · private-key — the name the feedback desk gave it, removed
// with claude-fleet#4904); neither it nor a token is ever logged or stored.
type GitHubApp struct {
	AppID          string
	InstallationID string
	Key            *rsa.PrivateKey
	// API replaces https://api.github.com in tests.
	API string
	// Client replaces the default HTTP client in tests.
	Client *http.Client

	tokMu sync.Mutex
	tok   string
	tokAt time.Time
}

const (
	githubAppAPI     = "https://api.github.com"
	githubAppTimeout = 20 * time.Second
	// githubAppTokenKeep is how long Token reuses one installation token
	// (GitHub gives an hour).
	githubAppTokenKeep = 50 * time.Minute
)

// LoadGitHubApp reads the App's credentials from dir (the mounted Secret).
// Any of the three files missing or empty ⇒ nil, nil (off); a key that does
// not parse ⇒ an error (the caller logs it and stays off). The error never
// carries the key's bytes.
func LoadGitHubApp(dir string) (*GitHubApp, error) {
	if dir == "" {
		return nil, nil
	}
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
	app, inst, pemText := read("app-id"), read("installation-id"), read("private-key")
	if app == "" || inst == "" || pemText == "" {
		return nil, nil
	}
	key, err := parseRSAKey([]byte(pemText))
	if err != nil {
		return nil, fmt.Errorf("%s/private-key: %w", dir, err)
	}
	return &GitHubApp{AppID: app, InstallationID: inst, Key: key}, nil
}

// Token is an installation token, reused for githubAppTokenKeep.
func (g *GitHubApp) Token(ctx context.Context) (string, error) {
	g.tokMu.Lock()
	defer g.tokMu.Unlock()
	now := time.Now()
	if g.tok != "" && now.Sub(g.tokAt) < githubAppTokenKeep {
		return g.tok, nil
	}
	t, err := g.installationToken(ctx, now)
	if err != nil {
		return "", err
	}
	g.tok, g.tokAt = t, now
	return t, nil
}

func parseRSAKey(b []byte) (*rsa.PrivateKey, error) {
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, errors.New("not a PEM private key")
	}
	if k, err := x509.ParsePKCS1PrivateKey(blk.Bytes); err == nil {
		return k, nil
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, errors.New("not an RSA private key (PKCS#1 or PKCS#8)")
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("not an RSA private key")
	}
	return rk, nil
}

// appJWT is the App's RS256 assertion: issued a minute back (clock skew),
// good for nine minutes (GitHub's cap is ten).
func (g *GitHubApp) appJWT(now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	head := enc.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{"iat": now.Add(-time.Minute).Unix(), "exp": now.Add(9 * time.Minute).Unix(), "iss": g.AppID})
	signing := head + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, g.Key, crypto.SHA256, sum[:])
	if err != nil {
		return "", fmt.Errorf("sign the App JWT: %w", err)
	}
	return signing + "." + enc.EncodeToString(sig), nil
}

// installationToken trades the App JWT for a short installation token. A
// non-2xx is an error naming the status and the start of GitHub's own message
// (never a header, never the token).
func (g *GitHubApp) installationToken(ctx context.Context, now time.Time) (string, error) {
	jwt, err := g.appJWT(now)
	if err != nil {
		return "", err
	}
	base := githubAppAPI
	if g.API != "" {
		base = strings.TrimRight(g.API, "/")
	}
	path := "/app/installations/" + g.InstallationID + "/access_tokens"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+path, bytes.NewReader([]byte("{}")))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Content-Type", "application/json")
	c := g.Client
	if c == nil {
		c = &http.Client{Timeout: githubAppTimeout}
	}
	res, err := c.Do(req)
	if err != nil {
		var ue interface{ Timeout() bool }
		if errors.As(err, &ue) && ue.Timeout() {
			return "", fmt.Errorf("POST %s: timed out", path)
		}
		return "", fmt.Errorf("POST %s: unreachable", path)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode/100 != 2 {
		var m struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(b, &m)
		return "", fmt.Errorf("POST %s: %d %s", path, res.StatusCode, clipRunes(m.Message, 200))
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return "", fmt.Errorf("POST %s: answer not JSON", path)
	}
	if out.Token == "" {
		return "", errors.New("installation token: GitHub answered none")
	}
	return out.Token, nil
}
