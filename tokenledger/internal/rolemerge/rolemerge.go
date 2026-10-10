// Package rolemerge is the hub's copy of a role definition's merge
// (claude-fleet#2787, EPIC #2781 C6): bin/fleet-role.py's parse / overlay_of /
// check_overlay / merge / role_locks, and bin/fleet_rules.py's table, in Go —
// so the /config page shows the merged role exactly as `fleet role show
// --sources` prints it on a machine with no local layer.
//
// Both copies are held to the same vectors, tests/role-merge/*.json: python's
// selftest (bin/fleet-role-merge-selftest.sh) and this package's test read
// every file and compare the canonical JSON of the answer with its `expect`.
// A change to one copy without the other reds on that set — never fix only one.
package rolemerge

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// Roles are the four role definitions (agents/<role>.md).
var Roles = []string{"orchestrator", "steward", "worker", "epic-driver"}

// Fields is the frontmatter's order, as `show` prints it.
var Fields = []string{"name", "description", "model", "effort", "tools", "disallowedTools",
	"mcpServers", "skills", "hooks", "permissionMode", "memory"}

var (
	scalars     = []string{"description", "model", "effort", "permissionMode", "memory"}
	lists       = []string{"tools", "disallowedTools", "skills"}
	dicts       = []string{"mcpServers", "hooks"}
	efforts     = []string{"low", "medium", "high", "xhigh", "max"}
	modes       = []string{"default", "acceptEdits", "auto", "dontAsk", "plan", "bypassPermissions"}
	modeRank    = map[string]int{"bypassPermissions": 0, "acceptEdits": 1, "auto": 1, "default": 2, "dontAsk": 3, "plan": 3}
	memories    = []string{"user", "project", "local"}
	hookEvents  = []string{"PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop", "SessionStart", "SessionEnd", "Notification", "PreCompact"}
	bodyHead    = map[string]string{"person": "## （你加的）", "local": "## （本机加的）"}
	nameRE      = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,64}$`)
	signedName  = regexp.MustCompile(`^[+-]?[A-Za-z0-9_.:-]{1,64}$`)
	modelNameRE = regexp.MustCompile(`^[A-Za-z0-9._\[\]-]{1,64}$`)
)

// Overridable are the ten fields a layer may change.
var Overridable = append(append(append([]string{}, scalars...), lists...), dicts...)

// Replace is a list's first item when the layer replaces the whole list.
const Replace = "!replace"

// SecretIn reports a credential-shaped value's path, "" when none — the
// person bundle's own rule. The hub sets it (api's secretIn); nil = no scan.
var SecretIn func(v any) string

func in(s string, set []string) bool {
	for _, x := range set {
		if x == s {
			return true
		}
	}
	return false
}

func pyStrip(s string) string { return strings.TrimFunc(s, unicode.IsSpace) }

// pyStr is python's str() of a value the merge can meet.
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

// truthy is python's bool() of a value.
func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case string:
		return t != ""
	case bool:
		return t
	case []any:
		return len(t) > 0
	case []string:
		return len(t) > 0
	case *OMap:
		return t.Len() > 0
	case fmt.Stringer:
		s := t.String()
		return s != "0" && s != "0.0" && s != ""
	}
	return true
}

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

// OverlayOf is (front, body) of one overlay: the agents/*.md text, or the same
// as an object ({front, body} or flat {<field>…, body}).
func OverlayOf(obj any) (*OMap, any, error) {
	switch t := obj.(type) {
	case string:
		text := t
		if !strings.HasPrefix(text, "---\n") {
			text = "---\n---\n" + text
		}
		f, b, err := Parse(text)
		return f, b, err
	case *OMap:
		body, _ := t.Get("body")
		if !truthy(body) {
			body = ""
		}
		if fr, ok := t.Get("front"); ok {
			if fm, ok := fr.(*OMap); ok {
				return fm.Copy(), body, nil
			}
		}
		front := NewOMap()
		for _, k := range t.Keys {
			if k != "body" {
				front.Set(k, t.Vals[k])
			}
		}
		return front, body, nil
	}
	return nil, nil, fmt.Errorf("an overlay is the definition text or an object, not %T", obj)
}

func itemsOf(v any) []any {
	if l, ok := v.([]any); ok {
		return l
	}
	if !truthy(v) {
		v = ""
	}
	out := []any{}
	for _, x := range listval(v) {
		out = append(out, x)
	}
	return out
}

func listval(v any) []string {
	if l, ok := v.([]any); ok {
		out := make([]string, len(l))
		for i, x := range l {
			out[i] = pyStr(x)
		}
		return out
	}
	if l, ok := v.([]string); ok {
		return append([]string(nil), l...)
	}
	out := []string{}
	for _, x := range strings.Split(pyStr(v), ",") {
		if x = pyStrip(x); x != "" {
			out = append(out, x)
		}
	}
	return out
}

func strs(l []string) []any {
	out := make([]any, len(l))
	for i, x := range l {
		out[i] = x
	}
	return out
}

// CheckOverlay is "" when the layer may be used, else the one-line reason.
func CheckOverlay(role string, front *OMap, body any) string {
	for _, k := range front.Keys {
		v := front.Vals[k]
		switch {
		case k == "name":
			if s, ok := v.(string); !ok || s != role {
				return fmt.Sprintf("name: %s is not this role (%s)", pyStr(v), role)
			}
			continue
		case k == "body":
			if s, ok := v.(string); !ok || (s != "replace" && s != "append") {
				return fmt.Sprintf("body: %s — only replace (or append, the default)", pyStr(v))
			}
			continue
		case !in(k, Overridable):
			return fmt.Sprintf("%s is not something a layer can change (%s)", k, strings.Join(Overridable, " "))
		}
		switch {
		case in(k, scalars):
			if v == nil {
				continue
			}
			s, ok := v.(string)
			if !ok {
				return k + " must be one value"
			}
			if s == "" {
				continue
			}
			switch {
			case k == "effort" && !in(s, efforts):
				return fmt.Sprintf("effort: %s is none of %s", s, strings.Join(efforts, " "))
			case k == "permissionMode" && !in(s, modes):
				return fmt.Sprintf("permissionMode: %s is none of %s", s, strings.Join(modes, " "))
			case k == "memory" && !in(s, memories):
				return fmt.Sprintf("memory: %s is none of %s", s, strings.Join(memories, " "))
			case k == "model" && !modelNameRE.MatchString(s):
				return fmt.Sprintf("model: %s is no model name", s)
			}
		case in(k, lists):
			for i, x := range itemsOf(v) {
				s, ok := x.(string)
				if !ok || pyStrip(s) == "" || (s == Replace && i > 0) {
					return fmt.Sprintf("%s[%d] must be a name (+X adds, -X removes, %s first)", k, i, Replace)
				}
			}
		case k == "mcpServers":
			switch t := v.(type) {
			case []any:
				for _, x := range t {
					if m, ok := x.(*OMap); ok {
						if m.Len() != 1 || !nameRE.MatchString(m.Keys[0]) {
							return "mcpServers: an inline server is {name: {command|url…}}"
						}
						if _, ok := m.Vals[m.Keys[0]].(*OMap); !ok {
							return "mcpServers: an inline server is {name: {command|url…}}"
						}
					} else if s, ok := x.(string); !ok || !signedName.MatchString(s) {
						return fmt.Sprintf("mcpServers: %s is no server name", pyStr(x))
					}
				}
			case *OMap:
				for _, n := range t.Keys {
					s := t.Vals[n]
					_, isMap := s.(*OMap)
					_, isStr := s.(string)
					if !nameRE.MatchString(n) || !(s == nil || isMap || isStr) {
						return fmt.Sprintf("mcpServers.%s: a config object, the name again, or null to remove", n)
					}
				}
			default:
				return "mcpServers must be a list or an object"
			}
		case k == "hooks":
			t, ok := v.(*OMap)
			if !ok {
				return "hooks must be an object of hook events"
			}
			for _, ev := range t.Keys {
				_, isList := t.Vals[ev].([]any)
				if !in(ev, hookEvents) || !(t.Vals[ev] == nil || isList) {
					return fmt.Sprintf("hooks.%s is not a hook event with a list (or null)", ev)
				}
			}
		}
	}
	if _, ok := body.(string); !ok {
		return "the body must be text"
	}
	if SecretIn != nil {
		o := NewOMap()
		o.Set("front", front)
		o.Set("body", body)
		if s := SecretIn(Plain(o)); s != "" {
			return fmt.Sprintf("carries something credential-shaped (%s) — a key goes in a wrapper script and an env name", s)
		}
	}
	return ""
}

// Plain is v with every *OMap a map[string]any (what encoding/json gives).
func Plain(v any) any {
	switch t := v.(type) {
	case *OMap:
		m := make(map[string]any, t.Len())
		for _, k := range t.Keys {
			m[k] = Plain(t.Vals[k])
		}
		return m
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = Plain(x)
		}
		return out
	}
	return v
}

// Layer is one overlay, low → high: Kind "person" | "local".
type Layer struct {
	Label, Kind string
	Front       *OMap
	Body        string
}

// Result is the merge's answer.
type Result struct {
	Fields  *OMap    `json:"fields"`
	Body    string   `json:"body"`
	Sources *OMap    `json:"sources"` // field → []string, low → high
	Locked  []string `json:"locked"`
	Refused []int    `json:"refused,omitempty"`
}

func srcs(sources *OMap, k string) []string {
	v, _ := sources.Get(k)
	l, _ := v.([]string)
	return append([]string(nil), l...)
}

func addOnce(l []string, x string) []string {
	if in(x, l) {
		return l
	}
	return append(l, x)
}

// mcpDict is mcpServers as an ordered name → config | true ("the login's own").
func mcpDict(v any) *OMap {
	out := NewOMap()
	switch t := v.(type) {
	case *OMap:
		return t.Copy()
	case []any:
		for _, x := range t {
			if m, ok := x.(*OMap); ok {
				for _, k := range m.Keys {
					out.Set(k, m.Vals[k])
				}
			} else {
				out.Set(pyStr(x), true)
			}
		}
	case nil:
	case string:
		if t != "" {
			out.Set(t, true)
		}
	default:
		out.Set(pyStr(t), true)
	}
	return out
}

func mcpList(d *OMap) []any {
	out := []any{}
	for _, n := range d.Keys {
		c := d.Vals[n]
		_, isStr := c.(string)
		if c == true || isStr {
			out = append(out, n)
		} else {
			m := NewOMap()
			m.Set(n, c)
			out = append(out, m)
		}
	}
	return out
}

// Merge is fleet-role.py's merge: pure, low → high.
func Merge(baseFront *OMap, baseBody string, layers []Layer, locks []string) Result {
	fields := baseFront.Copy()
	sources := NewOMap()
	for _, k := range baseFront.Keys {
		sources.Set(k, []string{"agents"})
	}
	body, bsrc := baseBody, []string{"agents"}
	for _, l := range layers {
		for _, k := range l.Front.Keys {
			v := l.Front.Vals[k]
			if k == "name" || k == "body" {
				continue
			}
			cur, _ := fields.Get(k)
			switch {
			case in(k, scalars):
				if v == nil {
					v = ""
				}
				fields.Set(k, v)
				sources.Set(k, []string{l.Label})
			case k == "tools" && !truthy(cur) && !firstIsReplace(itemsOf(v)):
				var gone []string
				for _, x := range itemsOf(v) {
					if s := pyStr(x); strings.HasPrefix(s, "-") {
						gone = append(gone, s[1:])
					}
				}
				if len(gone) > 0 {
					dv, _ := fields.Get("disallowedTools")
					if !truthy(dv) {
						dv = []any{}
					}
					c := listval(dv)
					for _, x := range gone {
						if !in(x, c) {
							c = append(c, x)
						}
					}
					fields.Set("disallowedTools", strs(c))
					sources.Set("disallowedTools", addOnce(srcs(sources, "disallowedTools"), l.Label))
				}
			case in(k, lists):
				items := itemsOf(v)
				var c, s []string
				if firstIsReplace(items) {
					c, s, items = []string{}, []string{l.Label}, items[1:]
				} else {
					if !truthy(cur) {
						cur = []any{}
					}
					c, s = listval(cur), srcs(sources, k)
				}
				for _, xi := range items {
					x := pyStr(xi)
					if strings.HasPrefix(x, "-") {
						keep := c[:0:0]
						for _, y := range c {
							if y != x[1:] {
								keep = append(keep, y)
							}
						}
						c = keep
					} else {
						x = strings.TrimPrefix(x, "+")
						if !in(x, c) {
							c = append(c, x)
						}
					}
				}
				fields.Set(k, strs(c))
				sources.Set(k, addOnce(s, l.Label))
			case k == "mcpServers":
				d := mcpDict(cur)
				if lv, ok := v.([]any); ok {
					for _, x := range lv {
						if m, ok := x.(*OMap); ok {
							for _, n := range m.Keys {
								d.Set(n, m.Vals[n])
							}
						} else if s := pyStr(x); strings.HasPrefix(s, "-") {
							d.Del(s[1:])
						} else {
							d.Set(strings.TrimLeft(s, "+"), true)
						}
					}
				} else if m, ok := v.(*OMap); ok {
					for _, n := range m.Keys {
						c := m.Vals[n]
						if c == nil {
							d.Del(n)
						} else if _, isStr := c.(string); isStr {
							d.Set(n, true)
						} else {
							d.Set(n, c)
						}
					}
				}
				fields.Set(k, mcpList(d))
				sources.Set(k, append(srcs(sources, k), l.Label))
			case k == "hooks":
				c := NewOMap()
				if m, ok := cur.(*OMap); ok {
					c = m.Copy()
				}
				if m, ok := v.(*OMap); ok {
					for _, ev := range m.Keys {
						if m.Vals[ev] == nil {
							c.Del(ev)
						} else {
							c.Set(ev, m.Vals[ev])
						}
					}
				}
				fields.Set(k, c)
				sources.Set(k, append(srcs(sources, k), l.Label))
			}
		}
		if bv, _ := l.Front.Get("body"); bv == "replace" {
			body, bsrc = l.Body, []string{l.Label}
		} else if pyStrip(l.Body) != "" {
			h, ok := bodyHead[l.Kind]
			if !ok {
				h = bodyHead["person"]
			}
			body = fmt.Sprintf("%s\n\n%s\n\n%s\n", strings.TrimRight(body, "\n"), h, strings.Trim(l.Body, "\n"))
			bsrc = append(bsrc, l.Label)
		}
	}
	locked := []string{}
	for _, k := range locks {
		b, inBase := baseFront.Get(k)
		cur, inFields := fields.Get(k)
		if !inBase && !inFields {
			continue
		}
		locked = append(locked, k)
		switch {
		case in(k, lists):
			if !truthy(b) {
				b = []any{}
			}
			if !truthy(cur) {
				cur = []any{}
			}
			want, have := listval(b), listval(cur)
			var miss []string
			for _, x := range want {
				if !in(x, have) {
					miss = append(miss, x)
				}
			}
			if len(miss) > 0 {
				fields.Set(k, strs(append(have, miss...)))
				sources.Set(k, append(srcs(sources, k), "lock"))
			}
		case k == "permissionMode":
			cs, _ := cur.(string)
			bs, _ := b.(string)
			if modeRank[cs] < modeRank[bs] {
				fields.Set(k, b)
				sources.Set(k, append(srcs(sources, k), "lock"))
			}
		case Canonical(cur) != Canonical(b):
			if b == nil {
				fields.Del(k)
			} else {
				fields.Set(k, b)
			}
			sources.Set(k, append(srcs(sources, k), "lock"))
		}
	}
	for _, k := range append([]string(nil), fields.Keys...) {
		v := fields.Vals[k]
		if _, inBase := baseFront.Get(k); !inBase && (v == nil || v == "") {
			fields.Del(k)
			sources.Del(k)
		}
	}
	sources.Set("body", bsrc)
	sort.Strings(locked)
	return Result{Fields: fields, Body: body, Sources: sources, Locked: locked}
}

func firstIsReplace(items []any) bool {
	if len(items) == 0 {
		return false
	}
	s, ok := items[0].(string)
	return ok && s == Replace
}

// RoleLocks is the fields conf/agent-locked.list's text holds for role
// (`role.<role>.<field>`, `role.*.<field>`).
func RoleLocks(role, list string) []string {
	out := []string{}
	for _, ln := range strings.Split(list, "\n") {
		if i := strings.Index(ln, "#"); i >= 0 {
			ln = ln[:i]
		}
		p := strings.Split(pyStrip(ln), ".")
		if len(p) == 3 && p[0] == "role" && (p[1] == role || p[1] == "*") && !in(p[2], out) {
			out = append(out, p[2])
		}
	}
	return out
}

// SaySource is a source label as a person reads it (fleet-role.py's say_source).
func SaySource(label string) string {
	switch {
	case label == "agents":
		return "自带"
	case label == "lock":
		return "🔒"
	case strings.HasPrefix(label, "person:"):
		return "你的 " + strings.SplitN(label, ":", 2)[1]
	case label == "local":
		return "本机"
	}
	return label
}
