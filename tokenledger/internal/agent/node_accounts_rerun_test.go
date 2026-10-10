package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#2928: the machine's agent was restarted half way through a
// create (the login's .env it wrote), the hub asked the same op again, and the
// new process — with no book — ran fleet-login-new.sh a second time: exit 3,
// 「already exists」, recorded over the login the first run had made, whose
// services then ran on with nobody's record.

const rerunOp = "c15b9c43230eafe5f971f0dc15eff5d0"

// rerunScripts installs a fleet-login-new.sh that counts its runs and does
// what body says (sh, $1 = login, $MK = its mark), and a fleet-login-remove.sh
// that records its argv.
func rerunScripts(t *testing.T, home, body string) (newCount, removeLog string) {
	t.Helper()
	bin := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	newCount, removeLog = filepath.Join(home, "new.count"), filepath.Join(home, "remove.args")
	newSh := "#!/bin/sh\necho run >> '" + newCount + "'\nMK='" + home + "'/\"$1\"-onboard/op\n" + body + "\n"
	rmSh := "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done >> '" + removeLog + "'\necho >> '" + removeLog + "'\nexit 0\n"
	for name, b := range map[string]string{"fleet-login-new.sh": newSh, "fleet-login-remove.sh": rmSh} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(b), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return newCount, removeLog
}

func runs(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return strings.Count(string(b), "run\n")
}

func writeMark(t *testing.T, home, login, body string) {
	t.Helper()
	dir := filepath.Join(home, login+"-onboard")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "op"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func rerunAgent(t *testing.T, exists func(string) bool) *Agent {
	t.Helper()
	old, oldAlive, oldPoll := accountLoginExists, accountPIDAlive, accountMarkPoll
	accountLoginExists = exists
	accountMarkPoll = 10 * time.Millisecond
	t.Cleanup(func() { accountLoginExists, accountPIDAlive, accountMarkPoll = old, oldAlive, oldPoll })
	return &Agent{cfg: Config{Home: t.TempDir(), FleetAdmin: true}}
}

var createOp = control.AccountOp{Op: control.AccountCreate, Login: "drill1", FullName: "Drill"}

// The script is handed the op_id; the mark it leaves answers the same op
// arriving again — a success, never 「already exists」, never a second run.
func TestCreateArrivingTwiceIsAnsweredFromItsFirstRun(t *testing.T) {
	made := false
	a := rerunAgent(t, func(string) bool { return made })
	newCount, removeLog := rerunScripts(t, a.cfg.Home, `
[ -e "$MK" ] && { echo "login $1 already exists — refusing"; exit 3; }
[ -n "$FLEET_LOGIN_OP_ID" ] || { echo no op id; exit 9; }
mkdir -p "$(dirname "$MK")"
printf 'op=%s\npid=%s\nstarted=2026-10-10T08:01:20Z\n' "$FLEET_LOGIN_OP_ID" "$$" > "$MK"
printf 'done=2026-10-10T08:02:16Z\nline=node: joined\nline=credsep: separated\n' >> "$MK"
echo "credsep: separated"`)

	first := a.runAccountOp(rerunOp, createOp)
	if !first.OK || first.Credsep != control.CredsepSeparated {
		t.Fatalf("first run = %+v", first)
	}
	made = true
	// a new process: no book, the same op again (the hub's re-ask)
	a.acct = accountOps{}
	again := a.runAccountOp(rerunOp, createOp)
	if !again.OK || again.Exists || again.Credsep != control.CredsepSeparated {
		t.Fatalf("same op again = %+v; want OK from the first run", again)
	}
	if !strings.Contains(again.Detail, "this op's own run") {
		t.Fatalf("detail %q does not say where the answer came from", again.Detail)
	}
	if n := runs(t, newCount); n != 1 {
		t.Fatalf("fleet-login-new.sh ran %d times; want once", n)
	}
	if _, err := os.Stat(removeLog); err == nil {
		t.Fatal("a successful create was rolled back")
	}
}

// Another op's login (or a login made by hand, no mark) is still 「already
// exists」: the script runs and refuses, nothing is removed.
func TestCreateOfSomeoneElsesLoginStillExists(t *testing.T) {
	a := rerunAgent(t, func(string) bool { return true })
	newCount, removeLog := rerunScripts(t, a.cfg.Home, "echo exists; exit 3")
	writeMark(t, a.cfg.Home, createOp.Login, "op=0123456789abcdef\npid=1\ndone=x\nline=credsep: separated\n")
	res := a.runAccountOp(rerunOp, createOp)
	if res.OK || !res.Exists || res.Exit != 3 {
		t.Fatalf("result %+v; want exists (exit 3)", res)
	}
	if runs(t, newCount) != 1 {
		t.Fatal("the script did not decide")
	}
	if _, err := os.Stat(removeLog); err == nil {
		t.Fatal("someone else's login was removed")
	}
}

// This op's run stopped half way (the process gone, no done=): the login is
// taken back — remove, home kept — and the op answers failed, saying so.
func TestCreateCutOffHalfWayIsRolledBack(t *testing.T) {
	a := rerunAgent(t, func(string) bool { return true })
	accountPIDAlive = func(int) bool { return false }
	newCount, removeLog := rerunScripts(t, a.cfg.Home, "exit 3")
	writeMark(t, a.cfg.Home, createOp.Login, "op="+rerunOp+"\npid=424242\nstarted=2026-10-10T08:01:20Z\n")
	res := a.runAccountOp(rerunOp, createOp)
	if res.OK || res.Exists {
		t.Fatalf("result %+v; want a failure that is not 「exists」", res)
	}
	if !strings.Contains(res.Detail, "rolled back") {
		t.Fatalf("detail %q does not say it was rolled back", res.Detail)
	}
	if runs(t, newCount) != 0 {
		t.Fatal("fleet-login-new.sh ran again")
	}
	got, _ := os.ReadFile(removeLog)
	if strings.TrimSpace(string(got)) != "[drill1][--keep-home][--apply]" {
		t.Fatalf("remove argv %q", got)
	}
}

// This op's run is still going (survived its agent): waited for, then its
// result is the answer.
func TestCreateStillRunningIsWaitedFor(t *testing.T) {
	a := rerunAgent(t, func(string) bool { return true })
	newCount, removeLog := rerunScripts(t, a.cfg.Home, "exit 3")
	writeMark(t, a.cfg.Home, createOp.Login, "op="+rerunOp+"\npid=777\nstarted=s\n")
	polls := 0
	accountPIDAlive = func(int) bool {
		polls++
		if polls == 3 {
			writeMark(t, a.cfg.Home, createOp.Login, "op="+rerunOp+"\npid=777\nstarted=s\ndone=d\nline=credsep: separated\n")
		}
		return true
	}
	res := a.runAccountOp(rerunOp, createOp)
	if !res.OK || res.Credsep != control.CredsepSeparated {
		t.Fatalf("result %+v; want the first run's success", res)
	}
	if runs(t, newCount) != 0 {
		t.Fatal("fleet-login-new.sh ran while the first run still did")
	}
	if _, err := os.Stat(removeLog); err == nil {
		t.Fatal("a running create was rolled back")
	}
}

// A first run that fails after it made the login (a step after sysadminctl)
// leaves no live login: it is taken back at once.
func TestCreateFailingAfterMakingTheLoginIsRolledBack(t *testing.T) {
	made := false
	a := rerunAgent(t, func(string) bool { return made })
	accountPIDAlive = func(int) bool { return false }
	_, removeLog := rerunScripts(t, a.cfg.Home, `
mkdir -p "$(dirname "$MK")"
printf 'op=%s\npid=%s\n' "$FLEET_LOGIN_OP_ID" "$$" > "$MK"
echo "FAILED at step 7"; exit 1`)
	// the script made the login before it failed
	accountLoginExists = func(string) bool { made = true; return true }
	res := a.runAccountOp(rerunOp, createOp)
	if res.OK || res.Exit != 1 || !strings.Contains(res.Detail, "rolled back") {
		t.Fatalf("result %+v; want exit 1 and rolled back", res)
	}
	if b, _ := os.ReadFile(removeLog); !strings.Contains(string(b), "[drill1][--keep-home]") {
		t.Fatalf("remove argv %q", b)
	}
}

// A create a restart cut off whose own run finished: the new process answers
// it from the mark (OK), not 「the login exists but may be half made」.
func TestRestartSettlesItsOwnCreateFromTheMark(t *testing.T) {
	a := rerunAgent(t, func(string) bool { return true })
	path := filepath.Join(t.TempDir(), accountOpsFile)
	var o1 accountOps
	o1.load(path)
	o1.claim(rerunOp, createOp)
	writeMark(t, a.cfg.Home, createOp.Login, "op="+rerunOp+"\npid=1\nstarted=s\ndone=d\nline=credsep: separated\n")

	a.acct = accountOps{home: a.cfg.Home}
	a.acct.load(path)
	if _, owed := a.acct.outbox[rerunOp]; owed {
		t.Fatal("answered as cut off before reading the mark")
	}
	if f, ok := a.acct.inflight[rerunOp]; !ok || f.PID != os.Getpid() {
		t.Fatalf("inflight %+v; want it held by this process while it settles", a.acct.inflight)
	}
	a.resumeAccountOps()
	m, ok := a.acct.outbox[rerunOp]
	if !ok {
		t.Fatal("no result owed after settling")
	}
	var res control.AccountResult
	if err := json.Unmarshal(m.Payload, &res); err != nil {
		t.Fatal(err)
	}
	if !res.OK || res.Credsep != control.CredsepSeparated {
		t.Fatalf("settled result %+v; want OK separated", res)
	}
	if len(a.acct.inflight) != 0 {
		t.Fatalf("still inflight: %v", a.acct.inflight)
	}
}

// The op_id rides the create's environment (hex only), never a remove's.
func TestAccountEnvCarriesTheOpID(t *testing.T) {
	env := strings.Join(accountEnv("", rerunOp, createOp), "\n")
	if !strings.Contains(env, "FLEET_LOGIN_OP_ID="+rerunOp) {
		t.Fatal("no op id in a create's environment")
	}
	if accountEnv("", "op-1", createOp) != nil {
		t.Fatal("a non-hex op id was handed on")
	}
	if accountEnv("", rerunOp, control.AccountOp{Op: control.AccountRemove, Login: "x"}) != nil {
		t.Fatal("a remove got an environment")
	}
}
