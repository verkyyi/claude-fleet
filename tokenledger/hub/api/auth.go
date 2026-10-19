package api

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
)

// tokenBytes is the entropy in a minted token. 32 bytes is well past guessing
// range and keeps the printed string short enough to paste into a config file.
const tokenBytes = 32

// MintToken returns a new random bearer token. It is shown to the operator
// once, at enrollment, and only its hash is ever stored.
func MintToken() (string, error) {
	b := make([]byte, tokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate token: %w", err)
	}
	return "ccq_" + base64.RawURLEncoding.EncodeToString(b), nil
}

// HashToken is the one-way function used for storage and lookup.
//
// A plain SHA-256 is right here, not a password hash: these are 256-bit random
// secrets, not human-chosen passwords, so there is no dictionary to slow down
// and the lookup happens on every push from every endpoint.
func HashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// bearer extracts a token from the Authorization header.
func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) > len(prefix) && strings.EqualFold(h[:len(prefix)], prefix) {
		return h[len(prefix):]
	}
	return ""
}

// constantTimeEqual compares two secrets without leaking their contents
// through timing.
func constantTimeEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
