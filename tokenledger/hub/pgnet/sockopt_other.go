//go:build !linux

package pgnet

import (
	"errors"
	"syscall"
	"time"
)

type syscallRawConn = syscall.RawConn

// setUserTimeout: TCP_USER_TIMEOUT is Linux's; elsewhere (a developer's Mac)
// the keepalive alone bounds a dead connection.
func setUserTimeout(uintptr, time.Duration) error { return nil }

// UserTimeoutOf is not available off Linux.
func UserTimeoutOf(uintptr) (time.Duration, error) {
	return 0, errors.New("TCP_USER_TIMEOUT is Linux only")
}
