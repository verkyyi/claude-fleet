package rolemerge

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// The rule table's row format (bin/fleet_rules.py, claude-fleet#2786): the
// hub only reads a person bundle's `rules` to refuse a row no machine could read.

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

// Roles are the role names a rule row may name.
var Roles = []string{"orchestrator", "steward", "worker", "epic-driver"}

func in(s string, set []string) bool {
	for _, x := range set {
		if x == s {
			return true
		}
	}
	return false
}

// pyStr is python's str() of a cell.
func pyStr(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case nil:
		return "None"
	case bool:
		if t {
			return "True"
		}
		return "False"
	case fmt.Stringer:
		return t.String()
	default:
		return Canonical(t)
	}
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
