package agent

import (
	"golang.org/x/sys/unix"
	"net"
)

func previewPeerUID(c *net.UnixConn) (uint32, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var peerErr error
	err = raw.Control(func(fd uintptr) {
		var cred *unix.Xucred
		cred, peerErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if peerErr == nil {
			uid = cred.Uid
		}
	})
	if err != nil {
		return 0, err
	}
	return uid, peerErr
}
