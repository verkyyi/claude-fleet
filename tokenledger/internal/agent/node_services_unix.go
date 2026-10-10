//go:build unix

package agent

import (
	"os"
	"syscall"
)

// openOwnedLog opens path read-only without following a link, and only a
// regular file uid owns.
func openOwnedLog(path string, uid int) (*os.File, os.FileInfo, bool) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, nil, false
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, false
	}
	st, isStat := fi.Sys().(*syscall.Stat_t)
	if !fi.Mode().IsRegular() || !isStat || int(st.Uid) != uid {
		f.Close()
		return nil, nil, false
	}
	return f, fi, true
}

// fileID is fi's device and inode (0, 0 when the platform does not say).
func fileID(fi os.FileInfo) (dev, ino uint64) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Dev), uint64(st.Ino)
	}
	return 0, 0
}
