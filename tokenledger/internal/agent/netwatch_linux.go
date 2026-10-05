package agent

import (
	"context"
	"syscall"
)

// rtnetlink multicast groups (linux/rtnetlink.h); package syscall does not
// name them.
const (
	rtmgrpLink       = 0x1
	rtmgrpIPv4IfAddr = 0x10
	rtmgrpIPv6IfAddr = 0x100
)

// netChangeSource joins rtnetlink's link and address groups: an interface
// going up or down, an IPv4/IPv6 address added or removed. Every message on
// those groups is a change worth a wake, so none is parsed.
func netChangeSource(ctx context.Context) <-chan struct{} {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return nil
	}
	sa := &syscall.SockaddrNetlink{
		Family: syscall.AF_NETLINK,
		Groups: rtmgrpLink | rtmgrpIPv4IfAddr | rtmgrpIPv6IfAddr,
	}
	if err := syscall.Bind(fd, sa); err != nil {
		syscall.Close(fd)
		return nil
	}
	// A read that blocks forever would pin an OS thread past ctx: wake every
	// second to look.
	tv := syscall.Timeval{Sec: 1}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		syscall.Close(fd)
		return nil
	}
	out := make(chan struct{}, 1)
	go func() {
		defer close(out)
		defer syscall.Close(fd)
		buf := make([]byte, 8192)
		for ctx.Err() == nil {
			_, _, err := syscall.Recvfrom(fd, buf, 0)
			if err != nil {
				if err == syscall.EAGAIN || err == syscall.EINTR || err == syscall.ENOBUFS {
					continue
				}
				return
			}
			select {
			case out <- struct{}{}:
			default:
			}
		}
	}()
	return out
}
