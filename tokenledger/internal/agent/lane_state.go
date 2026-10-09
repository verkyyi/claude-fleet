package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A tenant's lane state (claude-fleet#2501): the hub refusing a login's hello
// on the machine link with WRONG_LOGIN — a token reissued away, an endpoint
// retired — is not a network blip the reconnect ladder outlives; it needs the
// operator. The tenant says so in <StateDir>/lane.json, which
// `fleet-node-supervisor.py status` reads (令牌失效 · 需要 relogin), and
// removes it the moment a hello is welcomed again; the machine link's own
// heartbeat carries the same (Heartbeat.LoginsRefused) to the hub.

// laneStateFile is the file's name under the tenant's StateDir.
const laneStateFile = "lane.json"

// LaneState is lane.json.
type LaneState struct {
	State string `json:"state"` // "refused"
	Code  string `json:"code"`
	Why   string `json:"why"`
	Since string `json:"since"` // RFC 3339, the first refusal of this streak
}

// laneRefused records a refused login hello; a repeat keeps the first time.
func (a *Agent) laneRefused(e *control.Error) {
	if a.machine == nil || e == nil || e.Code != control.CodeWrongLogin {
		return
	}
	if a.cfg.RunAs != nil {
		a.machine.setRefused(a.cfg.RunAs.Login, e.Message)
	}
	if a.cfg.StateDir == "" {
		return
	}
	p := filepath.Join(a.cfg.StateDir, laneStateFile)
	st := LaneState{State: "refused", Code: e.Code, Why: e.Message, Since: time.Now().UTC().Format(time.RFC3339)}
	if b, err := os.ReadFile(p); err == nil {
		var old LaneState
		if json.Unmarshal(b, &old) == nil && old.State == st.State && old.Why == st.Why && old.Since != "" {
			return
		}
	}
	b, _ := json.Marshal(st)
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp, p)
}

// laneWelcomed clears lane.json: the lane is up again.
func (a *Agent) laneWelcomed() {
	if a.machine == nil {
		return
	}
	if a.cfg.RunAs != nil {
		a.machine.setRefused(a.cfg.RunAs.Login, "")
	}
	if a.cfg.StateDir == "" {
		return
	}
	_ = os.Remove(filepath.Join(a.cfg.StateDir, laneStateFile))
}
