package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// One person's pod (claude-fleet#3550, EPIC #3500 C5).

func TestUserPodLimitsParse(t *testing.T) {
	for in, want := range map[string]string{
		"":                                "cpu=2,memory=6Gi,disk=50Gi",
		"memory=8Gi":                      "cpu=2,memory=8Gi,disk=50Gi",
		" cpu=500m , disk=100Gi ":         "cpu=500m,memory=6Gi,disk=100Gi",
		"cpu=4,memory=16Gi,disk=1Ti":      "cpu=4,memory=16Gi,disk=1Ti",
		"cpu=250m,memory=1536Mi,disk=1Gi": "cpu=250m,memory=1536Mi,disk=1Gi",
	} {
		l, err := ParseUserPodLimits(in)
		if err != nil || l.String() != want {
			t.Errorf("ParseUserPodLimits(%q) = %q, %v; want %q", in, l.String(), err, want)
		}
	}
	for _, bad := range []string{"cpu=0", "cpu=100m", "memory=1Gi", "disk=512Mi", "gpu=1",
		"cpu=2.5", "memory=6GB", "cpu=", "memory=-1Gi"} {
		if _, err := ParseUserPodLimits(bad); err == nil {
			t.Errorf("ParseUserPodLimits(%q) accepted", bad)
		}
	}
}

func TestUserPodLimitsSetting(t *testing.T) {
	h := newFleetHarness(t)
	key := UserPodLimitsPrefix + "gh:1004"
	putSetting(t, h, key, "cpu=100m", http.StatusBadRequest)
	putSetting(t, h, key, "memory=8Gi", http.StatusOK)
	set, _ := h.srv.Store.FleetSettings()
	if set[key] != "cpu=2,memory=8Gi,disk=50Gi" {
		t.Fatalf("stored %q; want the full spelled value", set[key])
	}
	putSetting(t, h, key, "", http.StatusOK)
	if set, _ = h.srv.Store.FleetSettings(); set[key] != "" {
		t.Fatalf("an empty value keeps %q; want the default back", set[key])
	}
}

// A machine link that says CapUserPod is marked user_pod; every other row —
// a plain machine link, its logins — carries no such key, byte for byte.
func TestUserPodOffAddsNothing(t *testing.T) {
	h, _ := machineRig(t)
	h.enroll(t, "pod")
	identify(t, h, "pod", "u-drill1", "root")
	pod := dialMachine(t, h, h.tokens["pod"], control.CapUserPod)
	pod.beat("", control.Heartbeat{Hostname: "u-drill1", OSUser: "root", NCPU: 2, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "the pod's link online", func() bool {
		for _, v := range roster(t, h).Nodes {
			if v.EndpointID == "ep_pod" && v.Connected {
				return true
			}
		}
		return false
	})
	for _, v := range roster(t, h).Nodes {
		if want := v.EndpointID == "ep_pod"; v.UserPod != want {
			t.Fatalf("%s user_pod = %v; want %v", v.EndpointID, v.UserPod, want)
		}
		if v.EndpointID != "ep_pod" {
			raw, _ := json.Marshal(v)
			var m map[string]any
			_ = json.Unmarshal(raw, &m)
			if _, ok := m["user_pod"]; ok {
				t.Fatalf("%s carries user_pod: %s", v.EndpointID, raw)
			}
		}
	}
}
