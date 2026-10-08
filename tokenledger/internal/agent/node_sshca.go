package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// The admin agent's half of the SSH user CA (claude-fleet#1412).
//
// The hub sends its CA public key on every admin connect; this agent makes the
// machine's sshd trust it for NEW connections, and nothing else:
//
//   - it writes exactly two files, both fixed here: the key at
//     control.SSHCAKeyPath and a one-line sshd_config.d drop-in at
//     control.SSHCAConfPath (`TrustedUserCAKeys <that path>`);
//   - it never edits sshd_config, any authorized_keys, or anyone's home — the
//     operator's own key and every colleague's existing key keep working;
//   - before anything is in effect it runs `sshd -t`; if that fails, the
//     previous files go back (or the new ones go away) and sshd is never asked
//     to read the bad configuration;
//   - it then checks `sshd -T` really says TrustedUserCAKeys is ours — a
//     drop-in that sshd_config never Includes is reported, not left lying;
//   - on macOS sshd is started per connection by launchd, so the change takes
//     effect on the next connection and nothing is restarted; elsewhere the
//     listener is sent a reload (SIGHUP), which leaves established sessions
//     alone.
//
// Only an agent started as its machine's admin agent (CCQUOTA_FLEET_ADMIN=1)
// does any of it, and only with password-less sudo (`sudo -n`): it never
// waits on a password prompt.

// sshdHost is the machine's sshd, as this file uses it. The real one goes
// through `sudo -n`; tests substitute their own.
type sshdHost interface {
	// Install writes content to dst, mode 0644, owned by root.
	Install(ctx context.Context, dst string, content []byte) error
	// Remove deletes dst; a missing file is not an error.
	Remove(ctx context.Context, dst string) error
	// Check is `sshd -t`: the configuration as it is now on disk.
	Check(ctx context.Context) (string, error)
	// Effective is `sshd -T`: the configuration sshd would run with.
	Effective(ctx context.Context) (string, error)
	// Reload makes a long-running sshd re-read its configuration. A no-op
	// where sshd runs per connection (macOS).
	Reload(ctx context.Context) error
}

// newSSHDHost is the injection point for tests.
var newSSHDHost = func() sshdHost { return sudoSSHD{} }

// sshCAPaths are the two files, overridable for tests.
var sshCAPaths = struct{ key, conf string }{control.SSHCAKeyPath, control.SSHCAConfPath}

const sshCATimeout = time.Minute

type sudoSSHD struct{}

func sudo(ctx context.Context, stdin []byte, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "sudo", append([]string{"-n"}, args...)...)
	cmd.Dir = "/"
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	if err != nil {
		return out.String(), fmt.Errorf("sudo %s: %w: %s", args[0], err, tail(strings.TrimSpace(out.String()), 400))
	}
	return out.String(), nil
}

func (sudoSSHD) Install(ctx context.Context, dst string, content []byte) error {
	f, err := os.CreateTemp("", "fleet-sshca-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(content); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	_, err = sudo(ctx, nil, "/usr/bin/install", "-m", "0644", f.Name(), dst)
	return err
}

func (sudoSSHD) Remove(ctx context.Context, dst string) error {
	_, err := sudo(ctx, nil, "/bin/rm", "-f", dst)
	return err
}

func (sudoSSHD) Check(ctx context.Context) (string, error) {
	return sudo(ctx, nil, "/usr/sbin/sshd", "-t")
}

func (sudoSSHD) Effective(ctx context.Context) (string, error) {
	return sudo(ctx, nil, "/usr/sbin/sshd", "-T")
}

func (sudoSSHD) Reload(ctx context.Context) error {
	if runtime.GOOS == "darwin" {
		return nil // launchd starts sshd per connection: the next one reads it
	}
	var errs []error
	for _, unit := range []string{"ssh", "sshd"} {
		if _, err := sudo(ctx, nil, "systemctl", "reload", unit); err == nil {
			return nil
		} else {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// sshCAConf is the drop-in's content: one directive, nothing else.
func sshCAConf(keyPath string) []byte {
	return []byte("# Managed by ccquota (claude-fleet#1412): trust the fleet hub's SSH user CA.\n" +
		"# Existing keys are untouched; this only ADDS certificate logins.\n" +
		"TrustedUserCAKeys " + keyPath + "\n")
}

// sshCAMu serialises applies: two admin connects racing must not interleave
// write-and-rollback.
var sshCAMu sync.Mutex

// applySSHCA makes this machine's sshd trust pub. The result says what
// happened; it never leaves a configuration `sshd -t` refuses.
func applySSHCA(ctx context.Context, h sshdHost, pub string) control.SSHCAResult {
	sshCAMu.Lock()
	defer sshCAMu.Unlock()
	if !sshca.ValidCAPublicKey(pub) {
		return control.SSHCAResult{Detail: "refused: not a single plain public key"}
	}
	wantKey := []byte(pub + "\n")
	wantConf := sshCAConf(sshCAPaths.key)

	oldKey, keyErr := os.ReadFile(sshCAPaths.key)
	oldConf, confErr := os.ReadFile(sshCAPaths.conf)
	if keyErr == nil && confErr == nil && bytes.Equal(oldKey, wantKey) && bytes.Equal(oldConf, wantConf) {
		if err := effectiveCA(ctx, h); err != nil {
			return control.SSHCAResult{Detail: err.Error()}
		}
		return control.SSHCAResult{OK: true, Detail: "already trusted"}
	}
	for _, e := range []error{keyErr, confErr} {
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return control.SSHCAResult{Detail: "read current files: " + e.Error()}
		}
	}

	// Put the previous state back exactly: the old content where there was
	// one, nothing where there was none.
	rollback := func() error {
		var errs []error
		restore := func(path string, old []byte, readErr error) {
			if readErr == nil {
				errs = append(errs, h.Install(ctx, path, old))
			} else {
				errs = append(errs, h.Remove(ctx, path))
			}
		}
		// The drop-in first: with it gone, the key file is inert.
		restore(sshCAPaths.conf, oldConf, confErr)
		restore(sshCAPaths.key, oldKey, keyErr)
		return errors.Join(errs...)
	}
	fail := func(why string) control.SSHCAResult {
		res := control.SSHCAResult{Detail: why}
		if err := rollback(); err != nil {
			res.Detail += "; ROLLBACK FAILED: " + err.Error()
			return res
		}
		res.RolledBack = true
		return res
	}

	// The key before the drop-in that names it, so sshd never sees a
	// TrustedUserCAKeys pointing at a file that is not there yet.
	if err := h.Install(ctx, sshCAPaths.key, wantKey); err != nil {
		return fail("write " + sshCAPaths.key + ": " + err.Error())
	}
	if err := h.Install(ctx, sshCAPaths.conf, wantConf); err != nil {
		return fail("write " + sshCAPaths.conf + ": " + err.Error())
	}
	if out, err := h.Check(ctx); err != nil {
		return fail("sshd -t refused the new configuration: " + tail(strings.TrimSpace(out+" "+err.Error()), 600))
	}
	if err := effectiveCA(ctx, h); err != nil {
		return fail(err.Error())
	}
	res := control.SSHCAResult{OK: true, Changed: true, Detail: "trusted for new connections"}
	if err := h.Reload(ctx); err != nil {
		// The files are valid and in place; a listener that has not re-read
		// them yet picks them up on its next reload. Not a reason to undo.
		res.Detail += "; reload failed (takes effect on next sshd reload): " + tail(err.Error(), 300)
	}
	return res
}

// effectiveCA checks sshd would really use our key file.
func effectiveCA(ctx context.Context, h sshdHost) error {
	out, err := h.Effective(ctx)
	if err != nil {
		return errors.New("sshd -T: " + tail(err.Error(), 400))
	}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && strings.EqualFold(f[0], "trustedusercakeys") {
			if f[1] == sshCAPaths.key {
				return nil
			}
			return fmt.Errorf("sshd uses TrustedUserCAKeys %s, not %s (set earlier in its configuration); left as it was", f[1], sshCAPaths.key)
		}
	}
	return errors.New("sshd -T does not list TrustedUserCAKeys: sshd_config does not Include sshd_config.d; left as it was")
}

// handleSSHCA answers one TypeSSHCA. Like an account op it returns at once;
// sudo runs in the background.
func (a *Agent) handleSSHCA(ctx context.Context, conn nodeLink, m control.Message) {
	write := func(msg control.Message) {
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = conn.write(wctx, msg)
	}
	refuse := func(code, msg string) {
		write(control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: msg}})
	}
	if !a.cfg.FleetAdmin {
		refuse(control.CodeNotAdmin, "this agent was not started as its machine's admin agent")
		return
	}
	var req control.SSHCA
	if err := json.Unmarshal(m.Payload, &req); err != nil || !sshca.ValidCAPublicKey(req.PublicKey) {
		refuse(control.CodeBadArgs, "ssh_ca needs one plain public key")
		return
	}
	go func() {
		actx, cancel := context.WithTimeout(a.bgCtx(), sshCATimeout)
		res := applySSHCA(actx, newSSHDHost(), req.PublicKey)
		cancel()
		log.Printf("control channel: ssh CA: ok=%v changed=%v rolled_back=%v %s", res.OK, res.Changed, res.RolledBack, res.Detail)
		out, err := control.New(control.TypeSSHCAResult, res)
		if err != nil {
			return
		}
		out.OpID = m.OpID
		write(out)
	}()
}
