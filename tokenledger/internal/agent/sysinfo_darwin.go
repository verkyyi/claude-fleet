package agent

import (
	"encoding/binary"

	"golang.org/x/sys/unix"
)

// readSysInfo reads load and memory from the kernel through sysctl: no
// process spawned on a seconds cadence.
//
// "Free" is free + speculative + file-backed pageable pages — what the kernel
// can hand out without swapping, which is the number "can this machine take
// another session" actually asks about. page_free_count alone reads near zero
// on any Mac that has been up a while, because macOS fills idle RAM with cache.
func readSysInfo() sysInfo {
	var si sysInfo
	if b, err := unix.SysctlRaw("vm.loadavg"); err == nil && len(b) >= 24 {
		// struct loadavg { fixpt_t ldavg[3]; long fscale; } — 3×u32, pad, i64.
		ld := binary.LittleEndian.Uint32(b[0:4])
		if fscale := binary.LittleEndian.Uint64(b[16:24]); fscale > 0 {
			si.Load1 = float64(ld) / float64(fscale)
		}
	}
	if total, err := unix.SysctlUint64("hw.memsize"); err == nil {
		si.MemTotal = total
	}
	page, err := unix.SysctlUint32("hw.pagesize")
	if err != nil || page == 0 {
		return si
	}
	var pages uint64
	for _, k := range []string{"vm.page_free_count", "vm.page_speculative_count", "vm.page_pageable_external_count"} {
		if v, err := unix.SysctlUint32(k); err == nil {
			pages += uint64(v)
		}
	}
	si.MemFree = pages * uint64(page)
	return si
}
