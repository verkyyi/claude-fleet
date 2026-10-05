package agent

import (
	"context"
	"syscall"
)

// netChangeSource reads the PF_ROUTE socket and passes on the messages that
// mean "this machine's reachability may have changed": an address added or
// removed, an interface going up or down. Route add/delete is left out — the
// ARP and cloned-host routes it carries churn constantly on a busy LAN.
func netChangeSource(ctx context.Context) <-chan struct{} {
	fd, err := syscall.Socket(syscall.AF_ROUTE, syscall.SOCK_RAW, syscall.AF_UNSPEC)
	if err != nil {
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
		buf := make([]byte, 2048)
		for ctx.Err() == nil {
			n, err := syscall.Read(fd, buf)
			if err != nil {
				if err == syscall.EAGAIN || err == syscall.EINTR {
					continue
				}
				return
			}
			// rt_msghdr: u_short msglen, u_char version, u_char type.
			if n < 4 {
				continue
			}
			switch buf[3] {
			case syscall.RTM_NEWADDR, syscall.RTM_DELADDR, syscall.RTM_IFINFO:
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}()
	return out
}
