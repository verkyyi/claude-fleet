package agent

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// readSysInfo reads /proc: loadavg, and MemAvailable (the kernel's own
// estimate of what can be allocated without swapping).
func readSysInfo() sysInfo {
	var si sysInfo
	if b, err := os.ReadFile("/proc/loadavg"); err == nil {
		if f := strings.Fields(string(b)); len(f) > 0 {
			si.Load1, _ = strconv.ParseFloat(f[0], 64)
		}
	}
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return si
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		kb, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		switch fields[0] {
		case "MemTotal:":
			si.MemTotal = kb << 10
		case "MemAvailable:":
			si.MemFree = kb << 10
		}
	}
	return si
}
