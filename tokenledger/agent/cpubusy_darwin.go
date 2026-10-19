package agent

import (
	"bufio"
	"log"
	"os/exec"
	"strconv"
	"time"
)

// iostatPath is darwin's iostat; a var for tests.
var iostatPath = "/usr/sbin/iostat"

// startCPUSource keeps one `iostat -n0 -w 10` running for the process's life
// and feeds each interval into w. darwin has no sysctl for CPU ticks and the
// binary is cgo-free (no host_statistics), so one long-lived child reports
// every 10 s rather than a process spawned per reading. It dies with the
// agent: its next write to the closed pipe is a SIGPIPE. Restarted a minute
// after it exits.
func startCPUSource(w *cpuWindow) {
	for {
		cmd := exec.Command(iostatPath, "-n0", "-w", strconv.Itoa(int(cpuEvery/time.Second)))
		out, err := cmd.StdoutPipe()
		if err == nil {
			err = cmd.Start()
		}
		if err != nil {
			log.Printf("sysinfo: cpu busy: %v", err)
			time.Sleep(time.Minute)
			continue
		}
		sc := bufio.NewScanner(out)
		first := true
		for sc.Scan() {
			busy, ok := parseIostat(sc.Text())
			if !ok {
				continue
			}
			if first { // the first line is the average since boot
				first = false
				continue
			}
			w.add(time.Now(), busy)
		}
		err = cmd.Wait()
		log.Printf("sysinfo: cpu busy: iostat exited (%v); again in a minute", err)
		time.Sleep(time.Minute)
	}
}
