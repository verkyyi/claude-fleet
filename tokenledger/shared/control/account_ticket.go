package control

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// The admin seat's signed ticket (claude-fleet#3557, EPIC #3500 C15).
//
// A machine's account ops move off the admin's own login onto a role account
// (_fleetadmin / fleetadmin) that may run exactly two root-owned scripts
// through sudo. Those scripts trust no one who can reach the role account:
// each runs an op only with a ticket the hub signed with its account-op key —
// {op, login, machine, nonce, exp}, single-use (the nonce is the op's OpID,
// spent on the machine in a root-owned book), short-lived. A forged, expired,
// replayed or mismatched ticket is refused before anything runs. A hub with
// no account key, or a node that does not list CapAdminSeat, carries no
// ticket: byte for byte as before.

// CapAdminSeat is the hello capability of an admin agent that runs as the
// machine's admin role account: it runs an account op only through the two
// root-owned scripts, and only with a ticket. The hub prefers it over an
// admin login's agent on the same machine (step E: the old agent finishes the
// op in its hands and is sent no new one), and never sends it an op unsigned.
const CapAdminSeat = "admin_seat"

// AccountKeyPath serves the account-op public key (`ed25519 <base64>`), public
// like the release key; 404 while the hub has none. The machine's root
// installer pins it beside the scripts — the seat never hands it over.
const AccountKeyPath = "/v1/fleet/account-key"

// AccountTicketTTL is how long a ticket stays good: an op is run within
// seconds of its send, and a re-ask signs a fresh one.
const AccountTicketTTL = 10 * time.Minute

// accountTicketPrefix versions the encoding; accountTicketDomain separates
// the signed bytes from anything else the key could ever sign.
const (
	accountTicketPrefix = "v1."
	accountTicketDomain = "fleet-account-ticket-v1\x00"
)

// AccountTicket is what the hub signs for one account op.
type AccountTicket struct {
	Op      string `json:"op"`
	Login   string `json:"login"`
	Machine string `json:"machine"`
	Nonce   string `json:"nonce"`
	Exp     int64  `json:"exp"`
}

// SignAccountTicket is `v1.<payload>.<sig>`, both base64url (no padding): the
// signature is over the domain string and the payload bytes exactly as sent,
// so a verifier never re-serializes anything.
func SignAccountTicket(key ed25519.PrivateKey, t AccountTicket) (string, error) {
	if len(key) != ed25519.PrivateKeySize {
		return "", errors.New("no account key")
	}
	payload, err := json.Marshal(t)
	if err != nil {
		return "", err
	}
	sig := ed25519.Sign(key, append([]byte(accountTicketDomain), payload...))
	enc := base64.RawURLEncoding
	return accountTicketPrefix + enc.EncodeToString(payload) + "." + enc.EncodeToString(sig), nil
}

// VerifyAccountTicket checks a ticket's signature and expiry and returns it.
// The caller still matches op / login / machine and spends the nonce — the
// machine's verifier (bin/fleet_admin_ticket.py) is the one that runs ops;
// this is its Go twin, kept for the hub's tests and the agent's own check.
func VerifyAccountTicket(pub ed25519.PublicKey, s string, now time.Time) (AccountTicket, error) {
	var t AccountTicket
	rest, ok := strings.CutPrefix(s, accountTicketPrefix)
	if !ok {
		return t, errors.New("not a v1 account ticket")
	}
	p64, s64, ok := strings.Cut(rest, ".")
	if !ok {
		return t, errors.New("malformed account ticket")
	}
	enc := base64.RawURLEncoding
	payload, err1 := enc.DecodeString(p64)
	sig, err2 := enc.DecodeString(s64)
	if err1 != nil || err2 != nil || len(pub) != ed25519.PublicKeySize {
		return t, errors.New("malformed account ticket")
	}
	if !ed25519.Verify(pub, append([]byte(accountTicketDomain), payload...), sig) {
		return t, errors.New("account ticket: bad signature")
	}
	if err := json.Unmarshal(payload, &t); err != nil {
		return t, errors.New("malformed account ticket")
	}
	if t.Nonce == "" || t.Op == "" || t.Login == "" || t.Machine == "" {
		return t, errors.New("account ticket: missing field")
	}
	if now.Unix() >= t.Exp {
		return t, errors.New("account ticket: expired")
	}
	return t, nil
}
