package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// claude-fleet#3559: the signing key lives in the release train; the hub keeps
// only the root's public half and what the train signed.

func newKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func keyCert(t *testing.T, by ed25519.PrivateKey, key ed25519.PublicKey, role string) release.Doc {
	t.Helper()
	d, err := release.SignDoc(by, release.KeyCert{Schema: 1, Kind: release.KindKey, Key: release.FormatPublicKey(key),
		Role: role, By: release.KeyID(by.Public().(ed25519.PublicKey))})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func revocation(t *testing.T, root ed25519.PrivateKey, ver int64, ids ...string) release.Doc {
	t.Helper()
	d, err := release.SignDoc(root, release.Revocation{Schema: 1, Kind: release.KindRevoked, Version: ver, Keys: ids,
		By: release.KeyID(root.Public().(ed25519.PublicKey))})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func jsonOf(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// sign is the train's second half: the two signatures over the staged bytes.
func (p *publishRig) sign(tok, sha string, key ed25519.PrivateKey, mb []byte) (int, string) {
	p.t().Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("sha", sha)
	_ = mw.WriteField("sig", release.Sign(key, mb))
	_ = mw.WriteField("sshsig", base64.StdEncoding.EncodeToString(release.SSHSign(key, release.SSHSigNS, mb)))
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, p.h.http.URL+release.Path+"publish", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		p.t().Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	_, _ = b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

// staged decodes a 202's manifest bytes.
func staged(t *testing.T, body string) []byte {
	t.Helper()
	var out struct {
		Status   string `json:"status"`
		Manifest string `json:"manifest"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil || out.Status != "unsigned" {
		t.Fatalf("not a staged answer: %s", body)
	}
	mb, err := base64.StdEncoding.DecodeString(out.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	return mb
}

func TestReleaseTrainSigned(t *testing.T) {
	p := newPublishRig(t)
	tok := p.oidc.token(nil)
	rootPub, root := newKey(t)
	trainPub, train := newKey(t)
	strangerPub, _ := newKey(t)
	chain := []release.Doc{keyCert(t, p.key, rootPub, release.RoleRoot), keyCert(t, root, trainPub, release.RoleSign)}

	// step A: the hub still signs, but hands out the root and the commit's chain
	p.rs.Root = rootPub
	a := p.repo.commit("A", map[string]string{ReleaseKeysChain: jsonOf(t, chain)})
	if code, body := p.publish(tok, a, "", nil, nil); code != 200 {
		t.Fatalf("publish A (hub-signed): %d %s", code, body)
	}
	resp, body := getBody(t, p.h.http.URL+release.KeyPath)
	if strings.TrimSpace(body) != release.FormatPublicKey(rootPub) || resp.Header.Get(ReleaseSignerHeader) != "hub" {
		t.Fatalf("/key = %q (%s), want the root, signer hub", body, resp.Header.Get(ReleaseSignerHeader))
	}
	pin := filepath.Join(t.TempDir(), "release.pub")
	must(t, os.WriteFile(pin, []byte(release.FormatPublicKey(p.pub)+"\n"), 0o644))
	f := &release.Fetcher{Hub: p.h.http.URL, Key: p.pub}
	if _, err := f.Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "a"), false); err != nil {
		t.Fatalf("a machine pinned to the hub's old key: %v", err)
	}
	if said, err := f.Trust.Keep(pin); err != nil || !strings.Contains(said, "re-pinned to the root") {
		t.Fatalf("Keep: %q %v", said, err)
	}
	if b, _ := os.ReadFile(pin); strings.TrimSpace(string(b)) != release.FormatPublicKey(rootPub) {
		t.Fatalf("the pin is %q, want the root", b)
	}

	// the hub gives its key up: the train signs from now on
	p.rs.Key = nil
	b := p.repo.commit("B", nil)
	if code, body := p.publish(tok, b, a, nil, nil); code != http.StatusPreconditionRequired {
		t.Fatalf("a publish with no signer to a keyless hub: %d %s", code, body)
	}
	if code, body := p.publishParts(tok, b, a, nil, nil, map[string]string{"signer": release.FormatPublicKey(strangerPub)}); code != http.StatusForbidden {
		t.Fatalf("a signer the root never vouched for: %d %s", code, body)
	}
	code, body := p.publishParts(tok, b, a, nil, nil, map[string]string{"signer": release.FormatPublicKey(trainPub)})
	if code != http.StatusAccepted {
		t.Fatalf("stage B: %d %s", code, body)
	}
	mb := staged(t, body)
	if resp, _ := getBody(t, p.h.http.URL+release.Path+"stable"); p.rs.stable().SHA != a || resp.StatusCode != 200 {
		t.Fatal("an unsigned build moved stable")
	}
	_, stranger := newKey(t)
	if code, body := p.sign(tok, b, stranger, mb); code != http.StatusForbidden {
		t.Fatalf("a signature by another key: %d %s", code, body)
	}
	if code, body := p.sign(tok, b, train, mb); code != 200 || !strings.Contains(body, `"published"`) {
		t.Fatalf("sign B: %d %s", code, body)
	}
	if p.rs.stable().SHA != b {
		t.Fatalf("stable %s, want B", p.rs.stable().SHA)
	}
	if resp, _ := getBody(t, p.h.http.URL+release.KeyPath); resp.Header.Get(ReleaseSignerHeader) != "train" {
		t.Fatal("/key does not say the train signs")
	}
	// both pins take it: the root, and a machine still on the hub's old key
	for name, anchor := range map[string]ed25519.PublicKey{"root": rootPub, "old key": p.pub} {
		got, err := (&release.Fetcher{Hub: p.h.http.URL, Key: anchor}).Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "b"), true)
		if err != nil || got.SHA != b || got.Key != release.KeyID(trainPub) {
			t.Fatalf("a machine pinned to the %s: %v %v", name, got, err)
		}
	}
	// the SSHSIG the train made is what is served
	resp, sshsig := getBody(t, p.h.http.URL+release.Path+b+"/"+release.SSHSigName)
	if resp.StatusCode != 200 || !strings.Contains(sshsig, "BEGIN SSH SIGNATURE") {
		t.Fatalf("manifest.sshsig: %d %q", resp.StatusCode, sshsig)
	}
	// nothing on the hub's volume is a private key
	_ = filepath.Walk(p.dir, func(path string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			bs, _ := os.ReadFile(path)
			if bytes.Contains(bs, train.Seed()) || bytes.Contains(bs, []byte(base64.StdEncoding.EncodeToString(train.Seed()))) {
				t.Fatalf("%s holds the train's key", path)
			}
		}
		return nil
	})
}

func TestReleaseKeyRevoked(t *testing.T) {
	p := newPublishRig(t)
	tok := p.oidc.token(nil)
	rootPub, root := newKey(t)
	k1Pub, k1 := newKey(t)
	k2Pub, k2 := newKey(t)
	p.rs.Root, p.rs.Key = rootPub, nil
	chain := []release.Doc{keyCert(t, root, k1Pub, release.RoleSign), keyCert(t, root, k2Pub, release.RoleSign)}
	a := p.repo.commit("A", map[string]string{ReleaseKeysChain: jsonOf(t, chain)})
	code, body := p.publishParts(tok, a, "", nil, nil, map[string]string{"signer": release.FormatPublicKey(k1Pub)})
	if code != http.StatusAccepted {
		t.Fatalf("stage A: %d %s", code, body)
	}
	if code, body := p.sign(tok, a, k1, staged(t, body)); code != 200 {
		t.Fatalf("sign A: %d %s", code, body)
	}
	f := &release.Fetcher{Hub: p.h.http.URL, Key: rootPub}
	if _, err := f.Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "a"), false); err != nil {
		t.Fatalf("A signed by k1: %v", err)
	}

	// k1 leaks: the root's list, handed to the hub — every fetch refuses A at once
	rev := filepath.Join(t.TempDir(), "revoked.json")
	must(t, os.WriteFile(rev, []byte(jsonOf(t, revocation(t, root, 1, release.KeyID(k1Pub)))), 0o644))
	p.rs.RevokedFile = rev
	if resp, body := getBody(t, p.h.http.URL+release.Path+release.RevokedRel); resp.StatusCode != 200 || !strings.Contains(body, "payload") {
		t.Fatalf("/revoked: %d %s", resp.StatusCode, body)
	}
	pin := filepath.Join(t.TempDir(), "release.pub")
	must(t, os.WriteFile(pin, []byte(release.FormatPublicKey(rootPub)+"\n"), 0o644))
	f = &release.Fetcher{Hub: p.h.http.URL, Key: rootPub}
	if _, err := f.Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "a2"), false); !release.IsRevoked(err) {
		t.Fatalf("A signed by the revoked k1 was taken: %v", err)
	}
	// a list forged by anyone but the root counts for nothing
	_, mallory := newKey(t)
	must(t, os.WriteFile(rev, []byte(jsonOf(t, revocation(t, mallory, 9, release.KeyID(k2Pub)))), 0o644))
	if d := p.rs.revokedDoc(); d != nil {
		t.Fatalf("/revoked serves a list the root did not sign: %+v", d)
	}
	must(t, os.WriteFile(rev, []byte(jsonOf(t, revocation(t, root, 1, release.KeyID(k1Pub)))), 0o644))

	// the hub will not stage for the revoked key; the next release ships the list
	b := p.repo.commit("B", map[string]string{ReleaseKeysRevoked: jsonOf(t, revocation(t, root, 1, release.KeyID(k1Pub)))})
	if code, body := p.publishParts(tok, b, a, nil, nil, map[string]string{"signer": release.FormatPublicKey(k1Pub)}); code != http.StatusForbidden {
		t.Fatalf("stage for a revoked key: %d %s", code, body)
	}
	code, body = p.publishParts(tok, b, a, nil, nil, map[string]string{"signer": release.FormatPublicKey(k2Pub)})
	if code != http.StatusAccepted {
		t.Fatalf("stage B for k2: %d %s", code, body)
	}
	if code, body := p.sign(tok, b, k2, staged(t, body)); code != 200 {
		t.Fatalf("sign B: %d %s", code, body)
	}
	f = &release.Fetcher{Hub: p.h.http.URL, Key: rootPub}
	got, err := f.Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "b"), false)
	if err != nil || got.SHA != b || got.Revoked == nil {
		t.Fatalf("B by k2 with the list on board: %v %v", got, err)
	}
	if _, err := f.Trust.Keep(pin); err != nil {
		t.Fatal(err)
	}
	// the machine remembers: with the hub's list gone, k1 is still refused
	p.rs.RevokedFile = ""
	known, _ := release.LoadRevoked(pin)
	if !known[release.KeyID(k1Pub)] {
		t.Fatalf("the machine forgot k1 was revoked: %v", known)
	}
	mb, _ := os.ReadFile(filepath.Join(p.rs.dir(a), release.ManifestName))
	sig, _ := os.ReadFile(filepath.Join(p.rs.dir(a), release.SigName))
	if _, _, err := release.VerifyTrusted(rootPub, mb, string(sig), nil, known); !release.IsRevoked(err) {
		t.Fatalf("A by k1, from the machine's own memory: %v", err)
	}
}
