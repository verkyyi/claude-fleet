package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A cluster's readings (claude-fleet#3734): both halves.
//
// fleet-ops (FleetClusterOps set) reads every user pod's fleet container — its
// use from metrics.k8s.io, its limits from the pod — every
// control.ClusterReadingEvery and sends them up its ops link. A pod's reading
// is its own cgroup's (#3542, #3733): memory used against the container's
// memory limit, CPU used against its CPU limit — never the host's /proc. A pod
// with no limit gets that half empty, and its login probes for itself.
//
// A login in a user pod (FLEET_USER_POD=1, not root — the pod runs as its one
// login, #3757) lists CapClusterReading and writes what the hub hands it into
// its own $FLEET_CONF_DIR/cluster/machine.json, the file fleet_machine_reading
// (bin/fleet-lib.sh) reads first. Nothing else lists it, and nothing else
// changes.

// clusterPodContainer is the container a user pod's sessions run in
// (extras/managed-node/render.py user_pod_resources).
const clusterPodContainer = "fleet"

// The memory levels fleet_mem_probe derives on Linux: <5 % free → 4, <15 % → 2.
func memLevel(availPct int) int {
	switch {
	case availPct < 5:
		return 4
	case availPct < 15:
		return 2
	}
	return 1
}

// parseCPU is a Kubernetes CPU quantity in cores ("250m", "2", "123456n").
func parseCPU(q string) (float64, bool) {
	q = strings.TrimSpace(q)
	if q == "" {
		return 0, false
	}
	div := 1.0
	switch q[len(q)-1] {
	case 'n':
		div, q = 1e9, q[:len(q)-1]
	case 'u':
		div, q = 1e6, q[:len(q)-1]
	case 'm':
		div, q = 1e3, q[:len(q)-1]
	}
	v, err := strconv.ParseFloat(q, 64)
	if err != nil || v < 0 || math.IsInf(v, 0) || math.IsNaN(v) {
		return 0, false
	}
	return v / div, true
}

// parseMem is a Kubernetes memory quantity in bytes ("6Gi", "123456Ki", "1G").
func parseMem(q string) (float64, bool) {
	q = strings.TrimSpace(q)
	mult := 1.0
	for _, s := range []struct {
		suf string
		m   float64
	}{{"Ki", 1 << 10}, {"Mi", 1 << 20}, {"Gi", 1 << 30}, {"Ti", 1 << 40},
		{"k", 1e3}, {"K", 1e3}, {"M", 1e6}, {"G", 1e9}, {"T", 1e12}} {
		if strings.HasSuffix(q, s.suf) {
			mult, q = s.m, strings.TrimSuffix(q, s.suf)
			break
		}
	}
	v, err := strconv.ParseFloat(q, 64)
	if q == "" || err != nil || v < 0 || math.IsInf(v, 0) || math.IsNaN(v) {
		return 0, false
	}
	return v * mult, true
}

// podLimits is one user pod's fleet container's limits, by pod object name.
type podLimits struct {
	pod      string // the fleet/pod label: u-<nonce>, the machine the hub knows
	cpu, mem float64
}

// userPodLimits reads the pods list (labelSelector fleet/role=user).
func userPodLimits(raw []byte) (map[string]podLimits, error) {
	var l struct {
		Items []struct {
			Metadata struct {
				Name   string            `json:"name"`
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
			Spec struct {
				Containers []struct {
					Name      string `json:"name"`
					Resources struct {
						Limits map[string]string `json:"limits"`
					} `json:"resources"`
				} `json:"containers"`
			} `json:"spec"`
			Status struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	out := map[string]podLimits{}
	for _, it := range l.Items {
		pod := it.Metadata.Labels["fleet/pod"]
		if it.Metadata.Labels["fleet/role"] != "user" || !jobOwnerRE.MatchString(pod) || it.Status.Phase != "Running" {
			continue
		}
		pl := podLimits{pod: pod}
		for _, c := range it.Spec.Containers {
			if c.Name != clusterPodContainer {
				continue
			}
			pl.cpu, _ = parseCPU(c.Resources.Limits["cpu"])
			pl.mem, _ = parseMem(c.Resources.Limits["memory"])
		}
		out[it.Metadata.Name] = pl
	}
	return out, nil
}

// userPodsPresent is every user pod standing in the pods list, by its
// fleet/pod label, whatever its phase (claude-fleet#4887): a pod starting,
// running or stopping still has its Deployment; one deleted or scaled to 0
// has no pod object at all. Sorted, each once.
func userPodsPresent(raw []byte) ([]string, error) {
	var l struct {
		Items []struct {
			Metadata struct {
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []string{}
	for _, it := range l.Items {
		pod := it.Metadata.Labels["fleet/pod"]
		if it.Metadata.Labels["fleet/role"] != "user" || !jobOwnerRE.MatchString(pod) || seen[pod] {
			continue
		}
		seen[pod] = true
		out = append(out, pod)
	}
	sort.Strings(out)
	return out, nil
}

// podUsage is one pod's fleet container's use, by pod object name.
type podUsage struct{ cpu, mem float64 }

// userPodUsage reads metrics.k8s.io's pod list.
func userPodUsage(raw []byte) (map[string]podUsage, error) {
	var l struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Containers []struct {
				Name  string            `json:"name"`
				Usage map[string]string `json:"usage"`
			} `json:"containers"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	out := map[string]podUsage{}
	for _, it := range l.Items {
		for _, c := range it.Containers {
			if c.Name != clusterPodContainer {
				continue
			}
			cpu, ok1 := parseCPU(c.Usage["cpu"])
			mem, ok2 := parseMem(c.Usage["memory"])
			if ok1 && ok2 {
				out[it.Metadata.Name] = podUsage{cpu: cpu, mem: mem}
			}
		}
	}
	return out, nil
}

// podReading is one pod's reading off its limits and use: a half whose limit
// is missing stays empty.
func podReading(l podLimits, u podUsage, now time.Time) control.MachineReading {
	r := control.MachineReading{V: 1, TS: now.Unix()}
	if l.mem > 0 {
		avail := int((l.mem - u.mem) * 100 / l.mem)
		if avail < 0 {
			avail = 0
		}
		// level · free % · compressor % · swap MB: a pod has neither of the last two
		r.MemProbe = fmt.Sprintf("%d %d 0 0", memLevel(avail), avail)
		r.MemTotalMB = strconv.Itoa(int(l.mem / (1 << 20)))
	}
	if l.cpu > 0 {
		r.LoadPerCore = strconv.FormatFloat(u.cpu/l.cpu, 'f', 2, 64)
	}
	return r
}

// readClusterReadings is every running user pod's reading, sorted by pod,
// and the list of every user pod standing (Listed: claude-fleet#4887).
func (a *Agent) readClusterReadings(ctx context.Context) (control.ClusterReadings, error) {
	var cr control.ClusterReadings
	k, err := a.kubeReader()
	if err != nil {
		return cr, err
	}
	sel := url.QueryEscape("fleet/role=user")
	st, raw, err := k.get(ctx, "/api/v1/namespaces/"+url.PathEscape(k.ns)+"/pods?labelSelector="+sel, 8<<20)
	if err != nil {
		return cr, err
	}
	if st != 200 {
		return cr, fmt.Errorf("pods: HTTP %d", st)
	}
	limits, err := userPodLimits(raw)
	if err != nil {
		return cr, fmt.Errorf("pods: %w", err)
	}
	present, err := userPodsPresent(raw)
	if err != nil {
		return cr, fmt.Errorf("pods: %w", err)
	}
	// A list too long to send whole is not a list: the hub would read the
	// cut-off pods as gone.
	if len(present) <= control.MaxClusterReadings {
		cr.Listed, cr.Present = true, present
	}
	st, raw, err = k.get(ctx, "/apis/metrics.k8s.io/v1beta1/namespaces/"+url.PathEscape(k.ns)+"/pods?labelSelector="+sel, 8<<20)
	if err != nil {
		return cr, err
	}
	if st != 200 {
		return cr, fmt.Errorf("pod metrics: HTTP %d", st)
	}
	usage, err := userPodUsage(raw)
	if err != nil {
		return cr, fmt.Errorf("pod metrics: %w", err)
	}
	now := time.Now()
	var out []control.PodReading
	for name, l := range limits {
		u, ok := usage[name]
		if !ok {
			continue // no metrics yet: the pod's login probes for itself
		}
		out = append(out, control.PodReading{Pod: l.pod, Reading: podReading(l, u, now)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Pod < out[j].Pod })
	if len(out) > control.MaxClusterReadings {
		out = out[:control.MaxClusterReadings]
	}
	cr.Pods = out
	return cr, nil
}

// clusterReadingsLoop sends the cluster's readings up the ops link until the
// link ends. A failed read is one log line per change of error, never the link.
func (a *Agent) clusterReadingsLoop(ctx context.Context, conn nodeLink) {
	if a.cfg.FleetClusterOps == "" {
		return
	}
	every := a.clusterReadingEvery
	if every <= 0 {
		every = control.ClusterReadingEvery
	}
	t := time.NewTicker(every)
	defer t.Stop()
	lastErr := ""
	for {
		rctx, cancel := context.WithTimeout(ctx, every)
		cr, err := a.readClusterReadings(rctx)
		cancel()
		if err != nil {
			if err.Error() != lastErr {
				log.Printf("cluster readings: %v", err)
			}
			lastErr = err.Error()
		} else {
			lastErr = ""
			if m, err := control.New(control.TypeClusterReadings, cr); err == nil {
				wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
				err = conn.write(wctx, m)
				cancel()
				if err != nil {
					return
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// clusterReadingCapable: a login of a user pod, run as itself.
func (a *Agent) clusterReadingCapable() bool {
	return a.cfg.Fleet && os.Getenv("FLEET_USER_POD") == "1" && os.Geteuid() != 0
}

// clusterReadingPath is this login's $FLEET_CONF_DIR/cluster/machine.json.
func (a *Agent) clusterReadingPath() string {
	if a.cfg.FleetConfDir != "" {
		return filepath.Join(a.cfg.FleetConfDir, "cluster", "machine.json")
	}
	return filepath.Join(a.cfg.Home, ".config", "claude-fleet", "cluster", "machine.json")
}

// renderMachineReading is bin/fleet-machine-tasks.py's render, byte for byte:
// one key per line, the shell reader's shape.
func renderMachineReading(r control.MachineReading) []byte {
	q := func(s string) string { b, _ := json.Marshal(s); return string(b) }
	return []byte(fmt.Sprintf("{\n\"v\": %d,\n\"ts\": %d,\n\"mem_probe\": %s,\n\"mem_total_mb\": %s,\n\"load_per_core\": %s\n}\n",
		r.V, r.TS, q(r.MemProbe), q(r.MemTotalMB), q(r.LoadPerCore)))
}

// handleClusterReading writes the hub's reading of this pod.
func (a *Agent) handleClusterReading(m control.Message) {
	if !a.clusterReadingCapable() {
		return
	}
	var cr control.ClusterReading
	if err := json.Unmarshal(m.Payload, &cr); err != nil || !cr.Reading.Valid() {
		return
	}
	if err := writeFileAtomic(a.clusterReadingPath(), renderMachineReading(cr.Reading)); err != nil {
		log.Printf("cluster reading: %v", err)
	}
}

// writeFileAtomic writes path 0644 through a fresh temporary file and one
// rename; its directory is made 0755 when missing. Never through a link.
func writeFileAtomic(path string, b []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".machine.json.")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
