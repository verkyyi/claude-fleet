package agent

import (
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CPU busy (claude-fleet#2882): the share of CPU time spent in user + system
// over about the last minute. Placement gates on it rather than load1/ncpu —
// load counts every runnable process, and a machine running two hundred small
// fleet processes read 20 on 15 cores while three of them worked.
//
// A platform source (cpubusy_<os>.go) feeds one reading per cpuEvery into the
// process's window; the beat carries the window's mean.

// cpuEvery is how often a source reports one interval; cpuSpan is how far back
// the beat's mean reaches.
const (
	cpuEvery = 10 * time.Second
	cpuSpan  = 65 * time.Second
)

// cpuWindow keeps the readings of the last cpuSpan.
type cpuWindow struct {
	mu   sync.Mutex
	once sync.Once
	at   []time.Time
	v    []float64
}

// add records one interval's busy share (clamped to 0..1) read at t.
func (w *cpuWindow) add(t time.Time, busy float64) {
	if math.IsNaN(busy) {
		return
	}
	busy = math.Max(0, math.Min(1, busy))
	w.mu.Lock()
	defer w.mu.Unlock()
	w.at, w.v = append(w.at, t), append(w.v, busy)
	w.trim(t)
}

func (w *cpuWindow) trim(now time.Time) {
	i := 0
	for i < len(w.at) && now.Sub(w.at[i]) > cpuSpan {
		i++
	}
	w.at, w.v = w.at[i:], w.v[i:]
}

// mean is the window's average at now, rounded to a thousandth; nil when it
// holds no reading (none yet, or the source stopped answering).
func (w *cpuWindow) mean(now time.Time) *float64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.trim(now)
	if len(w.v) == 0 {
		return nil
	}
	sum := 0.0
	for _, x := range w.v {
		sum += x
	}
	m := math.Round(sum/float64(len(w.v))*1000) / 1000
	return &m
}

// processCPU is the process's one window, fed by startCPUSource on first use;
// every login of a machine agent reads the same CPUs.
var processCPU = &cpuWindow{}

// busy starts the platform source once and answers the window's mean.
func (w *cpuWindow) busy() *float64 {
	w.once.Do(func() { go startCPUSource(w) })
	return w.mean(time.Now())
}

// maxCPUBusy is this machine's own ceiling, carried in every beat
// (machine.env FLEET_MAX_CPU_BUSY); 0 = the hub's.
var maxCPUBusy float64

// SetMaxCPUBusy takes FLEET_MAX_CPU_BUSY's value: a share in (0,1], or a
// percent in (1,100]. Anything else leaves the hub's ceiling.
func SetMaxCPUBusy(v string) {
	maxCPUBusy = ParseCPUBusy(v)
}

// ParseCPUBusy reads a CPU-busy ceiling: 0.8, or 80 / 80%. 0 for none.
func ParseCPUBusy(v string) float64 {
	v = strings.TrimSuffix(strings.TrimSpace(v), "%")
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || math.IsNaN(f) || f <= 0 || f > 100 {
		return 0
	}
	if f > 1 {
		f /= 100
	}
	return f
}

// parseIostat reads one data line of `iostat -n0` ("us sy id 1m 5m 15m") into
// its busy share; ok false for a header or anything else.
func parseIostat(line string) (float64, bool) {
	f := strings.Fields(line)
	if len(f) < 3 {
		return 0, false
	}
	var n [3]float64
	for i := 0; i < 3; i++ {
		x, err := strconv.ParseFloat(f[i], 64)
		if err != nil {
			return 0, false
		}
		n[i] = x
	}
	if n[0]+n[1]+n[2] <= 0 {
		return 0, false
	}
	return (n[0] + n[1]) / 100, true
}

// procStatTicks reads /proc/stat's aggregate "cpu" line into its total and
// idle (idle + iowait) ticks.
func procStatTicks(stat string) (total, idle uint64, ok bool) {
	for _, line := range strings.Split(stat, "\n") {
		f := strings.Fields(line)
		if len(f) < 5 || f[0] != "cpu" {
			continue
		}
		for i, s := range f[1:] {
			x, err := strconv.ParseUint(s, 10, 64)
			if err != nil {
				return 0, 0, false
			}
			if i >= 8 { // guest, guest_nice are already in user / nice
				break
			}
			total += x
			if i == 3 || i == 4 {
				idle += x
			}
		}
		return total, idle, true
	}
	return 0, 0, false
}
