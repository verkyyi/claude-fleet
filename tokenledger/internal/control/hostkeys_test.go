package control

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestHostKey(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	sp, _ := ssh.NewPublicKey(pub)
	want := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	for _, in := range []string{want, want + " root@mini\n", "  " + want + "  "} {
		if got, ok := HostKey(in); !ok || got != want {
			t.Fatalf("HostKey(%q) = %q, %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "nope", want + "\nmini2 " + want, "ssh-dss AAAAB3NzaC1kc3MAAACBAP", "@cert-authority * " + want} {
		if got, ok := HostKey(in); ok {
			t.Fatalf("HostKey(%q) accepted: %q", in, got)
		}
	}
	if got := HostKeys([]string{want, "x", want + " c"}); len(got) != 1 || got[0] != want {
		t.Fatalf("HostKeys = %q", got)
	}
	if HostKeys(nil) != nil {
		t.Fatal("HostKeys(nil) not nil")
	}
}
