//go:build darwin || linux

package agent

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"golang.org/x/sys/unix"
)

// RunPreviewPipe is a short-lived, already unprivileged helper. Its only target
// is a basename inside the kernel user's ~/.fleet-preview (0700). The helper
// never reads project configuration or executes tenant code.
func RunPreviewPipe(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) != 1 || !control.PreviewSocketName(args[0]) {
		return errors.New("preview-pipe requires a socket basename; TCP/URLs are unsupported")
	}
	uid := os.Geteuid()
	if uid < 500 || os.Getuid() != uid {
		return errors.New("preview requires an ordinary, unprivileged login")
	}
	u, err := user.LookupId(fmt.Sprint(uid))
	if err != nil {
		return err
	}
	c, err := previewSocket(u.HomeDir, args[0], uid)
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err = stdout.Write([]byte{chatPipeReady}); err != nil {
		return err
	}
	go func() { io.Copy(c, stdin); c.CloseWrite() }()
	_, err = io.Copy(stdout, c)
	return err
}

// This runs only in the disposable helper: fchdir pins the directory inode,
// so ancestor replacement cannot redirect connect. The socket basename can
// still race within this tenant-owned directory: peer UID is the security
// boundary, checked before any application byte. Inode checks are defense in
// depth, not a claim of immutable same-UID service identity. No chdir in
// the node process. All ancestors are opened without following symlinks.
func previewSocket(home, name string, uid int) (*net.UnixConn, error) {
	return previewSocketDial(home, name, uid, net.DialTimeout)
}

func previewSocketDial(home, name string, uid int, dial func(string, string, time.Duration) (net.Conn, error)) (*net.UnixConn, error) {
	if !filepath.IsAbs(home) || filepath.Clean(home) != home || !control.PreviewSocketName(name) {
		return nil, errors.New("invalid preview path")
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	defer func() { unix.Close(fd) }()
	parts := strings.Split(strings.TrimPrefix(filepath.Join(home, ".fleet-preview"), "/"), "/")
	for i, p := range parts {
		next, e := unix.Openat(fd, p, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if e != nil {
			return nil, e
		}
		unix.Close(fd)
		fd = next
		var st unix.Stat_t
		if e = unix.Fstat(fd, &st); e != nil {
			return nil, e
		}
		if (st.Uid != 0 && st.Uid != uint32(uid)) || st.Mode&0022 != 0 {
			return nil, errors.New("unsafe preview ancestor")
		}
		if i == len(parts)-1 && (st.Uid != uint32(uid) || st.Mode&0077 != 0) {
			return nil, errors.New("preview directory must be owned by this login with mode 0700")
		}
	}
	if err = unix.Fchdir(fd); err != nil {
		return nil, err
	}
	var before, after unix.Stat_t
	if err = unix.Fstatat(fd, name, &before, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, err
	}
	if before.Mode&unix.S_IFMT != unix.S_IFSOCK || before.Uid != uint32(uid) || before.Mode&0077 != 0 {
		return nil, errors.New("preview socket must be this login's socket with mode 0600")
	}
	raw, err := dial("unix", "./"+name, 5*time.Second)
	if err != nil {
		return nil, err
	}
	c := raw.(*net.UnixConn)
	fail := func(e error) (*net.UnixConn, error) { c.Close(); return nil, e }
	peer, err := previewPeerUID(c)
	if err != nil {
		return fail(err)
	}
	if peer != uint32(uid) {
		return fail(errors.New("preview server UID differs from tenant UID"))
	}
	if err = unix.Fstatat(fd, name, &after, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return fail(err)
	}
	if before.Dev != after.Dev || before.Ino != after.Ino || before.Mode != after.Mode || before.Uid != after.Uid {
		return fail(errors.New("preview socket replaced during connect"))
	}
	return c, nil
}
