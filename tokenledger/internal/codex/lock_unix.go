//go:build !windows

package codex

import (
	"os"
	"syscall"
)

func lockFile(f *os.File, shared bool) error {
	op := syscall.LOCK_EX
	if shared {
		op = syscall.LOCK_SH
	}
	return syscall.Flock(int(f.Fd()), op|syscall.LOCK_NB)
}
func unlockFile(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }
