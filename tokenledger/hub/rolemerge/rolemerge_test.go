package rolemerge

import (
	"strings"
	"testing"
)

// Parse reads a subagent file's frontmatter (svc templates' name).
func TestParse(t *testing.T) {
	front, body, err := Parse("---\nname: reviewer\ntools:\n  - Read\n  - Grep\n---\nbody\n")
	if err != nil || body != "body\n" {
		t.Fatalf("%v %q", err, body)
	}
	if v, _ := front.Get("name"); v != "reviewer" {
		t.Fatalf("name %v", v)
	}
	if v, _ := front.Get("tools"); len(v.([]any)) != 2 {
		t.Fatalf("tools %v", v)
	}
	if _, _, err := Parse("---\nname: x\n"); err == nil {
		t.Fatal("no closing --- was read")
	}
}
