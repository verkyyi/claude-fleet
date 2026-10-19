package agent

import (
	"encoding/binary"
	"fmt"

	"golang.org/x/sys/unix"
)

// readSysInfo reads load and memory from the kernel through sysctl: no
// process spawned on a seconds cadence.
//
// "Free" is free + speculative + file-backed pageable pages — what the kernel
// can hand out without swapping, which is the number "can this machine take
// another session" actually asks about. page_free_count alone reads near zero
// on any Mac that has been up a while, because macOS fills idle RAM with cache.
//
// MemPressure is kern.memorystatus_vm_pressure_level (1 normal, 2 warn, 4
// critical — claude-fleet#1994): the kernel's own verdict, which placement
// reads beside the free-memory floor.
func readSysInfo() sysInfo {
	var si sysInfo
	if b, err := unix.SysctlRaw("vm.loadavg"); err != nil {
		si.unread("load", "vm.loadavg: "+err.Error())
	} else if len(b) < 24 {
		si.unread("load", fmt.Sprintf("vm.loadavg: %d bytes", len(b)))
	} else {
		// struct loadavg { fixpt_t ldavg[3]; long fscale; } — 3×u32, pad, i64.
		ld := binary.LittleEndian.Uint32(b[0:4])
		if fscale := binary.LittleEndian.Uint64(b[16:24]); fscale > 0 {
			si.Load1 = float64(ld) / float64(fscale)
		} else {
			si.unread("load", "vm.loadavg: fscale 0")
		}
	}
	if lv, err := unix.SysctlUint32("kern.memorystatus_vm_pressure_level"); err == nil {
		si.MemPressure = int(lv)
	}
	if total, err := unix.SysctlUint64("hw.memsize"); err == nil {
		si.MemTotal = total
	} else {
		si.unread("mem", "hw.memsize: "+err.Error())
	}
	page, err := unix.SysctlUint32("hw.pagesize")
	if err != nil || page == 0 {
		si.unread("mem", fmt.Sprintf("hw.pagesize: %d %v", page, err))
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
