//go:build !darwin && !linux

package agent

// readSysInfo has no source on this platform; the heartbeat carries zeros,
// which the roster renders as unknown.
func readSysInfo() sysInfo { return sysInfo{} }
