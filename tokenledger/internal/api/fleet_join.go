package api

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Adding a machine in one command (claude-fleet#1418).
//
//	operator  POST /v1/fleet/join-codes        → {code, expires_at, command}
//	machine   POST /v1/node/join {code, …}     → its own enrollment token
//	machine   GET  /v1/node/dist/<os>-<arch>   → the ccquota binary (token auth)
//	machine   GET  /v1/node/self               → is the hub seeing me yet (token auth)
//
// The code is the only credential that crosses by hand, and it is worth
// little: one redemption, within JoinCodeTTL, of an agent enrollment — the
// same thing `ccquota enroll` mints on the hub. What that agent may do once
// enrolled is unchanged: the admin role still needs its OS login in
// CCQUOTA_FLEET_ADMIN_USERS (claude-fleet#1411), whatever the joining side says.
//
// Format: "fj_" + 26 lowercase base32 characters (130 random bits). Long
// enough that guessing within ten minutes is not a strategy, short enough to
// paste into a terminal over a phone screen.

// JoinCodeTTL is how long a join code stays redeemable.
const JoinCodeTTL = 10 * time.Minute

// DefaultJoinScriptURL is where the one command fetches the join script: the
// fleet's `stable` tag, the same ref fleet-login-bootstrap.sh installs.
const DefaultJoinScriptURL = "https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-node-join.sh"

var (
	joinCodeRE  = regexp.MustCompile(`^fj_[a-z2-7]{26}$`)
	joinLabelRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)
	distNameRE  = regexp.MustCompile(`^(darwin|linux)-(amd64|arm64)$`)
)

// MintJoinCode generates a fresh code.
func MintJoinCode() (string, error) {
	b := make([]byte, 17) // 136 bits → 28 chars; keep 26 (130 bits)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate join code: %w", err)
	}
	s := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
	return "fj_" + s[:26], nil
}

// JoinCodeView is the body of POST /v1/fleet/join-codes: the code, shown once.
type JoinCodeView struct {
	Code      string    `json:"code"`
	Label     string    `json:"label,omitempty"`
	Kind      string    `json:"kind"`
	ExpiresAt time.Time `json:"expires_at"`
	Command   string    `json:"command"`
}

// handleFleetJoinCodes: GET lists recent codes (never the codes themselves),
// POST mints one. The operator's (adminOnly wraps it).
func (s *Server) handleFleetJoinCodes(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
		codes, err := s.Store.JoinCodes(20)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"codes": codes})
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		var req struct {
			Label string `json:"label"`
			// Kind is fixed (default) or ephemeral: a code for a node the
			// operator runs on a SPOT machine by hand (claude-fleet#1428).
			Kind string `json:"kind"`
		}
		if r.ContentLength != 0 {
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
				httpError(w, http.StatusBadRequest, "the body must be one JSON object")
				return
			}
		}
		if req.Label != "" && !joinLabelRE.MatchString(req.Label) {
			httpError(w, http.StatusBadRequest, "label: letters, digits, . _ - only, at most 63")
			return
		}
		switch req.Kind {
		case "":
			req.Kind = store.NodeKindFixed
		case store.NodeKindFixed, store.NodeKindEphemeral:
		default:
			httpError(w, http.StatusBadRequest, "kind: fixed or ephemeral")
			return
		}
		code, err := MintJoinCode()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		now := s.joinNow()
		if err := s.Store.CreateJoinCodeKind(HashToken(code), req.Label, req.Kind, now, JoinCodeTTL); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		// 加机器 is in the audit (claude-fleet#1990): who minted a code, and
		// below, which machine redeemed one. Never the code itself.
		if err := s.Store.FleetAudit(actorOf(r), "node_join_code", "join:"+req.Label, "MINTED "+req.Kind, "", now); err != nil {
			log.Printf("join code audit: %v", err)
		}
		writeJSON(w, http.StatusOK, JoinCodeView{
			Code: code, Label: req.Label, Kind: req.Kind, ExpiresAt: now.Add(JoinCodeTTL).UTC(),
			Command: s.joinCommand(r, code),
		})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// joinCommand is the one line the operator pastes on the new machine.
func (s *Server) joinCommand(r *http.Request, code string) string {
	script := s.FleetJoinScriptURL
	if script == "" {
		script = DefaultJoinScriptURL
	}
	return fmt.Sprintf("curl -fsSL %s | bash -s -- --hub %s --token %s", script, s.hubURL(r), code)
}

func (s *Server) joinNow() time.Time {
	if s.joinClock != nil {
		return s.joinClock()
	}
	return time.Now()
}

// NodeJoinResponse is the body of a successful POST /v1/node/join.
type NodeJoinResponse struct {
	EndpointID string `json:"endpoint_id"`
	Label      string `json:"label"`
	// Token is the machine's own enrollment token, shown this once.
	Token string `json:"token"`
	Hub   string `json:"hub"`
	// Admin says whether the hub will treat this login's agent as the
	// machine's admin agent (CCQUOTA_FLEET_ADMIN_USERS) — account ops and
	// the SSH user CA (claude-fleet#1411/#1412).
	Admin bool `json:"admin"`
	// SSHCA is the user CA public key the admin agent will install, empty
	// when the hub signs no certificates.
	SSHCA string `json:"ssh_ca,omitempty"`
	// Dist lists the agent binaries this hub serves at /v1/node/dist/<name>.
	Dist []string `json:"dist"`
	// Kind is what the code was minted for (claude-fleet#1428): fixed, or
	// ephemeral — the join script then runs the agent as a SPOT node, which
	// on SIGTERM tells the hub and moves its idle sessions off.
	Kind string `json:"kind"`
}

// handleNodeJoin trades a join code for an enrollment token. No credential
// but the code: this is what a machine runs before it has one.
func (s *Server) handleNodeJoin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var req struct {
		Code     string `json:"code"`
		Hostname string `json:"hostname"`
		OSUser   string `json:"os_user"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	if !joinCodeRE.MatchString(req.Code) {
		httpError(w, http.StatusUnauthorized, store.ErrJoinCode.Error())
		return
	}
	out, err := s.redeemJoin(r, req.Code, req.Hostname, req.OSUser)
	if err != nil {
		if errors.Is(err, store.ErrJoinCode) {
			httpError(w, http.StatusUnauthorized, err.Error())
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// redeemJoin spends a join code for a machine and enrolls its agent endpoint:
// the one place a node token is minted, for the code a person pasted
// (handleNodeJoin) and for the code the hub mints itself when a scan adds a
// node (enrollNode, `fleet node join`, claude-fleet#1627).
func (s *Server) redeemJoin(r *http.Request, code, hostname, osUser string) (*NodeJoinResponse, error) {
	host := sanitizeJoinField(hostname)
	osUser = sanitizeJoinField(osUser)
	label := host
	if osUser != "" && host != "" {
		label = host + "-" + osUser
	}
	if label == "" {
		label = "joined"
	}
	tok, err := MintToken()
	if err != nil {
		return nil, err
	}
	now := s.joinNow()
	id := fmt.Sprintf("ep_%d", now.UnixNano())
	if err := s.Store.RedeemJoinCode(HashToken(code), now, id, label, HashToken(tok), host, osUser); err != nil {
		return nil, err
	}
	if ep, err := s.Store.EndpointByTokenHash(HashToken(tok)); err == nil {
		label = ep.Label
	}
	if err := s.Store.FleetAudit("node:"+host+"/"+osUser, "node_join", "endpoint:"+id, "JOINED "+label, "", now); err != nil {
		log.Printf("join audit: %v", err)
	}
	out := &NodeJoinResponse{
		EndpointID: id, Label: label, Token: tok, Hub: s.hubURL(r),
		Admin: s.isFleetAdmin(osUser), Dist: s.distNames(), Kind: store.NodeKindFixed,
	}
	if k, err := s.Store.EndpointNodeKind(id); err == nil && k != "" {
		out.Kind = k
	}
	if s.SSHCA != nil {
		out.SSHCA = s.SSHCA.PublicKey()
	}
	return out, nil
}

// enrollNode is the scan's half of adding a machine (claude-fleet#1627): the
// person confirmed `fleet node join` on the same page as `fleet login`, so the
// hub mints a fixed-kind code for that confirmation and spends it at once.
// The code row stays as the audit trail — who added which machine, when.
func (s *Server) enrollNode(r *http.Request, hostname, osUser string) (*NodeJoinResponse, error) {
	code, err := MintJoinCode()
	if err != nil {
		return nil, err
	}
	if err := s.Store.CreateJoinCodeKind(HashToken(code), "", store.NodeKindFixed, s.joinNow(), JoinCodeTTL); err != nil {
		return nil, err
	}
	return s.redeemJoin(r, code, hostname, osUser)
}

// sanitizeJoinField keeps a reported hostname / login to a label-safe form.
// Informational only — it names the endpoint; the agent reports its real
// identity on the control channel.
func sanitizeJoinField(v string) string {
	v = strings.TrimSpace(v)
	if i := strings.IndexByte(v, '.'); i > 0 {
		v = v[:i] // m4.local → m4
	}
	var b strings.Builder
	for _, c := range v {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' {
			b.WriteRune(c)
		}
		if b.Len() >= 32 {
			break
		}
	}
	return b.String()
}

// distNames lists the binaries in FleetDistDir, by their <os>-<arch> name.
func (s *Server) distNames() []string {
	out := []string{}
	if s.FleetDistDir == "" {
		return out
	}
	for _, os_ := range []string{"darwin", "linux"} {
		for _, arch := range []string{"amd64", "arm64"} {
			if st, err := os.Stat(filepath.Join(s.FleetDistDir, "ccquota-"+os_+"-"+arch)); err == nil && st.Mode().IsRegular() {
				out = append(out, os_+"-"+arch)
			}
		}
	}
	return out
}

// handleNodeDist serves the agent binary for one platform, with its SHA-256
// in X-Ccquota-Sha256 so the joining side can refuse a truncated download.
func (s *Server) handleNodeDist(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if _, ok := s.nodeEndpoint(w, r); !ok {
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/v1/node/dist/")
	if !distNameRE.MatchString(name) || s.FleetDistDir == "" {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(filepath.Join(s.FleetDistDir, "ccquota-"+name))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Ccquota-Sha256", hex.EncodeToString(h.Sum(nil)))
	http.ServeContent(w, r, "ccquota", st.ModTime(), f)
}

// handleNodeSelf answers "does the hub see me": this endpoint's roster row,
// or status "never" before its agent has connected once.
func (s *Server) handleNodeSelf(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	snap, err := s.Nodes(time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, n := range snap.Nodes {
		if n.EndpointID == ep.ID {
			writeJSON(w, http.StatusOK, n)
			return
		}
	}
	// Never connected: the enrollment's machine name is all there is, and
	// trust (claude-fleet#1968) is read off it like the roster does.
	settings, _ := s.trustSettings(time.Now())
	writeJSON(w, http.StatusOK, map[string]string{"endpoint_id": ep.ID, "status": "never", "trust": trustOf(ep.Hostname, settings)})
}
