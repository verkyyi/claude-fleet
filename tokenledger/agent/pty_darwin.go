//go:build darwin

package agent

import (
	"bytes"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

// openPTY opens a pseudo-terminal pair (posix_openpt · grantpt · unlockpt ·
// ptsname, by hand: no cgo, no dependency).
func openPTY() (master, slave *os.File, err error) {
	fd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	m := os.NewFile(uintptr(fd), "/dev/ptmx")
	for _, req := range []uintptr{unix.TIOCPTYGRANT, unix.TIOCPTYUNLK} {
		if _, _, e := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), req, 0); e != 0 {
			m.Close()
			return nil, nil, e
		}
	}
	var name [128]byte
	if _, _, e := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), unix.TIOCPTYGNAME, uintptr(unsafe.Pointer(&name[0]))); e != 0 {
		m.Close()
		return nil, nil, e
	}
	n := bytes.IndexByte(name[:], 0)
	if n < 0 {
		n = len(name)
	}
	s, err := os.OpenFile(string(name[:n]), os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		m.Close()
		return nil, nil, err
	}
	return m, s, nil
}
