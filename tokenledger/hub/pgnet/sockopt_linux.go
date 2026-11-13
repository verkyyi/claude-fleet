//go:build linux

package pgnet

import (
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type syscallRawConn = syscall.RawConn

// setUserTimeout sets TCP_USER_TIMEOUT (milliseconds) on fd.
func setUserTimeout(fd uintptr, d time.Duration) error {
	return unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_USER_TIMEOUT, int(d/time.Millisecond))
}

// UserTimeoutOf reads TCP_USER_TIMEOUT back off fd (tests).
func UserTimeoutOf(fd uintptr) (time.Duration, error) {
	v, err := unix.GetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_USER_TIMEOUT)
	return time.Duration(v) * time.Millisecond, err
}
