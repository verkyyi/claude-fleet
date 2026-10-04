package authz

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"
)

// CookieName is this hub's session cookie.
//
// Set host-only — never with a Domain attribute. Every other 24haowan site that
// takes a ticket does the same, and for the same reason: a cookie scoped to the
// parent domain is a cookie handed to every preview environment and every other
// app on *.24haowan.com.
const CookieName = "ccq_sess"

// sessionAud separates a session cookie from an 入场票.
//
// The two use the same encoding and, on a bad day, the same leaked key. What
// keeps one from being replayed as the other is this field and the fact that
// both verifiers check it — in BOTH directions. kf-context's
// verifySession/verifyScoped pair is where this pattern comes from: its
// verifySession refuses any token that carries an `aud` at all.
const sessionAud = "ccquota-session"

// Session is a signed-in human on this hub.
type Session struct {
	// Sub is the ticket's subject, carried through unchanged so an audit line
	// can name the same person the issuer named.
	Sub string `json:"sub"`
	Aud string `json:"aud"`
	Exp int64  `json:"exp"`
}

// SignSession mints the cookie value for a verified ticket subject.
//
// ttl is this hub's own session length, unrelated to the ticket's 90 seconds:
// the ticket's job ends the moment it is exchanged.
func SignSession(sub, secret string, now time.Time, ttl time.Duration) string {
	body, _ := json.Marshal(Session{Sub: sub, Aud: sessionAud, Exp: now.Add(ttl).Unix()})
	enc := base64.RawURLEncoding.EncodeToString(body)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(enc))
	return enc + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// VerifySession checks a cookie value. Every failure is ErrTicket — the caller
// answers "log in again" either way.
//
// ★ No clock skew here, deliberately. The 30s margin exists because a 90-second
// ticket crosses between two machines whose NTP never quite agrees. Extending an
// eight-hour cookie by 30 seconds buys nothing and makes "when does this expire"
// a question with two answers.
func VerifySession(cookie, secret string, now time.Time) (*Session, error) {
	if secret == "" || cookie == "" {
		return nil, ErrTicket
	}
	i := strings.LastIndex(cookie, ".")
	if i <= 0 || i == len(cookie)-1 {
		return nil, ErrTicket
	}
	body, sig64 := cookie[:i], cookie[i+1:]
	sig, err := base64.RawURLEncoding.DecodeString(sig64)
	if err != nil {
		return nil, ErrTicket
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(body))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return nil, ErrTicket
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return nil, ErrTicket
	}
	var s Session
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, ErrTicket
	}
	// The audience split, enforced on this side too: a ticket signed for the app
	// (aud "ccquota") must never pass as a session.
	if !hmac.Equal([]byte(s.Aud), []byte(sessionAud)) || s.Sub == "" {
		return nil, ErrTicket
	}
	if s.Exp < now.Unix() {
		return nil, ErrTicket
	}
	return &s, nil
}
