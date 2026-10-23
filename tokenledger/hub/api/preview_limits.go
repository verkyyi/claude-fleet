package api

import (
	"encoding/json"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"strings"
	"time"
)

const PreviewLimitsKey = "fleet.preview_limits"

type previewLimitValues struct {
	Previews    int   `json:"previews,omitempty"`
	Connections int   `json:"connections,omitempty"`
	Lease       int   `json:"lease_seconds,omitempty"`
	Body        int64 `json:"body_bytes,omitempty"`
}
type previewPolicy struct {
	Default  previewLimitValues            `json:"default"`
	Accounts map[string]previewLimitValues `json:"accounts,omitempty"`
	Nodes    map[string]previewLimitValues `json:"nodes,omitempty"`
	Groups   map[string]previewLimitValues `json:"groups,omitempty"`
}
type previewBounds struct {
	previews, connections int
	lease                 time.Duration
	body                  int64
}

func previewPolicyCheck(_ *Server, v string) (string, string) {
	var p previewPolicy
	d := json.NewDecoder(strings.NewReader(v))
	d.DisallowUnknownFields()
	if len(v) > 16384 || d.Decode(&p) != nil {
		return "", "preview limits must be a JSON object with default/accounts/nodes/groups"
	}
	valid := func(x previewLimitValues) bool {
		return x.Previews >= 0 && x.Previews <= 3 && x.Connections >= 0 && x.Connections <= 32 && x.Lease >= 0 && x.Lease <= 7200 && x.Body >= 0 && x.Body <= 10<<20
	}
	if !valid(p.Default) {
		return "", "preview limits exceed V1 bounds"
	}
	for _, m := range []map[string]previewLimitValues{p.Accounts, p.Nodes, p.Groups} {
		for k, x := range m {
			if k == "" || !valid(x) {
				return "", "invalid preview scope or limits"
			}
		}
	}
	b, _ := json.Marshal(p)
	return string(b), ""
}
func (s *Server) previewLimits(p store.Preview) previewBounds {
	b := previewBounds{3, 32, 2 * time.Hour, 10 << 20}
	var policy previewPolicy
	if json.Unmarshal([]byte(s.setting(PreviewLimitsKey)), &policy) != nil {
		return b
	}
	apply := func(x previewLimitValues) {
		if x.Previews > 0 && x.Previews < b.previews {
			b.previews = x.Previews
		}
		if x.Connections > 0 && x.Connections < b.connections {
			b.connections = x.Connections
		}
		if x.Lease > 0 && time.Duration(x.Lease)*time.Second < b.lease {
			b.lease = time.Duration(x.Lease) * time.Second
		}
		if x.Body > 0 && x.Body < b.body {
			b.body = x.Body
		}
	}
	apply(policy.Default)
	apply(policy.Accounts[p.Owner])
	apply(policy.Nodes[p.Machine])
	// Groups use the existing endpoint allocation (team); no parallel group list.
	if ep, e := s.Store.EndpointByID(p.Endpoint); e == nil {
		apply(policy.Groups[ep.Team])
	}
	return b
}
