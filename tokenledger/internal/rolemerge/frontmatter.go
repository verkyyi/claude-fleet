// Package rolemerge reads a subagent file's frontmatter (svc templates) and a
// person bundle's `rules` (its validation). The role definitions' merge — the
// hub's copy of fleet-role.py, its /config view and tests/role-merge — left
// with the person's role layer (claude-fleet#3130); rules.go goes with the
// rule table's last readers.
package rolemerge

import (
	"fmt"
	"strings"
	"unicode"
)

func pyStrip(s string) string { return strings.TrimFunc(s, unicode.IsSpace) }

func scalar(v string) any {
	v = pyStrip(v)
	if len(v) >= 2 && v[0] == v[len(v)-1] && (v[0] == '"' || v[0] == '\'') {
		return v[1 : len(v)-1]
	}
	if strings.HasPrefix(v, "[") && strings.HasSuffix(v, "]") {
		out := []any{}
		for _, x := range strings.Split(v[1:len(v)-1], ",") {
			if pyStrip(x) != "" {
				out = append(out, scalar(x))
			}
		}
		return out
	}
	if strings.HasPrefix(v, "{") {
		if d, err := Decode([]byte(v)); err == nil {
			return d
		}
		return v
	}
	return v
}

// Parse is (frontmatter, body) of a subagent file — fleet-role.py's parse.
func Parse(text string) (*OMap, string, error) {
	front := NewOMap()
	if !strings.HasPrefix(text, "---\n") {
		return front, text, nil
	}
	i := strings.Index(text[3:], "\n---\n")
	if i < 0 {
		return nil, "", fmt.Errorf("frontmatter has no closing ---")
	}
	end := i + 3
	head, body := text[4:end+1], text[end+5:]
	key := ""
	haveKey := false
	for _, ln := range strings.Split(head, "\n") {
		ln = strings.TrimSuffix(ln, "\r")
		if pyStrip(ln) == "" || strings.HasPrefix(strings.TrimLeftFunc(ln, unicode.IsSpace), "#") {
			continue
		}
		if (ln[0] == ' ' || ln[0] == '\t') && haveKey {
			item := pyStrip(ln)
			if strings.HasPrefix(item, "- ") {
				cur, _ := front.Get(key)
				l, ok := cur.([]any)
				if !ok {
					l = []any{}
				}
				front.Set(key, append(l, scalar(item[2:])))
			}
			continue
		}
		c := strings.Index(ln, ":")
		if c < 0 {
			return nil, "", fmt.Errorf("cannot read frontmatter line: %s", ln)
		}
		key, haveKey = pyStrip(ln[:c]), true
		if val := ln[c+1:]; pyStrip(val) != "" {
			front.Set(key, scalar(val))
		} else {
			front.Set(key, "")
		}
	}
	return front, body, nil
}
