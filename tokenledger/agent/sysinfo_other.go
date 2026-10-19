//go:build !darwin && !linux

package agent

import "runtime"

// readSysInfo has no source on this platform; the heartbeat carries zeros
// and says so (sys_unread), which the roster renders as 读不到.
func readSysInfo() sysInfo {
	var si sysInfo
	si.unread("load", "no load source on "+runtime.GOOS)
	si.unread("mem", "no memory source on "+runtime.GOOS)
	return si
}
