package api

import (
	"testing"
	"time"
)

// Pod rolls start only inside fleet.user_pod_roll_window (task APVZ): UTC hours,
// across midnight too; "" or a bad value never stops them.
func TestUserPodRollWindow(t *testing.T) {
	at := func(h int) time.Time { return time.Date(2026, 11, 1, h, 30, 0, 0, time.UTC) }
	for _, c := range []struct {
		w    string
		h    int
		want bool
	}{
		{"", 3, true}, {"09-14", 9, true}, {"09-14", 13, true}, {"09-14", 14, false}, {"09-14", 8, false},
		{"22-05", 23, true}, {"22-05", 2, true}, {"22-05", 5, false}, {"22-05", 12, false}, {"junk", 12, true},
	} {
		if got := inRollWindow(c.w, at(c.h)); got != c.want {
			t.Errorf("inRollWindow(%q, %02d:30Z) = %v; want %v", c.w, c.h, got, c.want)
		}
	}
	for v, want := range map[string]string{"9-14": "09-14", " 22-5 ": "22-05", "": ""} {
		if got, why := checkRollWindow(nil, v); got != want || why != "" {
			t.Errorf("checkRollWindow(%q) = %q, %q; want %q", v, got, why, want)
		}
	}
	for _, bad := range []string{"9", "09-09", "25-03", "a-b"} {
		if _, why := checkRollWindow(nil, bad); why == "" {
			t.Errorf("checkRollWindow(%q) accepted", bad)
		}
	}
	h, ops, pods, rts, _ := rollRig(t, 1)
	rts[pods[0]] = podRuntime{SHA: rollOld}
	now := time.Now().UTC()
	setHubSetting(t, h.srv, UserPodRollWindowKey, checkWindowAround(now.Hour()+2))
	if got := h.srv.PodRollTick(now, true); got != nil {
		t.Fatalf("outside the window asked %v", got)
	}
	ops.quiet(200 * time.Millisecond)
	setHubSetting(t, h.srv, UserPodRollWindowKey, checkWindowAround(now.Hour()))
	if got := h.srv.PodRollTick(now, true); len(got) != 1 {
		t.Fatalf("inside the window asked %v", got)
	}
}

// checkWindowAround is a one-hour window starting at hour h (mod 24).
func checkWindowAround(h int) string {
	from := h % 24
	v, _ := checkRollWindow(nil, itoa2(from)+"-"+itoa2((from+1)%24))
	return v
}

func itoa2(n int) string { return string(rune('0'+n/10)) + string(rune('0'+n%10)) }
