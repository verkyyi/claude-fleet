package api

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// One person's pod (claude-fleet#3550, EPIC #3500 C5).
//
// A pod is a machine to the hub: its machine link lists CapUserPod and its
// hostname is the pod's stable u-<nonce>. Its ceiling is the person's, kept as
// the fleet setting fleet.user_pod_limits.<principal> in the same text
// extras/managed-node/render.py --limits takes, so the provisioner hands the
// setting to the template unchanged; changing it re-renders that person's
// Deployment alone. No setting = the template's default. Nothing here is read
// by placement or the roster's status: off is byte for byte as before.

// UserPodLimitsPrefix keys a person's pod ceiling.
const UserPodLimitsPrefix = "fleet.user_pod_limits."

// UserPodLimits is a pod ceiling. The defaults and the floors are the
// template's (render.py USER_POD_LIMITS / USER_POD_REQUESTS): a ceiling under
// what an idle pod is promised is refused.
type UserPodLimits struct {
	CPU    string
	Memory string
	Disk   string
}

// DefaultUserPodLimits is render.py's USER_POD_LIMITS.
var DefaultUserPodLimits = UserPodLimits{CPU: "2", Memory: "6Gi", Disk: "50Gi"}

var (
	userPodCPURE   = regexp.MustCompile(`^([1-9][0-9]{0,2}|[1-9][0-9]{0,5}m)$`)
	userPodBytesRE = regexp.MustCompile(`^[1-9][0-9]{0,5}(Mi|Gi|Ti)$`)
)

const (
	userPodCPUFloorMilli = 250  // render.py USER_POD_REQUESTS cpu
	userPodMemFloorMi    = 1536 // …and memory
	userPodDiskFloorMi   = 1024
)

func userPodMilli(q string) int {
	if strings.HasSuffix(q, "m") {
		n, _ := strconv.Atoi(q[:len(q)-1])
		return n
	}
	n, _ := strconv.Atoi(q)
	return n * 1000
}

func userPodMebi(q string) int {
	n, _ := strconv.Atoi(q[:len(q)-2])
	return n * map[string]int{"Mi": 1, "Gi": 1024, "Ti": 1024 * 1024}[q[len(q)-2:]]
}

// ParseUserPodLimits reads "cpu=2,memory=6Gi,disk=50Gi" (any subset; the
// rest the default).
func ParseUserPodLimits(text string) (UserPodLimits, error) {
	l := DefaultUserPodLimits
	for _, part := range strings.Split(text, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		k, v, _ := strings.Cut(part, "=")
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch k {
		case "cpu":
			if !userPodCPURE.MatchString(v) {
				return l, fmt.Errorf("a pod's cpu is cores (2) or millicores (500m), not %q", v)
			}
			l.CPU = v
		case "memory", "disk":
			if !userPodBytesRE.MatchString(v) {
				return l, fmt.Errorf("a pod's %s is N followed by Mi, Gi or Ti, not %q", k, v)
			}
			if k == "memory" {
				l.Memory = v
			} else {
				l.Disk = v
			}
		default:
			return l, fmt.Errorf("a pod's ceiling is cpu=…,memory=…,disk=…; not %q", k)
		}
	}
	switch {
	case userPodMilli(l.CPU) < userPodCPUFloorMilli:
		return l, fmt.Errorf("cpu=%s is under what an idle pod is promised (250m)", l.CPU)
	case userPodMebi(l.Memory) < userPodMemFloorMi:
		return l, fmt.Errorf("memory=%s is under what an idle pod is promised (1536Mi)", l.Memory)
	case userPodMebi(l.Disk) < userPodDiskFloorMi:
		return l, fmt.Errorf("disk=%s: at least 1Gi", l.Disk)
	}
	return l, nil
}

// String is the stored form, every key spelled.
func (l UserPodLimits) String() string {
	return "cpu=" + l.CPU + ",memory=" + l.Memory + ",disk=" + l.Disk
}
