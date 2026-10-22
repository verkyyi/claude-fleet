package api

import (
	"encoding/json"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// The producer login authorizes delivery; the existing node authentication and
// same-owner relay checks still apply. A sealed route never changes From/To and
// never becomes a task acceptance or a new historical parent link.
func checkReportDelegation(in control.Relay, obj map[string]json.RawMessage) error {
	raw, present := obj["report_delegation"]
	if !present {
		return nil
	}
	bad := func() error { return fault("INVALID_ARGUMENT", "invalid sealed report delegation") }
	var d struct {
		Reporter string `json:"reporter"`
		Parent   string `json:"original_parent"`
		Target   string `json:"target"`
		Chain    []struct {
			ID     string `json:"id"`
			Parent string `json:"parent"`
			Target string `json:"target"`
		} `json:"chain"`
	}
	var rid string
	if in.Kind != control.RelayChildReport || json.Unmarshal(raw, &d) != nil ||
		json.Unmarshal(obj["rid"], &rid) != nil || rid != in.ID ||
		d.Reporter != in.From || d.Target != in.To || len(d.Chain) == 0 || len(d.Chain) > 8 {
		return bad()
	}
	identity := func(wid string) bool {
		_, id, err := fleetid.ParseWorkerID(wid)
		return err == nil && fleetid.IsUUID(id)
	}
	if !identity(d.Reporter) || !identity(d.Parent) || !identity(d.Target) {
		return bad()
	}
	seen := map[string]bool{d.Reporter: true, d.Parent: true}
	parent := d.Parent
	for _, hop := range d.Chain {
		if !fleetid.IsUUID(hop.ID) || hop.Parent != parent || !identity(hop.Target) || seen[hop.Target] {
			return bad()
		}
		seen[hop.Target] = true
		parent = hop.Target
	}
	if parent != d.Target {
		return bad()
	}
	return nil
}
