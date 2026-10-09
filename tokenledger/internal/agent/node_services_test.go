package agent

import (
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// claude-fleet#2526: the machine link's beat carries the daemon's register —
// a state per entry, its times, and the last line of a log its login owns.
func TestReadServicesFromSupervisorState(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no machine daemon on windows")
	}
	me, err := user.Current()
	if err != nil {
		t.Skip(err)
	}
	dir := t.TempDir()
	lg := filepath.Join(dir, "sms.log")
	long := strings.Repeat("长", 100) // 300 bytes
	if err := os.WriteFile(lg, []byte("first\nsent 3 texts\n"+long+"\n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dir, "link.log")
	if err := os.Symlink(lg, other); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(dir, "state.json")
	body := `{"version":1,"services":[
	 {"name":"sms","login":"` + me.Username + `","kind":"service","status":"running","log":"` + lg + `","started":1760000000.5,"restarts":2},
	 {"name":"push","login":"` + me.Username + `","kind":"service","status":"down","log":"` + other + `","started":1760000000,"next_start":1760000060,"last_rc":1},
	 {"name":"bad","login":"ghost","status":"invalid","why":"exec must be a non-empty list of strings"},
	 {"name":"gone","login":"ghost","status":"no such login"},
	 {"name":"daily","login":"` + me.Username + `","kind":"task","status":"failed","last_run":"2026-10-08T07:00:00Z","next_run":1760086800,"last_error":"window never opened"},
	 {"name":"retry","login":"` + me.Username + `","kind":"task","status":"retrying","last_run":1760000000,"next_run":1760086800,"next_try":1760000300}
	]}`
	if err := os.WriteFile(state, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readServices(state)
	if len(got) != 6 {
		t.Fatalf("services = %d, want 6: %+v", len(got), got)
	}
	sms, push, bad, gone, daily, retry := got[0], got[1], got[2], got[3], got[4], got[5]
	if sms.State != "running" || sms.Failed() || sms.Restarts != 2 || sms.StartedAt == nil || sms.LastRun == nil || sms.NextRun != nil {
		t.Errorf("sms = %+v", sms)
	}
	if len(sms.LastLogLine) > 200 || !strings.HasPrefix(sms.LastLogLine, "长") || len(sms.LastLogLine)%3 != 0 {
		t.Errorf("sms last line not clipped to whole characters ≤ 200 bytes: %d %q", len(sms.LastLogLine), sms.LastLogLine)
	}
	if push.State != "down" || !push.Failed() || push.NextRun == nil || push.NextRun.Unix() != 1760000060 || push.LastRC == nil || *push.LastRC != 1 {
		t.Errorf("push = %+v", push)
	}
	if push.LastLogLine != "" {
		t.Errorf("a log reached through a link was read: %q", push.LastLogLine)
	}
	if bad.State != "invalid" || !bad.Failed() || bad.Why == "" || bad.Kind != "service" {
		t.Errorf("bad = %+v", bad)
	}
	if gone.State != "no_login" || !gone.Failed() {
		t.Errorf("gone = %+v", gone)
	}
	if daily.Kind != "task" || !daily.Failed() || daily.LastRun == nil || daily.LastRun.Hour() != 7 || daily.NextRun == nil || daily.Why != "window never opened" {
		t.Errorf("daily = %+v", daily)
	}
	if retry.Failed() || retry.NextRun == nil || retry.NextRun.Unix() != 1760000300 {
		t.Errorf("a retrying task is not failed yet, its next run is its next try: %+v", retry)
	}
	if readServices(filepath.Join(dir, "none.json")) != nil || readServices("") != nil {
		t.Error("no state file must report no services")
	}
	_ = os.WriteFile(state, []byte(`{"version":1,"services":[]}`), 0o644)
	if readServices(state) != nil {
		t.Error("an empty register must report nil")
	}
	if hb := machineHeartbeat("v", nil, state); hb.Services != nil {
		t.Errorf("beat services = %+v", hb.Services)
	}
}
