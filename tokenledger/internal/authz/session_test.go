package authz

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

const sessSecret = "dev-only-set-ccquota-session-golden"

var t0 = time.Unix(1_800_000_000, 0)

func TestSession_RoundTrip(t *testing.T) {
	s, err := VerifySession(SignRole("github", "gh:7", "lee", "admin", sessSecret, t0, time.Hour), sessSecret, t0)
	if err != nil {
		t.Fatalf("our own signature does not verify: %v", err)
	}
	if s.Sub != "github" || s.UID != "gh:7" || s.Name != "lee" || s.Role != "admin" || s.Principal() != "gh:7" {
		t.Fatalf("session = %+v", s)
	}
}

// A session has its own lifetime, to the second.
func TestSession_ExpiresExactly(t *testing.T) {
	c := SignRole("github", "gh:7", "lee", "user", sessSecret, t0, time.Hour)
	if _, err := VerifySession(c, sessSecret, t0.Add(3599*time.Second)); err != nil {
		t.Errorf("refused before expiry: %v", err)
	}
	if _, err := VerifySession(c, sessSecret, t0.Add(3601*time.Second)); err == nil {
		t.Error("an expired cookie was admitted")
	}
}

func TestSession_RejectsTamperedOrForeignKey(t *testing.T) {
	c := SignRole("github", "gh:7", "lee", "user", sessSecret, t0, time.Hour)
	body, _, _ := strings.Cut(c, ".")
	for name, bad := range map[string]string{
		"other signature": body + ".ZmFrZQ",
		"no dot":          body,
		"empty":           "",
		"only a dot":      ".",
	} {
		if _, err := VerifySession(bad, sessSecret, t0); err != ErrSession {
			t.Errorf("%s: got %v, want ErrSession", name, err)
		}
	}
	if _, err := VerifySession(c, "dev-only-set-some-other-key", t0); err != ErrSession {
		t.Error("verified under another key")
	}
	if _, err := VerifySession(c, "", t0); err != ErrSession {
		t.Error("admitted with no key configured")
	}
}

// A value signed with the right key but for another audience is not a session.
func TestSession_RefusesAnotherAudience(t *testing.T) {
	c := SignRole("github", "gh:7", "lee", "user", sessSecret, t0, time.Hour)
	body, _, _ := strings.Cut(c, ".")
	raw, _ := base64.RawURLEncoding.DecodeString(body)
	foreign := strings.Replace(string(raw), sessionAud, "ccquota", 1)
	enc := base64.RawURLEncoding.EncodeToString([]byte(foreign))
	if _, err := VerifySession(enc+"."+macFor(enc), sessSecret, t0); err != ErrSession {
		t.Errorf("a foreign-audience token verified as a session: %v", err)
	}
}

func macFor(enc string) string {
	m := hmac.New(sha256.New, []byte(sessSecret))
	m.Write([]byte(enc))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
