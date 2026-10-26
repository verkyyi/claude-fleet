package api

import (
	"net/url"
	"strings"
)

// NodeURLKey is the hub's one machine-facing address (task PNWW, «moving the
// hub»): when set, every hello's welcome names it (control.Welcome.HubURL), and
// a machine that dialed another address checks the named one takes its OWN
// token for its OWN endpoint (/v1/node/self, the same endpoint_id on both) and
// then rewrites its configuration through its one writer, bin/fleet-hub-move.py,
// and reconnects there. Empty (the default) = nothing announced: byte for byte as
// before. An opt-in setting, never CCQUOTA_FLEET_PUBLIC_URL by itself: a machine
// that dials another name on purpose is not moved by a deploy.
const NodeURLKey = "fleet.node_url"

// nodeURLCheck: an https origin (scheme + host[:port]), nothing more.
func nodeURLCheck(_ *Server, v string) (string, string) {
	if u := canonNodeURL(v); u != "" {
		return u, ""
	}
	return "", NodeURLKey + " is an https origin (https://hub.example.com, no path), or \"\" for none"
}

// canonNodeURL is v as an announced address — https://host[:port], no user,
// path, query or fragment — or "" when it is not one.
func canonNodeURL(v string) string {
	v = strings.TrimRight(strings.TrimSpace(v), "/")
	u, err := url.Parse(v)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" ||
		u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" || strings.ContainsAny(v, " \t\r\n\"'\\") {
		return ""
	}
	return "https://" + strings.ToLower(u.Host)
}

// announcedNodeURL is what a welcome tells a machine to dial: the setting, or
// "" (no announcement).
func (s *Server) announcedNodeURL() string {
	return canonNodeURL(s.setting(NodeURLKey))
}
