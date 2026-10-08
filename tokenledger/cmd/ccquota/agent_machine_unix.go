//go:build unix

package main

import (
	"os"
	"syscall"
)

// fileUID is the owner of fi.
func fileUID(fi os.FileInfo) (uint32, bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return st.Uid, true
}
