// Package nodesig is a node's half of the hub's signed requests
// (claude-fleet#3699 / #3710): a machine or a login that holds an Ed25519 key
// beside its token signs a request instead of showing the token —
//
//	Authorization: FleetSig keyid=nk_…, ts=<unix>, nonce=<random>, sig=<b64url>
//
// over `fleet-sig-v1 · keyid · ts · nonce · METHOD · URI`
// (internal/api/node_sig.go is the hub's half, bin/fleet_node_sig.py the
// shell's). The key file is bin/fleet_node_sig.py's: the 32-byte seed in base64
// on one line, 0600. It lives beside the env file that holds the token —
// machine.env → machine.key, node.env → node.key, logins/<l>.env → logins/<l>.key.
//
// A key signs only once the hub has said it is this node's (Ensure, which
// writes <key>.ok = "<keyid> <hub>"): no key, no answer, or a hub that predates
// #3699 ⇒ the bearer, byte for byte as before.
package nodesig

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	version   = "fleet-sig-v1"
	proofLine = "fleet-node-key-v1"
	keyPath   = "/v1/node/key"
)

// Signer is one node's private key.
type Signer struct {
	priv ed25519.PrivateKey
	id   string
}

// ID is the key's id: nk_ + the first 24 hex of sha256(public key).
func (s *Signer) ID() string { return s.id }

func fromSeed(seed []byte) *Signer {
	priv := ed25519.NewKeyFromSeed(seed)
	sum := sha256.Sum256(priv.Public().(ed25519.PublicKey))
	return &Signer{priv: priv, id: "nk_" + hex.EncodeToString(sum[:])[:24]}
}

// Load reads a key file; nil, nil when there is none (or it cannot be read —
// a separated login's key is not this process's to read).
func Load(path string) (*Signer, error) {
	if path == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("%s: not a 32-byte Ed25519 seed", path)
	}
	return fromSeed(seed), nil
}

// keygen writes a new key file (0600, never over one).
func keygen(path string) error {
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, err = f.WriteString(base64.StdEncoding.EncodeToString(seed) + "\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(path)
	}
	return err
}

// Beside is the key file that goes with an env file: <dir>/<stem>.key.
func Beside(envFile string) string {
	if envFile == "" {
		return ""
	}
	return strings.TrimSuffix(envFile, filepath.Ext(envFile)) + ".key"
}

// LoginKeyPath is this login's key file, the way bin/fleet-lib.sh finds it:
// $CCQUOTA_NODE_KEY (off = none), else <conf dir>/node.key beside node.env — none for a
// separated login (credsep.json: its token is not in the home, and neither may
// its key be).
func LoginKeyPath() string {
	if p := os.Getenv("CCQUOTA_NODE_KEY"); p == "off" {
		return ""
	} else if p != "" {
		return p
	}
	conf := os.Getenv("FLEET_CONF_DIR")
	if conf == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		conf = filepath.Join(home, ".config", "claude-fleet")
	}
	if _, err := os.Stat(filepath.Join(conf, "credsep.json")); err == nil {
		return ""
	}
	return filepath.Join(conf, "node.key")
}

func normHub(hub string) string { return strings.TrimRight(hub, "/") }

// Confirmed is the key at path when Ensure has seen the hub at hub take it
// (<key>.ok); nil otherwise — the caller shows its token.
func Confirmed(path, hub string) *Signer {
	s, err := Load(path)
	if err != nil || s == nil {
		return nil
	}
	ok, err := os.ReadFile(path + ".ok")
	if err != nil || strings.TrimSpace(string(ok)) != s.id+" "+normHub(hub) {
		return nil
	}
	return s
}

// Header is the Authorization value for one request.
func (s *Signer) Header(method, uri string) string {
	return s.headerAt(method, uri, time.Now(), "")
}

func (s *Signer) headerAt(method, uri string, now time.Time, nonce string) string {
	if nonce == "" {
		b := make([]byte, 18)
		_, _ = rand.Read(b)
		nonce = base64.RawURLEncoding.EncodeToString(b)
	}
	ts := strconv.FormatInt(now.Unix(), 10)
	msg := strings.Join([]string{version, s.id, ts, nonce, strings.ToUpper(method), uri}, "\n")
	sig := ed25519.Sign(s.priv, []byte(msg))
	return "FleetSig keyid=" + s.id + ", ts=" + ts + ", nonce=" + nonce + ", sig=" + base64.RawURLEncoding.EncodeToString(sig)
}

// Authorization is what a request to rawURL carries: a signature when s is
// set, else the bearer token.
func Authorization(s *Signer, token, method, rawURL string) string {
	if s == nil {
		return "Bearer " + token
	}
	uri := rawURL
	if i := strings.Index(rawURL, "://"); i >= 0 {
		rest := rawURL[i+3:]
		if j := strings.IndexByte(rest, '/'); j >= 0 {
			uri = rest[j:]
		} else {
			uri = "/"
		}
	}
	return s.Header(method, uri)
}

// Set puts the Authorization header on req (Authorization's rule).
func Set(req *http.Request, s *Signer, token string) {
	if s == nil {
		req.Header.Set("Authorization", "Bearer "+token)
		return
	}
	req.Header.Set("Authorization", s.Header(req.Method, req.URL.RequestURI()))
}

func (s *Signer) registerBody() []byte {
	pub := base64.StdEncoding.EncodeToString(s.priv.Public().(ed25519.PublicKey))
	proof := base64.RawURLEncoding.EncodeToString(ed25519.Sign(s.priv, []byte(proofLine+"\n"+pub)))
	b, _ := json.Marshal(map[string]any{"public_key": pub, "proof": proof})
	return b
}

// Ensure makes path this node's registered key and answers it, or nil — the
// node then keeps showing its token. A missing key is made (when the directory
// takes it); a key the hub does not hold is registered with the token; a key
// the hub has bound to another endpoint (a node that joined again) is set
// aside as <key>.old-<unix> and a new one registered. A hub that predates
// #3699 (404), refuses the token, or cannot be reached ⇒ nil, nothing else
// changes. note is one line for the log when something was done or refused.
func Ensure(ctx context.Context, c *http.Client, hub, token, path string) (s *Signer, note string) {
	if path == "" || hub == "" || token == "" {
		return nil, ""
	}
	if c == nil {
		c = &http.Client{Timeout: 15 * time.Second}
	}
	hub = normHub(hub)
	made := false
	for attempt := 0; attempt < 2; attempt++ {
		cur, err := Load(path)
		if err != nil {
			return nil, "node key: " + err.Error()
		}
		if cur == nil {
			if _, serr := os.Stat(path); serr == nil {
				return nil, "" // there, not ours to read
			}
			// a hub that does not take keys gets none made for it
			if code, _ := call(ctx, c, http.MethodGet, hub+keyPath, nil, nil, token); code != http.StatusOK {
				return nil, ""
			}
			if err := keygen(path); err != nil {
				return nil, "" // the directory is not ours to write: the token it is
			}
			made = true
			if cur, err = Load(path); err != nil || cur == nil {
				return nil, "node key: cannot read the key just made"
			}
		}
		// asked with the token: it is the token's endpoint the key must be
		// (a node that joined again holds a key of its old one); a token its
		// node turned off (bearer_off) leaves only the key to ask with
		code, body := call(ctx, c, http.MethodGet, hub+keyPath, nil, nil, token)
		if code == http.StatusUnauthorized {
			code, body = call(ctx, c, http.MethodGet, hub+keyPath, nil, cur, token)
		}
		switch code {
		case http.StatusOK:
		case http.StatusNotFound:
			return nil, ""
		default:
			return nil, fmt.Sprintf("node key: GET %s answered %d", keyPath, code)
		}
		var got struct {
			KeyID string `json:"key_id"`
		}
		_ = json.Unmarshal(body, &got)
		if got.KeyID != cur.id {
			code, body = call(ctx, c, http.MethodPost, hub+keyPath, cur.registerBody(), nil, token)
			if code == http.StatusConflict && attempt == 0 {
				_ = os.Rename(path, fmt.Sprintf("%s.old-%d", path, time.Now().Unix()))
				_ = os.Remove(path + ".ok")
				continue
			}
			if code != http.StatusOK {
				return nil, fmt.Sprintf("node key: registering %s answered %d: %s", cur.id, code, firstLine(body))
			}
			note = "node key: " + cur.id + " registered with the hub"
			if made {
				note = "node key: " + cur.id + " made and registered with the hub"
			}
		}
		_ = writeOK(path, cur.id+" "+hub)
		return cur, note
	}
	return nil, "node key: the hub keeps refusing a new key"
}

func writeOK(path, line string) error {
	tmp := fmt.Sprintf("%s.ok.tmp-%d", path, os.Getpid())
	if err := os.WriteFile(tmp, []byte(line+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path+".ok")
}

func call(ctx context.Context, c *http.Client, method, url string, body []byte, s *Signer, token string) (int, []byte) {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rd)
	if err != nil {
		return 0, nil
	}
	Set(req, s, token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := c.Do(req)
	if err != nil {
		return 0, nil
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 4<<10))
	return res.StatusCode, raw
}

func firstLine(b []byte) string {
	s := strings.TrimSpace(string(b))
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}
