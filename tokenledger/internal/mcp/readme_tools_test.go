package mcp

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The README is the only place a stranger learns what this MCP server offers,
// and it has already drifted once: the account dimension added usage_by_account
// and list_account_switches, and the README went on advertising seven tools for
// several commits. Nobody notices a doc that is merely out of date, so pin it to
// the registration instead of to a reviewer's memory.

var readmeToolSentence = regexp.MustCompile(`(?s)\b([A-Z][a-z]+) read-only tools:(.*?)\.\n`)

var numberWords = map[int]string{
	1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven",
	8: "Eight", 9: "Nine", 10: "Ten", 11: "Eleven", 12: "Twelve",
}

func TestREADMEListsEveryRegisteredTool(t *testing.T) {
	raw, err := os.ReadFile("../../README.md")
	if err != nil {
		t.Fatalf("read README: %v", err)
	}

	m := readmeToolSentence.FindSubmatch(raw)
	if m == nil {
		t.Fatal(`no "<N> read-only tools: ..." sentence in README.md — ` +
			`if the wording moved, move this guard with it rather than deleting it`)
	}
	countWord, list := string(m[1]), string(m[2])

	documented := map[string]bool{}
	for _, q := range regexp.MustCompile("`([a-z_]+)`").FindAllStringSubmatch(list, -1) {
		documented[q[1]] = true
	}
	// A regex that quietly matches nothing would make every assertion below
	// vacuously true, so refuse an empty parse outright.
	if len(documented) == 0 {
		t.Fatal("parsed zero tool names out of the README sentence — the guard is not guarding")
	}

	registered := map[string]bool{}
	for _, s := range toolSpecs() {
		registered[s.Name] = true
	}

	var missing, extra []string
	for name := range registered {
		if !documented[name] {
			missing = append(missing, name)
		}
	}
	for name := range documented {
		if !registered[name] {
			extra = append(extra, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)

	if len(missing) > 0 {
		t.Errorf("registered but undocumented in README: %s", strings.Join(missing, ", "))
	}
	if len(extra) > 0 {
		t.Errorf("README advertises tools that are not registered: %s", strings.Join(extra, ", "))
	}
	if want := numberWords[len(registered)]; want != "" && countWord != want {
		t.Errorf("README says %q read-only tools, %d are registered (want %q)",
			countWord, len(registered), want)
	}
}
