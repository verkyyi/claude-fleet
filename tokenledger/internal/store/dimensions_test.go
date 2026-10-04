package store

import (
	"strings"
	"testing"
)

// Dimensions and column() are two lists of the same thing, and the whole point
// of the exported one is that other packages can trust it. If a new axis is
// added to the switch and not to the slice, every surface generated from
// Dimensions silently keeps offering the old set -- which is exactly the drift
// issue #60 was filed about, one layer down.
func TestDimensionsMatchesTheColumnWhitelist(t *testing.T) {
	seen := map[Dimension]bool{}
	for _, d := range Dimensions {
		if seen[d] {
			t.Errorf("Dimensions lists %q twice", d)
		}
		seen[d] = true
		col, err := d.column()
		if err != nil {
			t.Errorf("Dimensions lists %q, which column() rejects: %v", d, err)
		}
		if col == "" {
			t.Errorf("%q maps to an empty column", d)
		}
	}

	// The other direction: a dimension the switch knows but the slice does not.
	// There is no reflection over a switch, so this enumerates the string
	// constants the package declares -- a new one has to be added here too,
	// which is the point at which someone notices the slice.
	for _, d := range []Dimension{
		BySource, ByAccount, ByEndpoint, ByProject, BySession, ByModel,
		ByProvider, ByBranch, ByUser, ByTeam, ByEffort, ByEntrypoint,
	} {
		if !seen[d] {
			t.Errorf("column() accepts %q but Dimensions does not list it", d)
		}
	}

	// An unknown axis must name the alternatives rather than only refusing:
	// a caller told its axis is unknown has to go and read the switch, one
	// handed the list can retry.
	_, err := Dimension("not-an-axis").column()
	if err == nil {
		t.Fatal(`column() accepted "not-an-axis"`)
	}
	for _, d := range Dimensions {
		if !strings.Contains(err.Error(), string(d)) {
			t.Errorf("the unknown-dimension error does not name %q: %v", d, err)
		}
	}
}
