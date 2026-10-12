package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// frl2 — a relay pass that lives hours, not forever (claude-fleet#3561,
// EPIC #3500 C19, 发起人拍板 20).
//
// frl1 is a random string whose hash the hub keeps; it never expires, and the
// relay can only ask the hub whether it still passes. With a relay signing key
// (CCQUOTA_FLEET_RELAY_SIGN_KEY[_FILE], an Ed25519 seed) the hub mints
//
//	frl2.<base64url claims JSON>.<base64url Ed25519 signature>
//
// claims {v, jti, machine, login, principal, iat, exp}, exp = iat + RelayPassTTL
// (4 h). The relay's sidecar verifies it itself — the public key comes with the
// revocation list (`relay_pub`) — and refuses by the list's `frl2:<jti>` entries
// and {machine|login|principal, before} scopes; it never asks the hub. The hub's
// own check (the sidecar without the key, or the old road) verifies the same
// signature and also asks that the machine's setting still names this jti for
// the login: a re-mint supersedes the previous pass there, a revoke drops it.
//
// The pass is renewed only when it is needed (the machine's proxy: < 20 % left
// when it is used, or at 80 % of its life) — never on a timer of its own.
// No key ⇒ the hub mints frl1 exactly as before (TestRelayFrl2OffAddsNothing).

const (
	relayPass2Prefix = "frl2."
	// RelayPassTTL is an frl2 pass's life.
	RelayPassTTL = 4 * time.Hour
	// relayPass2Word marks an frl2 jti in the machine's setting
	// (`<login>:frl2@<jti>`), beside frl1's bare hashes.
	relayPass2Word = "frl2@"
)

type relayPass2Claims struct {
	V         int    `json:"v"`
	JTI       string `json:"jti"`
	Machine   string `json:"machine"`
	Login     string `json:"login"`
	Principal string `json:"principal"`
	Iat       int64  `json:"iat"`
	Exp       int64  `json:"exp"`
}

// LoadRelaySignKey reads the relay pass signing key:
// CCQUOTA_FLEET_RELAY_SIGN_KEY_FILE wins over CCQUOTA_FLEET_RELAY_SIGN_KEY;
// either holds a 32-byte Ed25519 seed, base64 encoded (openssl rand -base64 32).
// ok is false when neither is set.
func LoadRelaySignKey(getenv func(string) string) (key ed25519.PrivateKey, ok bool, err error) {
	raw := strings.TrimSpace(getenv("CCQUOTA_FLEET_RELAY_SIGN_KEY"))
	if path := getenv("CCQUOTA_FLEET_RELAY_SIGN_KEY_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, true, fmt.Errorf("read relay sign key: %w", err)
		}
		raw = strings.TrimSpace(string(b))
	}
	if raw == "" {
		return nil, false, nil
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(raw); err == nil && len(b) == ed25519.SeedSize {
			return ed25519.NewKeyFromSeed(b), true, nil
		}
	}
	return nil, true, errors.New("relay sign key must be a 32-byte Ed25519 seed, base64 encoded (openssl rand -base64 32)")
}

// RelayPub is the public half a relay verifies frl2 with ("" = no key).
func (s *Server) RelayPub() string {
	if len(s.RelaySignKey) != ed25519.PrivateKeySize {
		return ""
	}
	return base64.StdEncoding.EncodeToString(s.RelaySignKey.Public().(ed25519.PublicKey))
}

func signRelayPass2(c relayPass2Claims, key ed25519.PrivateKey) string {
	raw, _ := json.Marshal(c)
	body := relayPass2Prefix + base64.RawURLEncoding.EncodeToString(raw)
	return body + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, []byte(body)))
}

// parseRelayPass2 checks shape, signature and life; the reason is what a
// refusal says.
func parseRelayPass2(tok string, pub ed25519.PublicKey, now time.Time) (*relayPass2Claims, string) {
	if !strings.HasPrefix(tok, relayPass2Prefix) {
		return nil, "not a relay pass"
	}
	i := strings.LastIndexByte(tok, '.')
	if i <= len(relayPass2Prefix) {
		return nil, "malformed relay pass"
	}
	sig, err := base64.RawURLEncoding.DecodeString(tok[i+1:])
	if err != nil || len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, []byte(tok[:i]), sig) {
		return nil, "bad relay pass signature"
	}
	raw, err := base64.RawURLEncoding.DecodeString(tok[len(relayPass2Prefix):i])
	if err != nil {
		return nil, "malformed relay pass"
	}
	var c relayPass2Claims
	if json.Unmarshal(raw, &c) != nil || c.V != 2 || c.JTI == "" || c.Machine == "" || c.Login == "" {
		return nil, "malformed relay pass"
	}
	if now.Unix() >= c.Exp {
		return &c, "relay pass expired"
	}
	return &c, ""
}

// mintRelayPass2 is the frl2 half of handleNodeRelayCredential: the pass, and
// the setting word that names it as this login's current one.
func (s *Server) mintRelayPass2(machine, login, principal string, now time.Time) (tok, word string, exp time.Time, err error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", "", time.Time{}, err
	}
	jti := hex.EncodeToString(b[:])
	exp = now.Add(RelayPassTTL)
	tok = signRelayPass2(relayPass2Claims{V: 2, JTI: jti, Machine: machine, Login: login, Principal: principal,
		Iat: now.Unix(), Exp: exp.Unix()}, s.RelaySignKey)
	return tok, relayPass2Word + jti, exp, nil
}

// relayJudge2 is the hub's verdict on an frl2 pass.
func (s *Server) relayJudge2(tok string, now time.Time) relayVerdict {
	if len(s.RelaySignKey) != ed25519.PrivateKeySize {
		return relayVerdict{why: "relay passes v2 are off on this hub"}
	}
	c, why := parseRelayPass2(tok, s.RelaySignKey.Public().(ed25519.PublicKey), now)
	if why != "" {
		return relayVerdict{why: why}
	}
	settings, err := s.trustSettings(now)
	if err != nil {
		return relayVerdict{why: "the hub could not read its settings"}
	}
	if relayEntries(settings[relayKey(c.Machine)])[c.Login] != relayPass2Word+c.JTI {
		return relayVerdict{why: "superseded or revoked relay pass"}
	}
	if !s.machineTrusted(c.Machine, settings) {
		return relayVerdict{why: c.Machine + " is not a trusted machine"}
	}
	if rev, err := s.Store.RevokedFor(c.Machine, c.Principal); err != nil {
		return relayVerdict{why: "the hub could not read its revocations"}
	} else if rev != nil {
		return relayVerdict{why: c.Machine + " was revoked"}
	}
	return relayVerdict{ok: true, who: c.Login + "@" + c.Machine}
}

// revRelayPass2 are the list entries a revoke of machine's frl2 passes adds:
// one per jti its setting names, kept as long as any can live.
func revRelayPass2(machine string, settings map[string]string, src string, now time.Time) []store.Revocation {
	out := []store.Revocation{}
	for k, v := range settings {
		if !strings.HasPrefix(k, NodeRelayPrefix) || v == "" {
			continue
		}
		m := k[len(NodeRelayPrefix):]
		if machine != "" && !sameMachine(machine, m) && !sameMachine(m, machine) {
			continue
		}
		for login, w := range relayEntries(v) {
			if strings.HasPrefix(w, relayPass2Word) {
				out = append(out, store.Revocation{JTI: "frl2:" + w[len(relayPass2Word):], Machine: revMachine(m),
					Login: login, Exp: now.Add(RelayPassTTL).Unix(), Src: src})
			}
		}
	}
	return out
}
