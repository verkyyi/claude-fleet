package agent

import (
	"math"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#2882: the beat carries CPU busy as the mean of the last
// minute's readings, and the machine's own ceiling beside it.
func TestCPUBusyWindowMean(t *testing.T) {
	w := &cpuWindow{}
	w.once.Do(func() {})
	if w.busy() != nil {
		t.Fatal("an empty window must say nothing, never 0")
	}
	t0 := time.Now()
	w.add(t0.Add(-2*time.Minute), 1) // older than the span: dropped
	w.add(t0.Add(-20*time.Second), 0.2)
	w.add(t0.Add(-10*time.Second), 0.4)
	w.add(t0, 1.5) // clamped to 1
	got := w.mean(t0)
	if got == nil || math.Abs(*got-0.533) > 1e-9 {
		t.Fatalf("mean = %v, want 0.533", got)
	}
	if w.mean(t0.Add(2*time.Minute)) != nil {
		t.Fatal("a source that stopped answering must age out to nothing")
	}
}

func TestParseIostat(t *testing.T) {
	for line, want := range map[string]float64{
		" 20 23 57  4.08 3.39 3.13": 0.43,
		"  3  1 96 20.10 18.2 17.9": 0.04,
	} {
		got, ok := parseIostat(line)
		if !ok || math.Abs(got-want) > 1e-9 {
			t.Fatalf("%q = %v %v, want %v", line, got, ok, want)
		}
	}
	for _, line := range []string{"      cpu    load average", " us sy id   1m   5m   15m", "", "0 0 0"} {
		if _, ok := parseIostat(line); ok {
			t.Fatalf("%q read as data", line)
		}
	}
}

func TestProcStatTicks(t *testing.T) {
	a := "cpu  100 0 50 800 50 0 0 0 7 7\ncpu0 1 2 3 4 5\n"
	b := "cpu  160 0 70 900 70 0 0 0 9 9\n"
	t1, i1, ok1 := procStatTicks(a)
	t2, i2, ok2 := procStatTicks(b)
	if !ok1 || !ok2 || t1 != 1000 || i1 != 850 {
		t.Fatalf("a = %d %d %v", t1, i1, ok1)
	}
	if busy := 1 - float64(i2-i1)/float64(t2-t1); math.Abs(busy-0.4) > 1e-9 {
		t.Fatalf("busy = %v, want 0.4", busy)
	}
}

func TestParseCPUBusy(t *testing.T) {
	for in, want := range map[string]float64{"0.6": 0.6, "60": 0.6, "60%": 0.6, " 1 ": 1, "": 0, "0": 0, "-1": 0, "abc": 0, "150": 0} {
		if got := ParseCPUBusy(in); math.Abs(got-want) > 1e-9 {
			t.Fatalf("ParseCPUBusy(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestBeatCarriesCPUBusyAndCeiling(t *testing.T) {
	stubSys(t, func() sysInfo { return sysInfo{Load1: 20} })
	processCPU.add(time.Now(), 0.25)
	old := maxCPUBusy
	SetMaxCPUBusy("70")
	t.Cleanup(func() { maxCPUBusy = old })
	var hb control.Heartbeat
	fillSys(&hb, processSys)
	if hb.CPUBusy == nil || *hb.CPUBusy != 0.25 || hb.MaxCPUBusy != 0.7 {
		t.Fatalf("beat cpu_busy %v max %v", hb.CPUBusy, hb.MaxCPUBusy)
	}
}
