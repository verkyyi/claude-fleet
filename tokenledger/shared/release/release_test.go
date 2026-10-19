package release

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const sha = "0123456789abcdef0123456789abcdef01234567"

func build(t *testing.T, files map[string][]byte) (string, *Manifest, ed25519.PrivateKey) {
	t.Helper()
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	dir := filepath.Join(t.TempDir(), sha)
	m, err := Build(dir, "o/r", sha, files, nil, key, time.Unix(1e9, 0))
	if err != nil {
		t.Fatal(err)
	}
	return dir, m, key
}

func TestBuildSignUnpack(t *testing.T) {
	files := map[string][]byte{"bin/a": []byte("#!/bin/sh\n"), "conf/b": []byte("b"), "README.md": []byte("r")}
	dir, m, key := build(t, files)
	mb, _ := os.ReadFile(filepath.Join(dir, ManifestName))
	sig, _ := os.ReadFile(filepath.Join(dir, SigName))
	got, err := Verify(key.Public().(ed25519.PublicKey), mb, string(sig))
	if err != nil || got.SHA != sha || len(got.Files) != 3 {
		t.Fatalf("verify: %v %+v", err, got)
	}
	tree, _ := os.ReadFile(filepath.Join(dir, TreeName))
	out := filepath.Join(t.TempDir(), "out")
	if err := Unpack(m, tree, out); err != nil {
		t.Fatal(err)
	}
	for p, want := range files {
		if b, _ := os.ReadFile(filepath.Join(out, p)); string(b) != string(want) {
			t.Errorf("%s = %q", p, b)
		}
	}
	// deterministic: the same files make the same tree
	dir2, _, _ := build(t, files)
	tree2, _ := os.ReadFile(filepath.Join(dir2, TreeName))
	if string(tree) != string(tree2) {
		t.Error("the tree is not deterministic")
	}
}

// A manifest whose tree digest is right but a file's is not (a forged
// manifest the attacker could only produce with the key): Unpack still
// checks every file.
func TestUnpackChecksEveryFile(t *testing.T) {
	dir, m, _ := build(t, map[string][]byte{"bin/a": []byte("A"), "bin/b": []byte("B")})
	tree, _ := os.ReadFile(filepath.Join(dir, TreeName))
	for _, mut := range []func(*Manifest){
		func(m *Manifest) { m.Files[0].SHA256 = strings.Repeat("0", 64) },
		func(m *Manifest) { m.Files = m.Files[:1] },                                                // an extra file in the tar
		func(m *Manifest) { m.Files = append(m.Files, File{Path: "bin/c", SHA256: "x", Size: 1}) }, // a missing one
		func(m *Manifest) { m.Files[0].Path = "../evil" },
	} {
		mm := *m
		mm.Files = append([]File{}, m.Files...)
		mut(&mm)
		out := filepath.Join(t.TempDir(), "out")
		if err := Unpack(&mm, tree, out); err == nil {
			t.Errorf("mutated manifest %+v unpacked", mm.Files)
		}
		if _, err := os.Stat(out); err == nil {
			t.Error("a refused unpack left its directory")
		}
	}
}

func TestKeys(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(priv)
	for name, b := range map[string][]byte{
		"pem":  pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}),
		"seed": []byte(base64.StdEncoding.EncodeToString(priv.Seed()) + "\n"),
	} {
		k, err := LoadPrivateKey(b)
		if err != nil || !k.Equal(priv) {
			t.Errorf("%s: %v", name, err)
		}
	}
	got, err := ParsePublicKey([]byte(FormatPublicKey(pub) + "\n"))
	if err != nil || !got.Equal(pub) {
		t.Fatalf("public key round trip: %v", err)
	}
	if _, err := LoadPrivateKey([]byte("nope")); err == nil {
		t.Error("garbage accepted as a key")
	}
}

func TestVerifyRejects(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	mb, _ := json.Marshal(Manifest{Schema: Schema, SHA: sha})
	sig := Sign(key, mb)
	if _, err := Verify(pub, mb, sig); err != nil {
		t.Fatal(err)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := Verify(other, mb, sig); err == nil {
		t.Error("another key verified")
	}
	if _, err := Verify(pub, append(mb, ' '), sig); err == nil {
		t.Error("an edited manifest verified")
	}
	bad, _ := json.Marshal(Manifest{Schema: 99, SHA: sha})
	if _, err := Verify(pub, bad, Sign(key, bad)); err == nil {
		t.Error("an unknown schema verified")
	}
}
