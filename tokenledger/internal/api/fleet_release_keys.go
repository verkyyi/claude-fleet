package api

import (
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// GET /v1/fleet/release/keys (claude-fleet#3937, EPIC #3923 C14) — the
// release signing keys' state, for the admin side's 发布 page: who signs (the
// hub or the train), whether an offline root is pinned, the key that signed
// stable and whether the anchor still vouches for it, every key the chain
// vouches for and how many the root revoked. Ids and roles only — never a
// private key, a seed or a signature; the public halves are /key's already.
//
// An admin's. Anyone else gets the 404 an unknown address under
// /v1/fleet/release/ gets (http.NotFound), audited role_denied like every
// refusal — a member cannot tell this read exists.

// ReleaseKeysPath is the read's route.
const ReleaseKeysPath = release.Path + "keys"

type releaseKeyRow struct {
	ID   string `json:"id"`
	Role string `json:"role"`
	By   string `json:"by,omitempty"`
}

type releaseKeysView struct {
	Repo   string `json:"repo,omitempty"`
	Signer string `json:"signer"`           // hub | train
	Anchor string `json:"anchor,omitempty"` // the pinned key's id (the root, else the hub's)
	Root   bool   `json:"root"`             // an offline root is pinned
	// Stable and the key that signed its manifest; trusted = the anchor
	// vouches for it through the chain, revoked = a root's list names it.
	Stable           string          `json:"stable,omitempty"`
	StableKey        string          `json:"stable_key,omitempty"`
	StableKeyTrusted bool            `json:"stable_key_trusted"`
	StableKeyRevoked bool            `json:"stable_key_revoked"`
	Trusted          []releaseKeyRow `json:"trusted"`
	Revoked          int             `json:"revoked"`
	RevokedVersion   int64           `json:"revoked_version"`
	// Overlap: the hub still holds the key its own replaced (key-endorsement).
	Overlap bool `json:"overlap"`
}

func (rs *ReleaseStore) keysView() releaseKeysView {
	v := releaseKeysView{Repo: rs.Repo, Signer: "hub", Root: rs.Root != nil, Overlap: rs.PrevKey != nil && rs.Key != nil, Trusted: []releaseKeyRow{}}
	if rs.TrainSigned() {
		v.Signer = "train"
	}
	a := rs.anchor()
	if a == nil {
		return v
	}
	v.Anchor = release.KeyID(a)
	var chain []release.Doc
	if p := rs.stable(); p.SHA != "" {
		v.Stable = p.SHA
		if m := rs.manifest(p.SHA); m != nil {
			chain, v.StableKey = m.KeyChain, m.Key
		}
	}
	t := release.NewTrust(a, chain, rs.revocations(), nil)
	for _, line := range t.IDs() {
		f := strings.Fields(line)
		row := releaseKeyRow{ID: f[0]}
		if len(f) > 1 {
			row.Role = f[1]
		}
		if len(f) > 2 {
			row.By = f[2]
		}
		v.Trusted = append(v.Trusted, row)
	}
	v.Revoked, v.RevokedVersion = len(t.Revoked), t.RevVersion
	if v.StableKey != "" {
		v.StableKeyTrusted, v.StableKeyRevoked = t.Has(v.StableKey), t.Revoked[v.StableKey]
	}
	return v
}

// handleReleaseKeys serves GET /v1/fleet/release/keys.
func (s *Server) handleReleaseKeys(w http.ResponseWriter, r *http.Request) {
	// adminOnly's gate, answered as a missing page instead of 403
	if roleOf(r.Context()) == roleUser {
		s.auditRoleDenied(r)
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	if s.Releases == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.Releases.keysView())
}
