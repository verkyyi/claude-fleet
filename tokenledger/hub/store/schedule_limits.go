package store

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

// ScheduleLimits is one owner's schedule budget, counted across all their logins.
// Concurrency (one running at a time) and the minimum hourly interval are not
// part of it: those stay the same for everyone.
type ScheduleLimits struct {
	Tasks       int `json:"tasks"`
	DailySlots  int `json:"daily_slots"`
	DailyStarts int `json:"daily_starts"`
}

// DefaultScheduleLimits is the documented policy every owner gets unless the hub's
// operator raised theirs (CCQUOTA_FLEET_SCHEDULE_LIMITS, task PVG9).
var DefaultScheduleLimits = ScheduleLimits{Tasks: schedule.MaxTasks, DailySlots: schedule.MaxDailySlots, DailyStarts: schedule.MaxDailyStarts}

// The highest an override may go: a typo must not hand anyone an unbounded
// budget. One hourly task is 24 slots a day, so 20 of them is 480.
const (
	ScheduleCapTasks       = 100
	ScheduleCapDailySlots  = 480
	ScheduleCapDailyStarts = 500
)

// ScheduleOverrides maps an owner principal (gh:<id> · p:<uuid>) to its limits.
type ScheduleOverrides map[string]ScheduleLimits

// For is the limits that apply to owner: its override, else Defaults.
func (o ScheduleOverrides) For(owner string) ScheduleLimits {
	if l, ok := o[owner]; ok && owner != "" {
		return l
	}
	return DefaultScheduleLimits
}

// ParseScheduleOverrides reads {"<owner>":{"tasks":N,"daily_slots":N,"daily_starts":N}}.
// A field left out keeps its default. Empty input is no overrides. Any bad
// entry (unknown field, a non-positive or over-cap number, an empty owner)
// rejects the whole value, so a half-applied config never ships.
func ParseScheduleOverrides(raw string) (ScheduleOverrides, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	var in map[string]json.RawMessage
	if e := json.Unmarshal([]byte(raw), &in); e != nil {
		return nil, fmt.Errorf("not a JSON object: %w", e)
	}
	out := ScheduleOverrides{}
	for owner, body := range in {
		key := strings.TrimSpace(owner)
		if key == "" || key != owner {
			return nil, fmt.Errorf("owner %q: must be a principal without spaces", owner)
		}
		var f struct {
			Tasks       *int `json:"tasks"`
			DailySlots  *int `json:"daily_slots"`
			DailyStarts *int `json:"daily_starts"`
		}
		dec := json.NewDecoder(bytes.NewReader(body))
		dec.DisallowUnknownFields()
		if e := dec.Decode(&f); e != nil {
			return nil, fmt.Errorf("owner %q: %w", owner, e)
		}
		l := DefaultScheduleLimits
		for _, x := range []struct {
			name string
			v    *int
			cap  int
			dst  *int
		}{{"tasks", f.Tasks, ScheduleCapTasks, &l.Tasks}, {"daily_slots", f.DailySlots, ScheduleCapDailySlots, &l.DailySlots}, {"daily_starts", f.DailyStarts, ScheduleCapDailyStarts, &l.DailyStarts}} {
			if x.v == nil {
				continue
			}
			if *x.v < 1 || *x.v > x.cap {
				return nil, fmt.Errorf("owner %q: %s must be 1..%d, got %d", owner, x.name, x.cap, *x.v)
			}
			*x.dst = *x.v
		}
		out[owner] = l
	}
	return out, nil
}
