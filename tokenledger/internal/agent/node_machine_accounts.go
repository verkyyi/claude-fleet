package agent

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A Linux managed machine opens its own logins (claude-fleet#3210, EPIC #3208
// C2). A Mac has an admin login with sudo whose agent runs the account ops; a
// Linux managed machine has none, so the machine's own node program — root —
// does, on its own half of the machine link. What it will do is as fixed as
// the admin agent's, and narrower:
//
//   - only where machine.env says FLEET_NODE_ACCOUNT_OPS=1 on Linux and the
//     root runtime has fleet-node-linux.py (MachineConfig.AccountOpener); then
//     the machine hello lists CapLoginJoin, else every account op is refused
//     NOT_ADMIN and logged;
//   - only `fleet-node-linux.py login open <login> [--full-name N]` and
//     `login remove <login> --keep-home|--delete-home`, the join code and the
//     op_id in its environment, never its argv;
//   - never the machine's service login, root or a reserved name — the
//     opener refuses a login it did not declare, too;
//   - the same book, one op at a time, each op_id at most once, a failed
//     create rolled back.

// linuxReserved are names the opener never makes or removes; fleet-node-linux.py
// RESERVED, plus root.
var linuxReserved = map[string]bool{"root": true, "admin": true, "daemon": true, "nobody": true,
	"guest": true, "shared": true, "fleetcred": true}

// validateLinuxAccountOp is validateAccountOp for the machine's own opener.
func validateLinuxAccountOp(op control.AccountOp, service string) error {
	if op.Op != control.AccountCreate && op.Op != control.AccountRemove {
		return errors.New("op must be create or remove")
	}
	// A digit may lead where the person already holds the name (`24haowan`,
	// EPIC #3208 共同约定 5): the opener passes useradd --badname for it.
	existing := op.Op == control.AccountRemove || op.Existing
	if !control.ValidCreateLogin(op.Login, existing) {
		return errors.New("login is not 2-16 lowercase letters and digits with at least one letter")
	}
	if linuxReserved[op.Login] {
		return errors.New("refusing a reserved login: " + op.Login)
	}
	if service == "" {
		service = "fleet"
	}
	if op.Login == service {
		return errors.New("refusing to touch this machine's service login " + service)
	}
	if op.JoinCode != "" && (op.Op != control.AccountCreate || !joinCodeRE.MatchString(op.JoinCode)) {
		return errors.New("join_code must be fj_ + 26 base32 characters, on a create")
	}
	if op.Op == control.AccountCreate && !control.ValidFullName(op.FullName) {
		return errors.New("full_name must be 1-64 printable characters")
	}
	return nil
}

// linuxAccountArgv is the ONE place the machine's account op argv is decided:
// python3 -I <opener> login open|remove …
func linuxAccountArgv(opener string, op control.AccountOp) (string, []string) {
	args := []string{"-I", opener, "login"}
	if op.Op == control.AccountRemove {
		keep := "--keep-home"
		if op.DropHome {
			keep = "--delete-home"
		}
		return serviceCtlPython, append(args, "remove", op.Login, keep)
	}
	args = append(args, "open", op.Login)
	if n := gecosName(op.FullName); n != "" {
		args = append(args, "--full-name", n)
	}
	return serviceCtlPython, args
}

// gecosName is the display name as a passwd comment holds it: no : or , (the
// field separators), trimmed; "" when nothing is left — the login opens
// without one.
func gecosName(n string) string {
	n = strings.Join(strings.Fields(strings.NewReplacer(":", " ", ",", " ").Replace(n)), " ")
	if !control.ValidFullName(n) {
		return ""
	}
	return n
}

// linuxDeclaredOp is the op_id fleet-node-linux.py wrote into login's
// declaration when that op's run made it; "" when none.
func linuxDeclaredOp(dir, login string) string {
	if dir == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(dir, login+".json"))
	if err != nil {
		return ""
	}
	var d struct {
		Op string `json:"op"`
	}
	if json.Unmarshal(b, &d) != nil {
		return ""
	}
	return d.Op
}

// newMachineAccounts is the machine half's account-op runner, or nil when the
// machine does not open its own logins (a Mac, or FLEET_NODE_ACCOUNT_OPS off).
func newMachineAccounts(mc MachineConfig) *Agent {
	if mc.AccountOpener == "" {
		return nil
	}
	a := &Agent{cfg: Config{HubURL: mc.HubURL, FleetAdmin: true, LinuxOpener: mc.AccountOpener,
		ServiceLogin: mc.ServiceLogin, LinuxTenants: mc.LinuxTenants}}
	if mc.AccountState != "" {
		a.cfg.StateDir = mc.AccountState
		a.acct.owns = a.ownsCreate
		a.acct.load(filepath.Join(mc.AccountState, accountOpsFile))
		if len(a.acct.resume) > 0 {
			go a.resumeAccountOps()
		}
	}
	return a
}

// machineAccountOp answers an account op on the machine's own half.
func (ml *machineLink) machineAccountOp(ctx context.Context, conn *websocket.Conn, m control.Message) {
	if ml.acct == nil {
		log.Printf("machine link: refused an account op %s: this machine does not open its own logins (FLEET_NODE_ACCOUNT_OPS is not 1)", m.OpID)
		e := control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto,
			Error: &control.Error{Code: control.CodeNotAdmin, Message: "this machine's node program does not open logins"}}
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = wsLink{conn}.write(wctx, e)
		return
	}
	ml.acct.handleAccountOp(ctx, wsLink{conn}, m)
}

// accountAttach hands the runner this connection's writer: results not acked
// go out again now. The returned func detaches it.
func (ml *machineLink) accountAttach(conn *websocket.Conn) func() {
	if ml.acct == nil {
		return func() {}
	}
	ml.acct.acct.attach(func(m control.Message) error {
		wctx, cancel := context.WithTimeout(context.Background(), nodeWriteTimeout)
		defer cancel()
		return wsLink{conn}.write(wctx, m)
	})
	return ml.acct.acct.detach
}
