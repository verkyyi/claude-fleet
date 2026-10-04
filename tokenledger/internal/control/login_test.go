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
