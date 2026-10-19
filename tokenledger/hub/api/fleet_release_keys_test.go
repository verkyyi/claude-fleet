package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// keysAs asks GET /v1/fleet/release/keys as role.
func keysAs(t *testing.T, s *Server, role string) (*httptest.ResponseRecorder, releaseKeysView) {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, ReleaseKeysPath, nil)
	s.handleReleaseKeys(rec, req.WithContext(withRole(req.Context(), role)))
	var v releaseKeysView
	if rec.Code == 200 {
		if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
			t.Fatalf("%v: %s", err, rec.Body)
		}
	}
	return rec, v
}

// claude-fleet#3937: the 发布 page's key card — who signs, the root, the key
// behind stable and the revocations, and nothing a private key could leak.
func TestReleaseKeysView(t *testing.T) {
	p := newPublishRig(t)
	tok := p.oidc.token(nil)
	rootPub, root := newKey(t)
	k1Pub, k1 := newKey(t)
	p.rs.Root, p.rs.Key = rootPub, nil
	chain := []release.Doc{keyCert(t, root, k1Pub, release.RoleSign)}
	a := p.repo.commit("A", map[string]string{ReleaseKeysChain: jsonOf(t, chain)})
	if code, body := p.publishParts(tok, a, "", nil, nil, map[string]string{"signer": release.FormatPublicKey(k1Pub)}); code != http.StatusAccepted {
		t.Fatalf("stage A: %d %s", code, body)
	} else if code, body := p.sign(tok, a, k1, staged(t, body)); code != 200 {
		t.Fatalf("sign A: %d %s", code, body)
	}

	rec, v := keysAs(t, p.h.srv, roleAdmin)
	if rec.Code != 200 {
		t.Fatalf("admin GET keys = %d %s", rec.Code, rec.Body)
	}
	k1id := release.KeyID(k1Pub)
	if v.Signer != "train" || !v.Root || v.Anchor != release.KeyID(rootPub) || v.Stable != a ||
		v.StableKey != k1id || !v.StableKeyTrusted || v.StableKeyRevoked || v.Revoked != 0 || len(v.Trusted) != 2 {
		t.Fatalf("keys = %+v; want train-signed, root pinned, stable %s by trusted %s, none revoked", v, a[:7], k1id)
	}

	// the root revokes k1: the card says so
	rev := filepath.Join(t.TempDir(), "revoked.json")
	must(t, os.WriteFile(rev, []byte(jsonOf(t, revocation(t, root, 3, k1id))), 0o644))
	p.rs.RevokedFile = rev
	if _, v = keysAs(t, p.h.srv, roleAdmin); v.Revoked != 1 || v.RevokedVersion != 3 || !v.StableKeyRevoked || v.StableKeyTrusted {
		t.Fatalf("after the revocation keys = %+v; want 1 revoked (v3), stable's key revoked", v)
	}

	// a hub that holds its own key: still no byte of it in the answer
	_, priv := newKey(t)
	p.rs.Key = priv
	rec, v = keysAs(t, p.h.srv, roleAdmin)
	if v.Signer != "hub" {
		t.Fatalf("hub-held key: signer = %q", v.Signer)
	}
	body := rec.Body.Bytes()
	for _, secret := range [][]byte{priv, priv.Seed(), root, k1} {
		for _, enc := range []string{base64.StdEncoding.EncodeToString(secret), base64.RawStdEncoding.EncodeToString(secret), string(secret)} {
			if bytes.Contains(body, []byte(enc)) {
				t.Fatalf("the keys read carries private key material: %s", body)
			}
		}
	}
	for _, word := range []string{"private", "seed", "PRIVATE"} {
		if strings.Contains(string(body), word) {
			t.Fatalf("the keys read names %q: %s", word, body)
		}
	}
}

// A member gets exactly the answer an unknown release path gets, and the
// refusal is audited.
func TestReleaseKeysIs404ForMember(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.Releases = &ReleaseStore{Dir: t.TempDir()}
	code, body := rolesGet(t, h, user, ReleaseKeysPath)
	ucode, ubody := rolesGet(t, h, user, release.Path+"no-such-thing")
	if code != http.StatusNotFound || code != ucode || !bytes.Equal(body, ubody) {
		t.Fatalf("member GET keys = %d %q; unknown release path = %d %q; want the same 404", code, body, ucode, ubody)
	}
	if code, body := rolesGet(t, h, admin, ReleaseKeysPath); code != 200 || !strings.Contains(string(body), `"signer"`) {
		t.Fatalf("admin GET keys = %d %s", code, body)
	}
	var refused int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'role_denied'
		AND fleet_id = ?`, "route:GET "+ReleaseKeysPath).Scan(&refused); err != nil {
		t.Fatal(err)
	}
	if refused != 1 {
		t.Fatalf("%d role refusals audited for the keys read; want 1", refused)
	}
}
