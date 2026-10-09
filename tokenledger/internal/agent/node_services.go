package agent

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/user"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The machine link carries the machine daemon's login-level register
// (claude-fleet#2526, EPIC #2524 C2): fleet-node-supervisor.py writes a
// summary of every entry into its state.json (0644, `services`) — what it is,
// how it runs — and the link adds each log's last line, read here as root
// from the file the demoted service writes, only when that file is the
// login's own (a link or someone else's file is never read: the line reaches
// the login on the hub).

// supervisorService is one row of state.json's services[] (services_summary).
type supervisorService struct {
	Name      string   `json:"name"`
	Login     string   `json:"login"`
	Kind      string   `json:"kind"`
	Status    string   `json:"status"`
	Why       string   `json:"why"`
	Log       string   `json:"log"`
	Started   *float64 `json:"started"`
	NextStart *float64 `json:"next_start"`
	LastRun   any      `json:"last_run"` // a task's (#2529): epoch or ISO
	NextRun   any      `json:"next_run"`
	NextTry   any      `json:"next_try"`   // a retrying task's next attempt
	LastError string   `json:"last_error"` // a task's (#2529)
	Restarts  int      `json:"restarts"`
	LastRC    *int     `json:"last_rc"`
}

// readServices reads the register's summary from the supervisor's state
// file; nil when there is none (no daemon, an older one, an empty register).
func readServices(stateFile string) []control.ServiceStatus {
	if stateFile == "" {
		return nil
	}
	b, err := os.ReadFile(stateFile)
	if err != nil {
		return nil
	}
	var st struct {
		Services []supervisorService `json:"services"`
	}
	if json.Unmarshal(b, &st) != nil || len(st.Services) == 0 {
		return nil
	}
	out := make([]control.ServiceStatus, 0, len(st.Services))
	for _, r := range st.Services {
		if r.Name == "" || r.Login == "" {
			continue
		}
		s := control.ServiceStatus{Name: r.Name, Login: r.Login, Kind: r.Kind,
			State: serviceState(r.Status), Restarts: r.Restarts, LastRC: r.LastRC, Why: r.Why}
		if s.Kind == "" {
			s.Kind = "service"
		}
		s.StartedAt = epochTime(r.Started)
		s.LastRun = anyTime(r.LastRun)
		if s.LastRun == nil {
			s.LastRun = s.StartedAt
		}
		s.NextRun = anyTime(r.NextRun)
		switch {
		case s.State == "retrying" && anyTime(r.NextTry) != nil:
			s.NextRun = anyTime(r.NextTry)
		case s.NextRun == nil && s.State == "down":
			s.NextRun = epochTime(r.NextStart)
		}
		if s.Why == "" && (s.State == "failed" || s.State == "retrying") {
			s.Why = r.LastError
		}
		s.LastLogLine = serviceLogLine(r.Log, r.Login)
		out = append(out, s)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// serviceState folds the daemon's status into one word.
func serviceState(st string) string {
	switch st {
	case "":
		return "unknown"
	case "no such login":
		return "no_login"
	}
	return strings.ReplaceAll(st, " ", "_")
}

func epochTime(f *float64) *time.Time {
	if f == nil || *f <= 0 {
		return nil
	}
	t := time.Unix(0, int64(*f*1e9)).UTC()
	return &t
}

func anyTime(v any) *time.Time {
	switch x := v.(type) {
	case float64:
		return epochTime(&x)
	case string:
		if t, err := time.Parse(time.RFC3339, x); err == nil {
			t = t.UTC()
			return &t
		}
		if f, err := strconv.ParseFloat(x, 64); err == nil {
			return epochTime(&f)
		}
	}
	return nil
}

// serviceLogLine is the last non-blank line of path (at most
// control.ServiceLineMax bytes) — only a regular file login owns, opened
// without following a link; "" otherwise.
func serviceLogLine(path, login string) string {
	if path == "" || login == "" {
		return ""
	}
	u, err := user.Lookup(login)
	if err != nil {
		return ""
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return ""
	}
	f, fi, ok := openOwnedLog(path, uid)
	if !ok {
		return ""
	}
	defer f.Close()
	const window = 64 << 10
	off := fi.Size() - window
	if off < 0 {
		off = 0
	}
	buf, err := io.ReadAll(io.NewSectionReader(f, off, window))
	if err != nil {
		return ""
	}
	lines := bytes.Split(buf, []byte("\n"))
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimRight(string(lines[i]), "\r")
		if strings.TrimSpace(l) == "" {
			continue
		}
		return clipUTF8(l, control.ServiceLineMax)
	}
	return ""
}

// clipUTF8 cuts s to at most n bytes without splitting a character.
func clipUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return strings.ToValidUTF8(s[:n], "")
}
