package api

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Browser terminals through the nearest door (XX79). fleet.term_doors lists the
// doors a browser may take a terminal's payload through: each a pipe URL, the
// endpoint whose token the door runs with (its tickets are signed with that
// token's hash, which only the hub and the door hold) and what the page calls
// it. The browser measures each against the hub and picks; admission, leases
// and the selection never leave the hub. Unset = no door offered: the config
// a browser gets is byte for byte as before.
const TermDoorsKey = "fleet.term_doors"

// termDoor is one fleet.term_doors entry.
type termDoor struct {
	ID       string `json:"id"`
	URL      string `json:"url"`
	Endpoint string `json:"endpoint"`
	Label    string `json:"label,omitempty"`
}

func parseTermDoors(v string) ([]termDoor, error) {
	v = strings.TrimSpace(v)
	if v == "" || v == noneValue {
		return nil, nil
	}
	var out []termDoor
	if err := json.Unmarshal([]byte(v), &out); err != nil {
		return nil, fmt.Errorf("%s: a JSON list of {id, url, endpoint, label}: %v", TermDoorsKey, err)
	}
	seen := map[string]bool{}
	for _, d := range out {
		switch {
		case !control.ValidDoorID(d.ID):
			return nil, fmt.Errorf("%s: %q is not a door id (a-z0-9-)", TermDoorsKey, d.ID)
		case seen[d.ID]:
			return nil, fmt.Errorf("%s: door %q twice", TermDoorsKey, d.ID)
		case !control.ValidDoorPipeURL(d.URL):
			return nil, fmt.Errorf("%s: %q is not wss://host%s", TermDoorsKey, d.URL, control.DoorPipePath)
		case d.Endpoint == "" || len(d.Endpoint) > 128 || strings.ContainsAny(d.Endpoint, " \t\r\n/"):
			return nil, fmt.Errorf("%s: door %q names no endpoint", TermDoorsKey, d.ID)
		case len(d.Label) > 32:
			return nil, fmt.Errorf("%s: door %q's label is longer than 32", TermDoorsKey, d.ID)
		}
		seen[d.ID] = true
	}
	if len(out) > 4 {
		return nil, fmt.Errorf("%s: at most 4 doors", TermDoorsKey)
	}
	return out, nil
}

func termDoorsCheck(_ *Server, v string) (string, string) {
	if _, err := parseTermDoors(v); err != nil {
		return "", err.Error()
	}
	return strings.TrimSpace(v), ""
}

// termDoors is the setting's doors (none on a bad value: the check refused it).
func (s *Server) termDoors() []termDoor {
	d, _ := parseTermDoors(s.setting(TermDoorsKey))
	return d
}

// browserDoors is what a browser is told: the pipe, its probe, its label.
func browserDoors(ds []termDoor) []control.TermDoor {
	var out []control.TermDoor
	for _, d := range ds {
		u, _ := url.Parse(d.URL)
		out = append(out, control.TermDoor{ID: d.ID, URL: d.URL, Probe: "https://" + u.Host + "/healthz", Label: d.Label})
	}
	return out
}

// doorTickets signs one pipe's two halves for door d.
func (s *Server) doorTickets(d termDoor, now time.Time) (pipe, browser, home string, err error) {
	key, err := s.Store.EndpointTokenHash(d.Endpoint)
	if err != nil || key == "" {
		return "", "", "", fmt.Errorf("door %s: no token on file", d.ID)
	}
	b := make([]byte, 18)
	_, _ = rand.Read(b)
	pipe = base64.RawURLEncoding.EncodeToString(b)
	t := control.DoorPipeTicket{V: 1, Door: d.ID, Pipe: pipe, Iat: now.Unix(), Exp: now.Add(control.DoorPipeTicketTTL).Unix()}
	t.Role = control.DoorPipeBrowser
	browser = control.SignDoorPipe(t, key)
	t.Role = control.DoorPipeHome
	home = control.SignDoorPipe(t, key)
	return pipe, browser, home, nil
}

// withDoorOrigins is a console policy plus exactly the doors' origins in
// connect-src (their pipe and their probe); no door = the policy itself.
func withDoorOrigins(policy string, ds []termDoor) string {
	if len(ds) == 0 {
		return policy
	}
	extra := ""
	for _, d := range ds {
		u, err := url.Parse(d.URL)
		if err != nil || u.Host == "" {
			continue
		}
		extra += " wss://" + u.Host + " https://" + u.Host
	}
	return strings.Replace(policy, "connect-src 'self'", "connect-src 'self'"+extra, 1)
}
