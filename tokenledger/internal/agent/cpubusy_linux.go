package agent

import (
	"os"
	"time"
)

// startCPUSource diffs /proc/stat's aggregate cpu line every cpuEvery.
func startCPUSource(w *cpuWindow) {
	var pt, pi uint64
	for {
		if b, err := os.ReadFile("/proc/stat"); err == nil {
			if t, i, ok := procStatTicks(string(b)); ok {
				if pt > 0 && t > pt {
					w.add(time.Now(), 1-float64(i-pi)/float64(t-pt))
				}
				pt, pi = t, i
			}
		}
		time.Sleep(cpuEvery)
	}
}
