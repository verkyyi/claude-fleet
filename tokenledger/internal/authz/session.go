// Package authz is this hub's own session: the cookie a GitHub sign-in
// (internal/api/github_auth.go) mints and every later request presents.
package authz

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// ErrSession is the only error VerifySession returns.
//
// Deliberately one kind: the caller answers "sign in again" either way, and a
// caller that can tell "bad key" from "expired" hands that distinction to
// whoever is probing it.
var ErrSession = errors.New("session rejected")

// CookieName is this hub's session cookie.
//
// Set host-only — never with a Domain attribute: a cookie scoped to the parent
// domain is a cookie handed to every other app on it.
const CookieName = "ccq_sess"

// sessionAud marks a value as this hub's session, so a token signed for
// anything else under the same key never verifies as one.
const sessionAud = "ccquota-session"

// Session is a signed-in human on this hub.
type Session struct {
	// Sub is the issuer of the sign-in ("github").
	Sub string `json:"sub"`
	Aud string `json:"aud"`
	Exp int64  `json:"exp"`
	// UID is the person (gh:<GitHub ID>) and Name their username, carried so
	// every later request knows who it is without asking GitHub again.
	UID  string `json:"uid,omitempty"`
	Name string `json:"nam,omitempty"`
	// Role is the hub role the sign-in was admitted as (claude-fleet#1984):
	// admin or user. A record of the sign-in, never the authority: the gate
	// re-reads the list on every request, so a person taken off it or demoted
	// is refused on their next one whatever the cookie says.
	Role string `json:"role,omitempty"`
}

// Principal is the person this session is for: UID, else the subject.
func (s *Session) Principal() string {
	if s.UID != "" {
		return s.UID
	}
	return s.Sub
}

// SignRole mints the cookie value for a person signed in by sub, admitted as
// role, for ttl.
func SignRole(sub, uid, name, role, secret string, now time.Time, ttl time.Duration) string {
	body, _ := json.Marshal(Session{Sub: sub, Aud: sessionAud, Exp: now.Add(ttl).Unix(), UID: uid, Name: name, Role: role})
	enc := base64.RawURLEncoding.EncodeToString(body)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(enc))
	return enc + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// VerifySession checks a cookie value. Every failure is ErrSession.
func VerifySession(cookie, secret string, now time.Time) (*Session, error) {
	if secret == "" || cookie == "" {
		return nil, ErrSession
	}
	i := strings.LastIndex(cookie, ".")
	if i <= 0 || i == len(cookie)-1 {
		return nil, ErrSession
	}
	body, sig64 := cookie[:i], cookie[i+1:]
	sig, err := base64.RawURLEncoding.DecodeString(sig64)
	if err != nil {
		return nil, ErrSession
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(body))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return nil, ErrSession
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return nil, ErrSession
	}
	var s Session
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, ErrSession
	}
	if !hmac.Equal([]byte(s.Aud), []byte(sessionAud)) || s.Sub == "" {
		return nil, ErrSession
	}
	if s.Exp < now.Unix() {
		return nil, ErrSession
	}
	return &s, nil
}
