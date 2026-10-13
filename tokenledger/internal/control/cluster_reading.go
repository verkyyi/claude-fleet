package control

import (
	"regexp"
	"time"
)

// A cluster's readings (claude-fleet#3734, EPIC #3500 C1's cloud half).
//
// On a managed machine the node daemon reads memory and load ONCE and every
// login reads the file (cluster/machine.json, #3546). In a cluster the machine
// is a person's pod, and its reading is the pod's own — its fleet container's
// use against its own limits, never the host's /proc — which only the
// cluster's fleet-ops can see (metrics.k8s.io, read-only). So fleet-ops sends
// every user pod's reading up its ops link, and the hub hands each pod its
// own, as the same file, into its login's $FLEET_CONF_DIR/cluster/.
//
//	fleet-ops ──TypeClusterReadings {pods: [{pod, reading}]}──▶ hub
//	hub ──TypeClusterReading {reading}──▶ that pod's login (CapClusterReading)
//
// The hub takes a reading only from a link that listed CapClusterOps, only for
// a pod fleet_cluster_pods puts in THAT cluster, and sends it only to links on
// that pod. A login that never lists CapClusterReading is sent nothing.
const (
	TypeClusterReadings = "cluster_readings"
	TypeClusterReading  = "cluster_reading"
	CapClusterReading   = "cluster_reading"
)

// ClusterReadingEvery is how often fleet-ops reads its cluster — the node
// daemon's machine-reading cadence.
const ClusterReadingEvery = 15 * time.Second

// MaxClusterReadings bounds one TypeClusterReadings (a cluster's pods).
const MaxClusterReadings = 500

// MachineReading is the file cluster/machine.json, field for field
// (bin/fleet-machine-tasks.py render): every value a string a shell reader
// takes as it is, empty = no answer (the reader probes for itself).
type MachineReading struct {
	V           int    `json:"v"`
	TS          int64  `json:"ts"`
	MemProbe    string `json:"mem_probe"`
	MemTotalMB  string `json:"mem_total_mb"`
	LoadPerCore string `json:"load_per_core"`
}

// readingValueRE is what a value may hold: it travels into awk and the shell.
var readingValueRE = regexp.MustCompile(`^[0-9. ]{0,64}$`)

// Valid says the reading is one a login may be handed: version 1, a time,
// and no value that is not digits, dots and spaces.
func (r MachineReading) Valid() bool {
	return r.V == 1 && r.TS > 0 && readingValueRE.MatchString(r.MemProbe) &&
		readingValueRE.MatchString(r.MemTotalMB) && readingValueRE.MatchString(r.LoadPerCore)
}

// PodReading is one pod's reading in a TypeClusterReadings.
type PodReading struct {
	Pod     string         `json:"pod"`
	Reading MachineReading `json:"reading"`
}

// ClusterReadings is TypeClusterReadings' payload.
type ClusterReadings struct {
	Pods []PodReading `json:"pods"`
}

// ClusterReading is TypeClusterReading's payload: the pod's own reading.
type ClusterReading struct {
	Reading MachineReading `json:"reading"`
}
