package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

// fakeSSHD is a machine's sshd on disk in a temp dir: Install/Remove are file
// writes, Check fails when told to, Effective reports the drop-in only when
// the "sshd_config" Includes it.
type fakeSSHD struct {
	checkErr  error
	included  bool   // sshd_config Includes sshd_config.d
	otherCA   string // a TrustedUserCAKeys set earlier, if any
	calls     []string
	reloadErr error
}

func (f *fakeSSHD) Install(_ context.Context, dst string, b []byte) error {
	f.calls = append(f.calls, "install "+filepath.Base(dst))
	return os.WriteFile(dst, b, 0o644)
}

func (f *fakeSSHD) Remove(_ context.Context, dst string) error {
	f.calls = append(f.calls, "remove "+filepath.Base(dst))
	if err := os.Remove(dst); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (f *fakeSSHD) Check(context.Context) (string, error) {
	f.calls = append(f.calls, "sshd -t")
	if f.checkErr != nil {
		return "line 3: Bad configuration option", f.checkErr
	}
	return "", nil
}

func (f *fakeSSHD) Effective(context.Context) (string, error) {
	f.calls = append(f.calls, "sshd -T")
	ca := "none"
	if f.otherCA != "" {
		ca = f.otherCA
	} else if f.included {
		if _, err := os.Stat(sshCAPaths.conf); err == nil {
			ca = sshCAPaths.key
		}
	}
	return "port 22\ntrustedusercakeys " + ca + "\nauthorizedkeysfile .ssh/authorized_keys\n", nil
}

func (f *fakeSSHD) Reload(context.Context) error {
	f.calls = append(f.calls, "reload")
	return f.reloadErr
}

func withSSHCAPaths(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	old := sshCAPaths
	sshCAPaths.key = filepath.Join(dir, "fleet_user_ca.pub")
	sshCAPaths.conf = filepath.Join(dir, "100-fleet-user-ca.conf")
	t.Cleanup(func() { sshCAPaths = old })
	return dir
}

func caLine(t *testing.T) string {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pk, _ := ssh.NewPublicKey(pub)
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pk)))
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return "<absent>"
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// First install: key, then drop-in, then `sshd -t`, then the effective check;
// both files hold exactly what they should. Applying the same key again
// changes nothing and re-writes nothing.
func TestApplySSHCAInstallsThenIsIdempotent(t *testing.T) {
	withSSHCAPaths(t)
	h := &fakeSSHD{included: true}
	pub := caLine(t)
	res := applySSHCA(context.Background(), h, pub)
	if !res.OK || !res.Changed || res.RolledBack {
		t.Fatalf("first apply: %+v", res)
	}
	want := []string{"install fleet_user_ca.pub", "install 100-fleet-user-ca.conf", "sshd -t", "sshd -T", "reload"}
	if strings.Join(h.calls, "|") != strings.Join(want, "|") {
		t.Fatalf("order %v, want %v", h.calls, want)
	}
	if got := read(t, sshCAPaths.key); got != pub+"\n" {
		t.Fatalf("key file %q", got)
	}
	conf := read(t, sshCAPaths.conf)
	if !strings.Contains(conf, "\nTrustedUserCAKeys "+sshCAPaths.key+"\n") {
		t.Fatalf("drop-in %q", conf)
	}
	for _, l := range strings.Split(conf, "\n") {
		if l != "" && !strings.HasPrefix(l, "#") && !strings.HasPrefix(l, "TrustedUserCAKeys ") {
			t.Fatalf("drop-in sets more than TrustedUserCAKeys: %q", l)
		}
	}

	h.calls = nil
	res = applySSHCA(context.Background(), h, pub)
	if !res.OK || res.Changed {
		t.Fatalf("second apply: %+v", res)
	}
	for _, c := range h.calls {
		if strings.HasPrefix(c, "install") || c == "reload" {
			t.Fatalf("an unchanged CA re-wrote or reloaded: %v", h.calls)
		}
	}
}

// `sshd -t` refusing the new configuration puts the previous files back and
// never reloads: a machine that had no CA has none again, one that had an
// older CA has exactly that one.
func TestApplySSHCARollsBackWhenSshdTFails(t *testing.T) {
	withSSHCAPaths(t)
	h := &fakeSSHD{included: true, checkErr: errors.New("exit status 255")}
	res := applySSHCA(context.Background(), h, caLine(t))
	if res.OK || !res.RolledBack || !strings.Contains(res.Detail, "sshd -t") {
		t.Fatalf("fresh machine: %+v", res)
	}
	if read(t, sshCAPaths.key) != "<absent>" || read(t, sshCAPaths.conf) != "<absent>" {
		t.Fatal("a failed install left files behind")
	}
	for _, c := range h.calls {
		if c == "reload" {
			t.Fatal("reloaded sshd after sshd -t failed")
		}
	}

	// An older, working CA is restored byte for byte.
	ok := &fakeSSHD{included: true}
	old := caLine(t)
	if res := applySSHCA(context.Background(), ok, old); !res.OK {
		t.Fatal(res.Detail)
	}
	oldConf := read(t, sshCAPaths.conf)
	res = applySSHCA(context.Background(), h, caLine(t))
	if res.OK || !res.RolledBack {
		t.Fatalf("rotation: %+v", res)
	}
	if read(t, sshCAPaths.key) != old+"\n" || read(t, sshCAPaths.conf) != oldConf {
		t.Fatal("the previous CA was not restored")
	}
}

// A drop-in sshd never reads (no Include) or one shadowed by an earlier
// TrustedUserCAKeys is reported and removed, not left lying around.
func TestApplySSHCARefusesIneffectiveDropIn(t *testing.T) {
	for name, h := range map[string]*fakeSSHD{
		"no include": {included: false},
		"shadowed":   {included: true, otherCA: "/etc/ssh/other_ca.pub"},
	} {
		t.Run(name, func(t *testing.T) {
			withSSHCAPaths(t)
			res := applySSHCA(context.Background(), h, caLine(t))
			if res.OK || !res.RolledBack {
				t.Fatalf("%+v", res)
			}
			if read(t, sshCAPaths.conf) != "<absent>" {
				t.Fatal("ineffective drop-in left in place")
			}
		})
	}
}

// Anything but one plain public key is refused before a file is touched.
func TestApplySSHCARefusesBadKey(t *testing.T) {
	withSSHCAPaths(t)
	h := &fakeSSHD{included: true}
	for _, bad := range []string{"", "ssh-ed25519 AAAA\nTrustedUserCAKeys /tmp/x", "garbage"} {
		if res := applySSHCA(context.Background(), h, bad); res.OK {
			t.Fatalf("accepted %q", bad)
		}
	}
	if len(h.calls) != 0 {
		t.Fatalf("touched sshd for a bad key: %v", h.calls)
	}
}

// A reload that fails does not undo a valid, checked configuration.
func TestApplySSHCAReloadFailureKeepsFiles(t *testing.T) {
	withSSHCAPaths(t)
	h := &fakeSSHD{included: true, reloadErr: errors.New("no systemd")}
	res := applySSHCA(context.Background(), h, caLine(t))
	if !res.OK || !strings.Contains(res.Detail, "reload failed") {
		t.Fatalf("%+v", res)
	}
	if read(t, sshCAPaths.conf) == "<absent>" {
		t.Fatal("files removed after a reload failure")
	}
}
