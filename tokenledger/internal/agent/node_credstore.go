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
		return credStoreCall(sock, as, map[string]string{
			"op": "store", "kind": kind, "label": label,
			"data": base64.StdEncoding.EncodeToString(data),
		})
	}
}

// credUnstore removes one account's copy from the proxy (claude-fleet#3043):
// {"op":"unstore","kind","label"} — THIS login's index entry and own copy
// only; a pool file another login still names stays. nil when not separated.
func (a *Agent) credUnstore() func(kind, label string) error {
	if a.cfg.FleetCredStore == "" {
		return nil
	}
	sock, as := a.cfg.FleetCredStore, ""
	if a.cfg.RunAs != nil {
		as = a.cfg.RunAs.Login
	}
	return func(kind, label string) error {
		return credStoreCall(sock, as, map[string]string{"op": "unstore", "kind": kind, "label": label})
	}
}

// credStoreCall is one request on the proxy's control socket.
func credStoreCall(sock, as string, m map[string]string) error {
	req := make(map[string]any, len(m))
	for k, v := range m {
		req[k] = v
	}
	_, err := credStoreAsk(sock, as, req)
	return err
}

// credStoreAsk is one request on the proxy's control socket -> its answer
// line, or an error when it could not be asked or said no.
func credStoreAsk(sock, as string, m map[string]any) ([]byte, error) {
	c, err := net.DialTimeout("unix", sock, 10*time.Second)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	if as != "" {
		m["as"] = as
	}
	req, _ := json.Marshal(m)
	if _, err := c.Write(append(req, '\n')); err != nil {
		return nil, err
	}
	line, err := bufio.NewReader(c).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return nil, err
	}
	var res struct {
		OK  bool   `json:"ok"`
		Err string `json:"err"`
	}
	if err := json.Unmarshal(line, &res); err != nil {
		return nil, err
	}
	if !res.OK {
		return nil, errors.New("credential store: " + res.Err)
	}
	return line, nil
}
