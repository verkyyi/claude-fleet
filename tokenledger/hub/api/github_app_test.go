package api

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const fakeAppTok = "ghs_fakeinstallationtoken"

// TestIssueStateViaAppToken: the settle's issue reads carry ONE installation
// token minted from the App's Secret files (claude-fleet#4881), anonymous
// reads are refused, and a failing token source falls back to Token.
func TestIssueStateViaAppToken(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	for name, v := range map[string]string{"app-id": "123", "installation-id": "456", "private-key": string(keyPEM)} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var mints atomic.Int32
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/app/installations/456/access_tokens":
			if !strings.HasPrefix(auth, "Bearer ey") {
				http.Error(w, `{"message":"bad jwt"}`, http.StatusUnauthorized)
				return
			}
			mints.Add(1)
			_, _ = w.Write([]byte(`{"token":"` + fakeAppTok + `"}`))
		case strings.HasPrefix(r.URL.Path, "/repos/o/r/issues/"):
			if auth != "Bearer "+fakeAppTok {
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = w.Write([]byte(`{"message":"Bad credentials"}`))
				return
			}
			_, _ = w.Write([]byte(`{"state":"closed"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer gh.Close()

	app, err := LoadGitHubApp(dir)
	if err != nil || app == nil {
		t.Fatalf("LoadGitHubApp = %v, %v", app, err)
	}
	app.API = gh.URL
	im := &GitHubIssueMeta{APIBase: gh.URL, TokenSource: app.Token}
	ctx := context.Background()
	for n := 1; n <= 3; n++ {
		if st, err := im.IssueState(ctx, "o/r", n); err != nil || st != "closed" {
			t.Fatalf("o/r#%d = %q, %v", n, st, err)
		}
	}
	if got := mints.Load(); got != 1 {
		t.Errorf("%d installation tokens minted for 3 reads; want 1", got)
	}
	anon := &GitHubIssueMeta{APIBase: gh.URL}
	if _, err := anon.IssueState(ctx, "o/r", 1); err == nil || err.Error() != "HTTP 401 Bad credentials" {
		t.Errorf("anonymous = %v; want HTTP 401 Bad credentials", err)
	}
	fb := &GitHubIssueMeta{APIBase: gh.URL, Token: fakeAppTok, TokenSource: func(context.Context) (string, error) { return "", errors.New("down") }}
	if st, err := fb.IssueState(ctx, "o/r", 1); err != nil || st != "closed" {
		t.Errorf("fallback = %q, %v", st, err)
	}
	if a, err := LoadGitHubApp(t.TempDir()); a != nil || err != nil {
		t.Errorf("empty dir = %v, %v; want nil, nil", a, err)
	}
}
