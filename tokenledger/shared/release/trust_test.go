package release

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func tkey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func tcert(t *testing.T, by ed25519.PrivateKey, key ed25519.PublicKey, role string) Doc {
	t.Helper()
	d, err := SignDoc(by, KeyCert{Schema: 1, Kind: KindKey, Key: FormatPublicKey(key), Role: role, By: KeyID(by.Public().(ed25519.PublicKey))})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func signedManifest(t *testing.T, key ed25519.PrivateKey, chain []Doc, rev *Doc) ([]byte, string) {
	t.Helper()
	m := Manifest{Schema: Schema, SHA: strings.Repeat("a", 40), Key: KeyID(key.Public().(ed25519.PublicKey)), KeyChain: chain, Revoked: rev}
	b, _ := json.Marshal(m)
	return b, Sign(key, b)
}

func TestTrustChain(t *testing.T) {
	oldPub, old := tkey(t)
	rootPub, root := tkey(t)
	k1Pub, k1 := tkey(t)
	_, stranger := tkey(t)
	chain := []Doc{tcert(t, root, k1Pub, RoleSign), tcert(t, old, rootPub, RoleRoot)}

	// a machine still pinned to the hub's old key follows old → root → k1, and re-pins
	mb, sig := signedManifest(t, k1, chain, nil)
	_, tr, err := VerifyTrusted(oldPub, mb, sig, nil, nil)
	if err != nil || !tr.Repin.Equal(rootPub) {
		t.Fatalf("old pin: %v repin %v", err, tr)
	}
	// pinned to the root: k1 is vouched for, nothing to re-pin
	if _, tr, err := VerifyTrusted(rootPub, mb, sig, nil, nil); err != nil || tr.Repin != nil {
		t.Fatalf("root pin: %v %v", err, tr)
	}
	// a sign key cannot make a root, nor vouch for anyone it was not given
	sneaky := tcert(t, k1, ed25519.PublicKey(stranger.Public().(ed25519.PublicKey)), RoleRoot)
	tr = NewTrust(rootPub, append(chain, sneaky), nil, nil)
	if tr.Repin != nil || tr.keys[KeyID(stranger.Public().(ed25519.PublicKey))].role == RoleRoot {
		t.Fatalf("a sign key minted a root: %v", tr.IDs())
	}
	// a key the pin never vouched for: the old message
	mb2, sig2 := signedManifest(t, stranger, chain, nil)
	if _, _, err := VerifyTrusted(rootPub, mb2, sig2, nil, nil); err == nil || !strings.Contains(err.Error(), "does not match the pinned key") {
		t.Fatalf("a stranger's manifest: %v", err)
	}
	// a cert someone else signed in the root's name counts for nothing
	forged := tcert(t, stranger, k1Pub, RoleSign)
	var c KeyCert
	b, _ := forged.bytes()
	_ = json.Unmarshal(b, &c)
	c.By = KeyID(rootPub)
	forged, _ = SignDoc(stranger, c)
	if NewTrust(rootPub, []Doc{forged}, nil, nil).Has(KeyID(k1Pub)) {
		t.Fatal("a forged cert was taken")
	}
	// the legacy shape: no chain, signed by the pin itself
	mb3, sig3 := signedManifest(t, old, nil, nil)
	if _, _, err := VerifyTrusted(oldPub, mb3, sig3, nil, nil); err != nil {
		t.Fatalf("a manifest signed by the pin: %v", err)
	}
}

func TestTrustRevoked(t *testing.T) {
	rootPub, root := tkey(t)
	k1Pub, k1 := tkey(t)
	_, mallory := tkey(t)
	chain := []Doc{tcert(t, root, k1Pub, RoleSign)}
	rev, _ := SignDoc(root, Revocation{Schema: 1, Kind: KindRevoked, Version: 1, Keys: []string{KeyID(k1Pub)}, By: KeyID(rootPub)})
	forged, _ := SignDoc(mallory, Revocation{Schema: 1, Kind: KindRevoked, Version: 9, Keys: []string{KeyID(k1Pub)}, By: KeyID(rootPub)})

	mb, sig := signedManifest(t, k1, chain, nil)
	if _, _, err := VerifyTrusted(rootPub, mb, sig, []Doc{forged}, nil); err != nil {
		t.Fatalf("a forged list revoked k1: %v", err)
	}
	if _, _, err := VerifyTrusted(rootPub, mb, sig, []Doc{rev}, nil); !IsRevoked(err) {
		t.Fatalf("the hub's list: %v", err)
	}
	mbr, sigr := signedManifest(t, k1, chain, &rev)
	if _, _, err := VerifyTrusted(rootPub, mbr, sigr, nil, nil); !IsRevoked(err) {
		t.Fatalf("the manifest's own list: %v", err)
	}
	if _, _, err := VerifyTrusted(rootPub, mb, sig, nil, map[string]bool{KeyID(k1Pub): true}); !IsRevoked(err) {
		t.Fatalf("the machine's memory: %v", err)
	}
	// the pin itself is never revoked (a leaked root is a person's re-pin)
	self, _ := SignDoc(root, Revocation{Schema: 1, Kind: KindRevoked, Version: 2, Keys: []string{KeyID(rootPub)}, By: KeyID(rootPub)})
	mbs, sigs := signedManifest(t, root, nil, nil)
	if _, _, err := VerifyTrusted(rootPub, mbs, sigs, []Doc{self}, nil); err != nil {
		t.Fatalf("the pin revoked itself: %v", err)
	}

	// Keep: the ids only ever grow, the pin moves to a vouched root
	dir := t.TempDir()
	pin := filepath.Join(dir, "release.pub")
	must(t, os.WriteFile(pin, []byte(FormatPublicKey(rootPub)+"\n"), 0o644))
	tr := NewTrust(rootPub, chain, []Doc{rev}, nil)
	if _, err := tr.Keep(pin); err != nil {
		t.Fatal(err)
	}
	if _, err := NewTrust(rootPub, chain, nil, nil).Keep(pin); err != nil {
		t.Fatal(err)
	}
	if got, ver := LoadRevoked(pin); !got[KeyID(k1Pub)] || ver != 1 {
		t.Fatalf("revoked file: %v v%d", got, ver)
	}
}

func TestSSHSigVerify(t *testing.T) {
	pub, key := tkey(t)
	other, _ := tkey(t)
	msg := []byte("manifest bytes\n")
	blob := SSHSign(key, SSHSigNS, msg)
	if !SSHSigVerify(pub, SSHSigNS, msg, blob) {
		t.Fatal("its own SSHSIG")
	}
	if SSHSigVerify(other, SSHSigNS, msg, blob) || SSHSigVerify(pub, SSHSigKeyNS, msg, blob) ||
		SSHSigVerify(pub, SSHSigNS, append(msg, 'x'), blob) || SSHSigVerify(pub, SSHSigNS, msg, blob[:len(blob)-1]) {
		t.Fatal("a wrong key / namespace / message / blob verified")
	}
}

// TestTrustPythonInterop: bin/fleet-release-verify.py (what clients and the
// root's offline computer run) and this package read one format.
func TestTrustPythonInterop(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	_, file, _, _ := runtime.Caller(0)
	script := filepath.Join(filepath.Dir(file), "..", "..", "..", "bin", "fleet-release-verify.py")
	if _, err := os.Stat(script); err != nil {
		t.Skip("no bin/fleet-release-verify.py beside this tree")
	}
	// Python signs the chain and a revocation; Go must agree with Python's verdict
	prog := `
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("v", sys.argv[1]); v = importlib.util.module_from_spec(s); s.loader.exec_module(v)
root, k1, k2 = bytes([1]*32), bytes([2]*32), bytes([3]*32)
R, K1, K2 = v.pub_of(root), v.pub_of(k1), v.pub_of(k2)
chain = [v.make_doc(root, {"schema":1,"kind":"release-key","key":v.key_line(K1),"role":"sign","by":v.key_id(R)}),
         v.make_doc(root, {"schema":1,"kind":"release-key","key":v.key_line(K2),"role":"sign","by":v.key_id(R)})]
rev = v.make_doc(root, {"schema":1,"kind":"release-revoked","version":3,"keys":[v.key_id(K1)],"by":v.key_id(R)})
print(json.dumps({"root": v.key_line(R), "k1": v.key_id(K1), "k2": v.key_id(K2), "chain": chain, "rev": rev}))
`
	out, err := exec.Command(py, "-c", prog, script).Output()
	if err != nil {
		t.Fatalf("python: %v", err)
	}
	var got struct {
		Root   string `json:"root"`
		K1, K2 string
		Chain  []Doc `json:"chain"`
		Rev    Doc   `json:"rev"`
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	root, err := ParsePublicKey([]byte(got.Root))
	if err != nil {
		t.Fatal(err)
	}
	tr := NewTrust(root, got.Chain, []Doc{got.Rev}, nil)
	if !tr.Has(got.K2) || tr.Has(got.K1) || !tr.Revoked[got.K1] || tr.RevVersion != 3 {
		t.Fatalf("Go reads Python's documents differently: %v revoked %v v%d", tr.IDs(), tr.Revoked, tr.RevVersion)
	}
	// and Python reads Go's
	_, k3 := tkey(t)
	k3Pub := k3.Public().(ed25519.PublicKey)
	seed := []byte{1}
	for len(seed) < 32 {
		seed = append(seed, 1)
	}
	rootKey := ed25519.NewKeyFromSeed(seed)
	d := tcert(t, rootKey, k3Pub, RoleSign)
	db, _ := json.Marshal(d)
	chk := `
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("v", sys.argv[1]); v = importlib.util.module_from_spec(s); s.loader.exec_module(v)
t = v.trust(v.pub_of(bytes([1]*32)), [json.loads(sys.argv[2])], [])
print("yes" if sys.argv[3] in t[0] else "no")
`
	out, err = exec.Command(py, "-c", chk, script, string(db), KeyID(k3Pub)).Output()
	if err != nil || strings.TrimSpace(string(out)) != "yes" {
		t.Fatalf("Python does not take Go's cert: %q %v", out, err)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
