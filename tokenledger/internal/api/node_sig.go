package api

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A node's signed requests (claude-fleet#3699, EPIC #3500; 发起人拍板 23:
// signatures, not mTLS).
//
// A node — a machine (machine.env) or one login on it (node.env) — that
// registered an Ed25519 key with POST /v1/node/key signs a request instead of
// showing its token:
//
//	Authorization: FleetSig keyid=nk_…, ts=<unix seconds>, nonce=<16-64 of [A-Za-z0-9_-]>, sig=<base64url>
//
// over the lines (no trailing newline)
//
//	fleet-sig-v1 · keyid · ts · nonce · METHOD · request URI (path?query)
//
// A signature is good within ±NodeSigSkew of the hub's clock and ONCE: its
// nonce is spent in fleet_sig_nonces for NodeSigNonceKeep, longer than the
// whole window it could be accepted in. bin/fleet_node_sig.py is the node's
// half (keygen · register · header).
//
// No key registered ⇒ nothing changes: the bearer is read exactly as before
// (TestNodeSigOffAddsNothing).
const (
	nodeSigScheme    = "FleetSig"
	nodeSigVersion   = "fleet-sig-v1"
	nodeKeyProofLine = "fleet-node-key-v1"
	NodeKeyPath      = "/v1/node/key"
	NodeSigSkew      = 2 * time.Minute
	NodeSigNonceKeep = 5 * time.Minute
)

var nodeSigNonceRE = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

// NodeKeyID is a public key's id: nk_ + the first 24 hex of its SHA-256.
func NodeKeyID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return "nk_" + hex.EncodeToString(sum[:])[:24]
}

// NodeSigMessage is what a FleetSig signature covers.
func NodeSigMessage(keyID, ts, nonce, method, uri string) []byte {
	return []byte(strings.Join([]string{nodeSigVersion, keyID, ts, nonce, method, uri}, "\n"))
}

// parseNodeSig reads `FleetSig k=v, …`; ok false when the header is not one.
func parseNodeSig(h string) (map[string]string, bool) {
	if len(h) <= len(nodeSigScheme)+1 || !strings.EqualFold(h[:len(nodeSigScheme)+1], nodeSigScheme+" ") {
		return nil, false
	}
	out := map[string]string{}
	for _, part := range strings.Split(h[len(nodeSigScheme)+1:], ",") {
		k, v, found := strings.Cut(strings.TrimSpace(part), "=")
		if !found {
			continue
		}
		out[strings.ToLower(strings.TrimSpace(k))] = strings.Trim(strings.TrimSpace(v), `"`)
	}
	return out, true
}

// errNodeSig is a refused signature; its text is the answer's message.
type errNodeSig string

func (e errNodeSig) Error() string { return string(e) }

// verifyNodeSig authenticates a FleetSig request: the endpoint it proves and
// that endpoint's token hash (what a worker assertion is keyed with).
func (s *Server) verifyNodeSig(r *http.Request, f map[string]string, now time.Time) (*store.Endpoint, string, error) {
	keyID, ts, nonce, sig := f["keyid"], f["ts"], f["nonce"], f["sig"]
	if keyID == "" || ts == "" || nonce == "" || sig == "" {
		return nil, "", errNodeSig("FleetSig needs keyid, ts, nonce and sig")
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return nil, "", errNodeSig("FleetSig ts must be unix seconds")
	}
	if d := now.Sub(time.Unix(sec, 0)); d > NodeSigSkew || d < -NodeSigSkew {
		return nil, "", errNodeSig("FleetSig ts is outside ±2 minutes of the hub's clock")
	}
	if !nodeSigNonceRE.MatchString(nonce) {
		return nil, "", errNodeSig("FleetSig nonce must be 16-64 of [A-Za-z0-9_-]")
	}
	k, err := s.Store.NodeKeyByID(keyID)
	if err != nil {
		return nil, "", errNodeSig("unrecognised node key")
	}
	pub, err := base64.StdEncoding.DecodeString(k.PublicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, "", errNodeSig("unrecognised node key")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(sig, "="))
	if err != nil || !ed25519.Verify(pub, NodeSigMessage(keyID, ts, nonce, r.Method, r.URL.RequestURI()), raw) {
		return nil, "", errNodeSig("bad FleetSig signature")
	}
	fresh, err := s.Store.SpendSigNonce(keyID, nonce, now, NodeSigNonceKeep)
	if err != nil {
		return nil, "", err
	}
	if !fresh {
		return nil, "", errNodeSig("FleetSig nonce already used (a replayed request)")
	}
	ep, err := s.Store.LiveEndpoint(k.EndpointID)
	if err != nil {
		return nil, "", errNodeSig("unrecognised node key")
	}
	h, err := s.Store.EndpointTokenHash(ep.ID)
	if err != nil {
		return nil, "", err
	}
	return ep, h, nil
}

// nodeAuth is the ONE way a node request proves its endpoint: a FleetSig
// signature, else the bearer token — refused when the endpoint's key says
// everything on it signs (bearer_off). Answers the endpoint and its token
// hash, or an HTTP status + message.
func (s *Server) nodeAuth(r *http.Request) (*store.Endpoint, string, int, string) {
	if f, ok := parseNodeSig(r.Header.Get("Authorization")); ok {
		ep, h, err := s.verifyNodeSig(r, f, time.Now())
		var refused errNodeSig
		switch {
		case errors.As(err, &refused):
			return nil, "", http.StatusUnauthorized, err.Error()
		case err != nil:
			return nil, "", http.StatusInternalServerError, err.Error()
		}
		return ep, h, 0, ""
	}
	tok := bearer(r)
	if tok == "" {
		return nil, "", http.StatusUnauthorized, "missing bearer token"
	}
	h := HashToken(tok)
	ep, err := s.Store.EndpointByTokenHash(h)
	if err != nil {
		return nil, "", http.StatusUnauthorized, "unrecognised enrollment token"
	}
	k, err := s.Store.NodeKeyOf(ep.ID)
	switch {
	case err == nil && k.BearerOff:
		return nil, "", http.StatusUnauthorized,
			"this node signs its requests (FleetSig, key " + k.KeyID + "); its bare token is refused"
	case err != nil && !errors.Is(err, store.ErrNoNodeKey):
		return nil, "", http.StatusInternalServerError, err.Error()
	}
	return ep, h, 0, ""
}

// handleNodeKey serves /v1/node/key: GET says the endpoint's key; POST
// registers {public_key, proof, bearer_off} — proof is the key's signature
// over "fleet-node-key-v1\n<public_key>", so nobody registers a key they do
// not hold. The caller proves its endpoint by nodeAuth like any node request:
// once bearer_off is set only a signature can change it.
func (s *Server) handleNodeKey(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	ep, _, code, msg := s.nodeAuth(r)
	if ep == nil {
		httpError(w, code, msg)
		return
	}
	switch r.Method {
	case http.MethodGet:
		k, err := s.Store.NodeKeyOf(ep.ID)
		if errors.Is(err, store.ErrNoNodeKey) {
			writeJSON(w, http.StatusOK, map[string]any{"key_id": "", "bearer_off": false})
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"key_id": k.KeyID, "bearer_off": k.BearerOff, "created_at": k.CreatedAt})
	case http.MethodPost:
		var req struct {
			PublicKey string `json:"public_key"`
			Proof     string `json:"proof"`
			BearerOff bool   `json:"bearer_off"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "the body must be one JSON object")
			return
		}
		pub, err := base64.StdEncoding.DecodeString(req.PublicKey)
		if err != nil || len(pub) != ed25519.PublicKeySize {
			httpError(w, http.StatusBadRequest, "public_key must be a base64 Ed25519 public key")
			return
		}
		proof, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(req.Proof, "="))
		if err != nil || !ed25519.Verify(pub, []byte(nodeKeyProofLine+"\n"+req.PublicKey), proof) {
			httpError(w, http.StatusBadRequest, "proof must be the key's signature over \"fleet-node-key-v1\\n<public_key>\"")
			return
		}
		k := store.NodeKey{KeyID: NodeKeyID(pub), EndpointID: ep.ID, PublicKey: req.PublicKey, BearerOff: req.BearerOff}
		if err := s.Store.RegisterNodeKey(k, time.Now()); err != nil {
			httpError(w, http.StatusConflict, err.Error())
			return
		}
		got, err := s.Store.NodeKeyOf(ep.ID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		host, user := s.nodeIdentity(ep)
		if err := s.Store.FleetAudit("node:"+user+"@"+host, "node_key", got.KeyID,
			"registered bearer_off="+strconv.FormatBool(got.BearerOff), "", time.Now()); err != nil {
			log.Printf("fleet audit: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]any{"key_id": got.KeyID, "bearer_off": got.BearerOff})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}
