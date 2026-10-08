package agent

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"time"
)

// credSink takes one leased credential file's bytes in place of the file
// (claude-fleet#1971). kind is "claude" or "codex"; label is the account
// label ("default" = ~/.codex).
type credSink func(kind, label string, data []byte) error

// credSink is nil — write the files, as always — unless this agent was
// started separated (FleetCredStore names the credential proxy's control
// socket), when every credential goes to the proxy, which runs as its own
// role account and keeps it where no session of this login can read it.
func (a *Agent) credSink() credSink {
	if a.cfg.FleetCredStore == "" {
		return nil
	}
	as := ""
	if a.cfg.RunAs != nil {
		// A machine tenant runs as root (claude-fleet#2333): the shared
		// proxy answers root only for the login it names.
		as = a.cfg.RunAs.Login
	}
	return credStoreSink(a.cfg.FleetCredStore, as)
}

// credStoreSink sends one `store` request to the proxy's control socket and
// waits for its answer: {"op":"store","kind","label","data":<base64>}\n →
// {"ok":true}\n. The proxy checks this end's uid (LOCAL_PEERCRED /
// SO_PEERCRED), so only this login — or root — can hand it a credential.
func credStoreSink(sock, as string) credSink {
	return func(kind, label string, data []byte) error {
		c, err := net.DialTimeout("unix", sock, 10*time.Second)
		if err != nil {
			return err
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(30 * time.Second))
		m := map[string]string{
			"op": "store", "kind": kind, "label": label,
			"data": base64.StdEncoding.EncodeToString(data),
		}
		if as != "" {
			m["as"] = as
		}
		req, _ := json.Marshal(m)
		if _, err := c.Write(append(req, '\n')); err != nil {
			return err
		}
		line, err := bufio.NewReader(c).ReadBytes('\n')
		if err != nil && len(line) == 0 {
			return err
		}
		var res struct {
			OK  bool   `json:"ok"`
			Err string `json:"err"`
		}
		if err := json.Unmarshal(line, &res); err != nil {
			return err
		}
		if !res.OK {
			return errors.New("credential store: " + res.Err)
		}
		return nil
	}
}
