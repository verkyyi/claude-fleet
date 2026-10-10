//go:build !darwin && !linux

package agent

// startCPUSource has no source on this platform: the beat carries no
// cpu_busy, and placement gates on load as before.
func startCPUSource(w *cpuWindow) {}
