package control

import "testing"

// Two shapes, deliberately (claude-fleet#1458): a login the hub may CREATE
// starts with a letter; a login the operator may NAME (adopt, map, certify)
// may also start with a digit, because `24haowan` exists. Both are lowercase
// letters and digits only, and neither is a reserved name.
func TestValidLoginShapes(t *testing.T) {
	for s, want := range map[string][2]bool{ // create, existing
		"verkyyi":           {true, true},
		"zhangsan2":         {true, true},
		"24haowan":          {false, true},
		"u0":                {true, true},
		"a":                 {false, false},
		"root":              {false, false},
		"shared":            {false, false},
		"24-haowan":         {false, false},
		"Verkyyi":           {false, false},
		"zhang.san":         {false, false},
		"-x":                {false, false},
		"abcdefghijklmnopq": {false, false}, // 17
		"abcdefghijklmnop":  {true, true},   // 16
		"":                  {false, false},
	} {
		if got := ValidLogin(s); got != want[0] {
			t.Errorf("ValidLogin(%q) = %v, want %v", s, got, want[0])
		}
		if got := ValidExistingLogin(s); got != want[1] {
			t.Errorf("ValidExistingLogin(%q) = %v, want %v", s, got, want[1])
		}
	}
}

// A create op makes a minted login (ValidLogin), or — marked existing — a
// second machine's copy of a login the hub already holds: a leading digit is
// fine there, an all-digit name never (claude-fleet#2105).
func TestValidCreateLogin(t *testing.T) {
	for s, want := range map[string][2]bool{ // minted, existing
		"verkyyi":   {true, true},
		"24haowan":  {false, true},
		"2468":      {false, false},
		"root":      {false, false},
		"24-haowan": {false, false},
		"a":         {false, false},
	} {
		if got := ValidCreateLogin(s, false); got != want[0] {
			t.Errorf("ValidCreateLogin(%q, false) = %v, want %v", s, got, want[0])
		}
		if got := ValidCreateLogin(s, true); got != want[1] {
			t.Errorf("ValidCreateLogin(%q, true) = %v, want %v", s, got, want[1])
		}
	}
}
