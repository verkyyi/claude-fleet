package control

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// The chat relay (claude-fleet#3644, EPIC #3642 C2): a person's browser talks to
// the ONE conversation service of their home login (extras/web-chat/server.mjs,
// listening only on that login's $FLEET_CONF_DIR/webchat/chat.sock). The hub
// finds the person's home, asks that login's agent on its control channel for
// one relay, and the agent dials a data stream back — exactly the shape of the
// SSH relay (#1413):
//
//	hub ──TypeChatRelayOpen {relay_id, secret, login}──▶ the login's agent
//	agent ──wss ChatRelayDataPath?id=…──▶ hub
//	hub ──first frame {"person": "fpp1.…"} (X-Fleet-Person)──▶ agent
//	agent ──as the login──▶ $FLEET_CONF_DIR/webchat/chat.sock
//
// The agent verifies the first frame before it touches the socket: a statement
// signed by the hub with THIS login's node token hash (the hub stores it, the
// agent computes it from its token — the worker assertion's keying, #1810), for
// this login and this relay, not expired. Anything else closes the stream and
// the socket never sees a byte. The target is the login's one socket: nothing
// the hub sends names a path, an address or a port.
const (
	// ChatRelayDataPath is where the agent dials the data half of one chat relay.
	ChatRelayDataPath = "/v1/node/chat-relay"

	// TypeChatRelayOpen is a hub→node request: dial ChatRelayDataPath for this
	// relay and splice it to the login's conversation socket. Sent only to a
	// node whose hello listed CapChat.
	TypeChatRelayOpen = "chat_relay_open"

	// CapChat is the hello capability of an agent that serves TypeChatRelayOpen.
	CapChat = "chat"

	// ChatPersonHeader names the statement the first frame carries.
	ChatPersonHeader = "X-Fleet-Person"

	// ChatClientHeader is where the browser's address (and the city the
	// entry's offline database puts it in) rides to the conversation service,
	// base64url JSON written by the entry on the relayed request — never taken
	// from the browser (claude-fleet#4034). It travels on the stream the agent
	// opened after the first frame verified, like the request's X-Fleet-Person.
	ChatClientHeader = "X-Fleet-Client"

	chatPersonPrefix = "fpp1"
	// ChatPersonMaxTTL bounds exp-iat: a statement is minted per relay, the
	// moment the agent attaches, so minutes are plenty.
	ChatPersonMaxTTL = 5 * time.Minute
	chatPersonSkew   = time.Minute
)

// ChatRelayOpen is the payload of TypeChatRelayOpen. It has no target field on
// purpose: the agent reaches the login's one socket, whatever else arrives.
type ChatRelayOpen struct {
	// RelayID names the relay; the agent dials ChatRelayDataPath?id=<RelayID>.
	RelayID string `json:"relay_id"`
	// Secret is echoed back as X-Relay-Secret, as for the SSH relay.
	Secret string `json:"secret,omitempty"`
	// Login is the login the relay is for: an agent serving another login
	// refuses it.
	Login string `json:"login"`
}

// ChatRelayHello is the first frame on the data stream, hub → agent (text).
type ChatRelayHello struct {
	// Person is the X-Fleet-Person statement (SignChatPerson).
	Person string `json:"person"`
}

// ChatPerson is a verified X-Fleet-Person statement: who the relay is for.
type ChatPerson struct {
	V int `json:"v"`
	// Person is the principal the hub admitted (their GitHub id / name).
	Person string `json:"person"`
	// Login is the home login the relay reaches.
	Login string `json:"login"`
	// Relay is the relay id the statement was minted for.
	Relay string `json:"relay"`
	Iat   int64  `json:"iat"`
	Exp   int64  `json:"exp"`
}

// ChatTokenHash is the key a login's statements are signed with: SHA-256 hex
// of its node token — api.HashToken, which the hub already stores.
func ChatTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// SignChatPerson is the hub's half: fpp1.<claims>.<HMAC-SHA256>, keyed with the
// login's token hash.
func SignChatPerson(c ChatPerson, tokenHash string) string {
	return signStatement(chatPersonPrefix, c, tokenHash)
}

// VerifyChatPerson is the agent's half: the statement must verify with this
// login's token hash, name this login and this relay, and hold now. Every
// fault is an error — a statement that does not hold is never "no statement".
func VerifyChatPerson(s, tokenHash, login, relay string, now time.Time) (*ChatPerson, error) {
	bad := func(why string) error { return errors.New("X-Fleet-Person: " + why) }
	raw, err := verifyStatement(chatPersonPrefix, s, tokenHash)
	if err != nil {
		return nil, bad(err.Error())
	}
	var c ChatPerson
	if err := json.Unmarshal(raw, &c); err != nil || c.V != 1 || c.Person == "" {
		return nil, bad("malformed claims")
	}
	switch {
	case c.Login != login:
		return nil, bad("for another login")
	case c.Relay != relay:
		return nil, bad("for another relay")
	}
	if why := statementWindow(c.Iat, c.Exp, ChatPersonMaxTTL, now); why != "" {
		return nil, bad(why)
	}
	return &c, nil
}

// signStatement is one hub statement: <prefix>.<claims>.<HMAC-SHA256>, keyed
// with a login's token hash. The prefix names the service it is for (fpp1 the
// chat relay, ftg1 the terminal — claude-fleet#3838): verifyStatement checks it
// before the signature, so a statement minted for one service never opens the
// other.
func signStatement(prefix string, claims any, tokenHash string) string {
	raw, _ := json.Marshal(claims)
	body := prefix + "." + base64.RawURLEncoding.EncodeToString(raw)
	mac := hmac.New(sha256.New, []byte(tokenHash))
	mac.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// verifyStatement checks s is a prefix statement signed with tokenHash and
// returns its claims, unread.
func verifyStatement(prefix, s, tokenHash string) ([]byte, error) {
	if tokenHash == "" {
		return nil, errors.New("no key to verify with")
	}
	parts := strings.Split(strings.TrimSpace(s), ".")
	if len(parts) != 3 || parts[0] != prefix {
		return nil, errors.New("malformed")
	}
	got, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, errors.New("malformed")
	}
	mac := hmac.New(sha256.New, []byte(tokenHash))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(mac.Sum(nil), got) {
		return nil, errors.New("signature does not verify (not signed for this login)")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("malformed")
	}
	return raw, nil
}

// statementWindow is "" when a statement issued at iat and expiring at exp
// holds now and lives no longer than max, else why not.
func statementWindow(iat, exp int64, max time.Duration, now time.Time) string {
	i, e := time.Unix(iat, 0), time.Unix(exp, 0)
	switch {
	case !e.After(now):
		return "expired"
	case i.After(now.Add(chatPersonSkew)), e.Sub(i) > max, !e.After(i):
		return "issued/expires out of range"
	}
	return ""
}
