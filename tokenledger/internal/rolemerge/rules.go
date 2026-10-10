package rolemerge

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// The rule table (bin/fleet_rules.py, claude-fleet#2786): 自带 < 你的 < 本机,
// merged by number. The hub holds the first two — the stable tree's
// conf/role-rules.default.md and the person bundle's `rules`.

// RuleNewFrom is where a layer's new rule numbers start.
const RuleNewFrom = 100

// Tiers are a rule's 档位.
var Tiers = []string{"auto", "default", "ask", "off"}

var (
	ruleHead    = "编号"
	ruleClassRE = regexp.MustCompile(`never:(rule|money|publish)`)
	ruleWordSep = regexp.MustCompile(`[,，、]`)
)

// Rule is one row.
type Rule struct {
	N        int      `json:"n"`
	Role     string   `json:"role"`
	Cond     string   `json:"cond"`
	Action   string   `json:"action"`
	Tier     string   `json:"tier"`
	Keywords []string `json:"keywords"`
	Class    string   `json:"cls"`
	Source   string   `json:"source,omitempty"`
}

// RuleLayer is one layer's verdict in the merged table.
type RuleLayer struct {
	Layer   string `json:"layer"`
	Used    bool   `json:"used"`
	Source  string `json:"source,omitempty"`
	Rows    int    `json:"rows,omitempty"`
	Problem string `json:"problem,omitempty"`
}

// Table is the merged table.
type Table struct {
	Version  string      `json:"version"`
	Rows     []Rule      `json:"rows"`
	Layers   []RuleLayer `json:"layers"`
	Problems []string    `json:"problems"`
}

func words(cell string) []string {
	out := []string{}
	for _, w := range ruleWordSep.Split(cell, -1) {
		if w = pyStrip(w); w != "" {
			out = append(out, strings.ToLower(w))
		}
	}
	return out
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// RuleRow is one row from its six cells (a list, or an object with
// n/role/cond/action/tier/keywords) — fleet_rules.py's _row.
func RuleRow(cells any) (Rule, error) {
	var c []string
	switch t := cells.(type) {
	case *OMap:
		get := func(k string) string {
			v, ok := t.Get(k)
			if !ok {
				return ""
			}
			return pyStr(v)
		}
		kw := get("keywords")
		if l, ok := t.Vals["keywords"].([]any); ok {
			parts := make([]string, len(l))
			for i, x := range l {
				parts[i] = pyStr(x)
			}
			kw = strings.Join(parts, ", ")
		}
		c = []string{get("n"), get("role"), get("cond"), get("action"), get("tier"), kw}
	case []any:
		for _, x := range t {
			c = append(c, pyStr(x))
		}
	case []string:
		c = t
	default:
		return Rule{}, fmt.Errorf("a row is its six cells or an object")
	}
	for i := range c {
		c[i] = pyStrip(c[i])
	}
	if len(c) != 6 {
		return Rule{}, fmt.Errorf("a row has %d cells, not 6: %s", len(c), strings.Join(c, " | "))
	}
	n, role, cond, action, tier, kw := c[0], c[1], c[2], c[3], c[4], c[5]
	num, _ := strconv.Atoi(n)
	if !isDigits(n) || num < 1 {
		return Rule{}, fmt.Errorf("编号 must be a positive number: '%s'", n)
	}
	if !in(role, Roles) {
		return Rule{}, fmt.Errorf("rule %s: 角色 '%s' is not one of %s", n, role, strings.Join(Roles, " "))
	}
	if !in(tier, Tiers) {
		return Rule{}, fmt.Errorf("rule %s: 档位 '%s' is not one of %s", n, tier, strings.Join(Tiers, " "))
	}
	if tier != "off" && (cond == "" || action == "") {
		return Rule{}, fmt.Errorf("rule %s: 条件 and 动作 are required", n)
	}
	r := Rule{N: num, Role: role, Cond: cond, Action: action, Tier: tier, Keywords: words(kw)}
	if m := ruleClassRE.FindStringSubmatch(action); m != nil {
		r.Class = m[1]
	}
	return r, nil
}

// ParseRules is the rows of a Markdown table whose header starts with 编号.
func ParseRules(text string) ([]Rule, error) {
	rows := []Rule{}
	inside := false
	for _, ln := range strings.Split(text, "\n") {
		s := pyStrip(ln)
		if !strings.HasPrefix(s, "|") {
			inside = false
			continue
		}
		parts := strings.Split(strings.Trim(s, "|"), "|")
		for i := range parts {
			parts[i] = pyStrip(parts[i])
		}
		if len(parts) > 0 && parts[0] == ruleHead {
			inside = true
			continue
		}
		if !inside || strings.Trim(strings.Join(parts, ""), "-: ") == "" {
			continue
		}
		r, err := RuleRow(parts)
		if err != nil {
			return nil, err
		}
		rows = append(rows, r)
	}
	return rows, nil
}

// PersonRules reads a person bundle's `rules` (a table's text or a list of
// rows); nil rows and no error when there is none.
func PersonRules(v any) ([]Rule, error) {
	switch t := v.(type) {
	case nil:
		return nil, nil
	case string:
		if t == "" {
			return nil, nil
		}
		return ParseRules(t)
	case []any:
		if len(t) == 0 {
			return nil, nil
		}
		out := []Rule{}
		for _, x := range t {
			r, err := RuleRow(x)
			if err != nil {
				return nil, err
			}
			out = append(out, r)
		}
		return out, nil
	}
	return nil, fmt.Errorf("person-bundle rules is neither a table nor a list")
}

// RulesVersion is the content address of the rows (fleet_rules.py's version_of).
func RulesVersion(rows []Rule) string {
	all := make([]any, len(rows))
	for i, r := range rows {
		all[i] = []any{r.N, r.Role, r.Cond, r.Action, r.Tier, strs(r.Keywords)}
	}
	sum := sha256.Sum256([]byte(Canonical(all)))
	return hex.EncodeToString(sum[:])[:10]
}

// MergeRules merges the built-in table's text with the person's `rules`
// (label e.g. "你的 v3"). An error only when the built-in cannot be read.
func MergeRules(defaultText string, person any, personLabel string) (Table, error) {
	merged := map[int]Rule{}
	t := Table{Layers: []RuleLayer{}, Problems: []string{}}
	rows, err := ParseRules(defaultText)
	if err != nil {
		return t, fmt.Errorf("the fleet's rule table: %v", err)
	}
	add := func(rows []Rule, label string) {
		seen := map[int]bool{}
		for _, r := range rows {
			if seen[r.N] {
				continue
			}
			seen[r.N] = true
			r.Source = label
			merged[r.N] = r
		}
	}
	add(rows, "自带")
	t.Layers = append(t.Layers, RuleLayer{Layer: "default", Used: true, Source: "自带", Rows: len(rows)})
	prows, err := PersonRules(person)
	switch {
	case err != nil:
		t.Problems = append(t.Problems, "person layer not used: "+err.Error())
		t.Layers = append(t.Layers, RuleLayer{Layer: "person", Problem: err.Error()})
	case prows != nil:
		var bad []string
		for _, r := range prows {
			if _, ok := merged[r.N]; !ok && r.N < RuleNewFrom {
				bad = append(bad, strconv.Itoa(r.N))
			}
		}
		if len(bad) > 0 {
			why := fmt.Sprintf("a new rule starts at %d (got %s)", RuleNewFrom, strings.Join(bad, ", "))
			t.Problems = append(t.Problems, "person layer not used: "+why)
			t.Layers = append(t.Layers, RuleLayer{Layer: "person", Problem: why})
		} else {
			add(prows, personLabel)
			t.Layers = append(t.Layers, RuleLayer{Layer: "person", Used: true, Source: personLabel, Rows: len(prows)})
		}
	}
	t.Rows = []Rule{}
	for _, r := range merged {
		if r.Tier != "off" {
			t.Rows = append(t.Rows, r)
		}
	}
	sort.Slice(t.Rows, func(i, j int) bool { return t.Rows[i].N < t.Rows[j].N })
	t.Version = RulesVersion(t.Rows)
	return t, nil
}
