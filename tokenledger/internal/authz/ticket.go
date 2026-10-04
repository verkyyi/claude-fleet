// Package authz verifies the入场票 a 24haowan authorization service signs for a
// downstream site, and turns it into this hub's own session.
//
// # Why a ticket at all
//
// 企微自建应用的「网页授权回调域」整个 corp 只能填 1 个、且不覆盖子域 —— it is
// ai.24haowan.com. So this host cannot run the WeCom OAuth dance itself, and no
// proxy in front of it can either: the callback domain is not something a proxy
// gets to move. The shape the platform settled on instead is
// **OAuth runs on ai., a short-lived ticket crosses to the other host, and the
// other host mints its own host-only cookie** — see
// 24haowan-monorepo doc/review/sso-consolidation.md (硬约束 1).
//
// # The format is a cross-language contract, not a local choice
//
//	base64url(JSON payload) + "." + base64url(HMAC-SHA256(<that ASCII>, secret))
//
// ★ The HMAC input is the bytes of the **base64url text**, not the JSON before
// encoding. That is the single point the four implementations are most likely to
// disagree on, and disagreeing looks like "401 forever while both sides look
// correct".
//
// This is the FOURTH implementation. The other three, which the golden vector in
// ticket_test.go is shared with byte for byte:
//
//	core/kf-context/src/authzTicket.ts      (signs)
//	ai-site/app/lib/aicallTicket.ts         (signs)
//	core/aicall/backend/app/ticket.py       (verifies)
//
// # What this package deliberately does NOT do
//
// It does not sign. A downstream that can sign is a second issuer, and the whole
// value of the `iss` whitelist is that "who signed this" stays answerable — the
// only thing that still separates issuers once an HMAC key leaks.
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

// ErrTicket is the only error Verify returns.
//
// Deliberately one kind: the caller answers 401 either way, and a caller that
// can tell "bad key" from "expired" hands that distinction to whoever is
// probing it.
var ErrTicket = errors.New("ticket rejected")

// Issuers may sign a ticket for this hub.
//
// ★ The test is membership, not presence. Accepting any ticket that merely
// carries an `iss` would accept everyone's.
//
// ★ ai-site is on the list even though kf-context is the issuer we expect,
// because the platform's migration order is always "收票方先接受，签发方再出现"
// (#4830). A downstream that only accepts today's issuer forces tomorrow's to
// either impersonate it or be rejected on cutover day.
//
// ⚠️ Being listed is not permission to sign: the issuer still needs this app's
// own ticket key (P3 — one key per app, never the session key).
var Issuers = []string{"ai-site", "kf-context"}

// ClockSkewSec is the tolerance on exp.
//
// The ticket lives 90 seconds. Two machines' NTP never agree exactly, and with
// no margin a few seconds of drift becomes "occasional login failures" — the
// hardest kind to chase. 30s is generous against drift and still far short of
// the TTL. Same value as core/aicall/backend/app/ticket.py.
const ClockSkewSec = 30

// Payload is the ticket's claims.
//
// Field order in the JSON is part of the contract on the signing side; here it
// only has to parse, but the tags keep the names visibly identical to the other
// three implementations.
type Payload struct {
	// Iss is kept verbatim, never normalised — an audit line has to be able to
	// say which service signed this.
	Iss string `json:"iss"`
	// Aud is the downstream app id. Checked field-for-field against our own.
	Aud string `json:"aud"`
	// Sub is the authorization subject. `Ten` is attribution only.
	Sub string `json:"sub"`
	Ten string `json:"ten"`
	Iat int64  `json:"iat"`
	Exp int64  `json:"exp"`
	// Switchable is the optional `swi` claim ("this session may switch demo
	// identities"). It is present only when true — a missing key is why the
	// golden vector is byte-identical across the guest and WeCom paths.
	// This hub reads it and grants nothing for it.
	Switchable bool `json:"swi,omitempty"`
}

// Verify checks signature, issuer, audience, subject and expiry, and returns the
// claims. Every failure is ErrTicket.
//
// An empty secret is always a rejection, never a fallback to some default: a
// default signing key is a thing that mints any identity out of thin air.
func Verify(token, secret, audience string, now time.Time) (*Payload, error) {
	if secret == "" || audience == "" || token == "" {
		return nil, ErrTicket
	}
	// The signature is the last dot-separated field; the body may not contain a
	// dot today, but splitting from the right is what the other three do.
	i := strings.LastIndex(token, ".")
	if i <= 0 || i == len(token)-1 {
		return nil, ErrTicket
	}
	body, sig64 := token[:i], token[i+1:]

	sig, err := base64.RawURLEncoding.DecodeString(sig64)
	if err != nil {
		return nil, ErrTicket
	}
	mac := hmac.New(sha256.New, []byte(secret))
	// ★ The signed bytes are the encoded body's ASCII, not the decoded JSON.
	mac.Write([]byte(body))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return nil, ErrTicket
	}

	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return nil, ErrTicket
	}
	var p Payload
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, ErrTicket
	}
	if !knownIssuer(p.Iss) || !hmac.Equal([]byte(p.Aud), []byte(audience)) {
		return nil, ErrTicket
	}
	if p.Sub == "" {
		return nil, ErrTicket
	}
	if p.Exp+ClockSkewSec < now.Unix() {
		return nil, ErrTicket
	}
	return &p, nil
}

func knownIssuer(iss string) bool {
	for _, k := range Issuers {
		if hmac.Equal([]byte(k), []byte(iss)) {
			return true
		}
	}
	return false
}
