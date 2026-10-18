package rolemerge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repo is the claude-fleet checkout this module sits in.
var repo = filepath.Join("..", "..", "..")

// vector runs one tests/role-merge/*.json case the way fleet-role.py's
// _vector does.
func vector(t *testing.T, v *OMap) Result {
	t.Helper()
	role := "worker"
	if r, ok := v.Get("role"); ok {
		role = r.(string)
	}
	var layers []Layer
	var refused []int
	ls, _ := v.Get("layers")
	ll, _ := ls.([]any)
	for i, x := range ll {
		l := x.(*OMap)
		var src any
		if txt, ok := l.Get("text"); ok {
			src = txt
		} else {
			o := NewOMap()
			f, ok := l.Get("front")
			if !ok {
				f = NewOMap()
			}
			b, ok := l.Get("body")
			if !ok {
				b = ""
			}
			o.Set("front", f)
			o.Set("body", b)
			src = o
		}
		front, body, err := OverlayOf(src)
		if err != nil || CheckOverlay(role, front, body) != "" {
			refused = append(refused, i)
			continue
		}
		label, _ := l.Get("label")
		kind, ok := l.Get("kind")
		if !ok {
			kind = "person"
		}
		layers = append(layers, Layer{Label: label.(string), Kind: kind.(string), Front: front, Body: body.(string)})
	}
	bv, _ := v.Get("base")
	base := bv.(*OMap)
	var bf *OMap
	var bb string
	if txt, ok := base.Get("text"); ok {
		var err error
		if bf, bb, err = Parse(txt.(string)); err != nil {
			t.Fatal(err)
		}
	} else {
		f, ok := base.Get("front")
		if !ok {
			f = NewOMap()
		}
		bf = f.(*OMap)
		b, _ := base.Get("body")
		bb, _ = b.(string)
	}
	var locks []string
	if lk, ok := v.Get("locks"); ok {
		for _, x := range lk.([]any) {
			locks = append(locks, x.(string))
		}
	}
	m := Merge(bf, bb, layers, locks)
	m.Refused = refused
	return m
}

func answer(m Result) any {
	o := NewOMap()
	o.Set("fields", m.Fields)
	o.Set("body", m.Body)
	src := NewOMap()
	for _, k := range m.Sources.Keys {
		src.Set(k, strs(m.Sources.Vals[k].([]string)))
	}
	o.Set("sources", src)
	o.Set("locked", strs(m.Locked))
	ref := []any{}
	for _, i := range m.Refused {
		ref = append(ref, json.Number(itoa(i)))
	}
	o.Set("refused", ref)
	return o
}

func itoa(i int) string { b, _ := json.Marshal(i); return string(b) }

// TestVectors: every tests/role-merge/*.json gives its `expect` — the same
// set bin/fleet-role-merge-selftest.sh holds python's copy to, so the two
// merges answer byte for byte the same (canonical JSON).
func TestVectors(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(repo, "tests", "role-merge", "*.json"))
	if len(files) < 15 {
		t.Fatalf("only %d vectors in tests/role-merge", len(files))
	}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		d, err := Decode(raw)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		v := d.(*OMap)
		want, ok := v.Get("expect")
		if !ok {
			t.Fatalf("%s has no expect", f)
		}
		got := Canonical(answer(vector(t, v)))
		if w := Canonical(want); got != w {
			t.Errorf("%s:\n got  %s\n want %s", filepath.Base(f), got, w)
		}
	}
}

// TestRulesPersonLayer: a person's rows merge onto a built-in table by number (tier
// off drops a row, a number from 100 adds one), and
// a new number below 100 is refused with the layer unused. (Its python twin,
// bin/fleet_rules.py, left with the node's rule table — claude-fleet#4340; the
// hub's view keeps this copy until the person's role layer goes, #3130.)
func TestRulesPersonLayer(t *testing.T) {
	def := "| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n" +
		"| 4 | orchestrator | 一件小事 | 派一个执行会话 | auto | 小事 |\n"
	for _, tc := range []struct{ name, rules string }{
		{"person", `[{"n": 4, "role": "orchestrator", "cond": "x", "action": "y", "tier": "off", "keywords": ""},
		 {"n": 100, "role": "steward", "cond": "新的", "action": "问你（never:money）", "tier": "ask", "keywords": ["钱"]}]`},
		{"bad", `[{"n": 50, "role": "worker", "cond": "a", "action": "b", "tier": "auto"}]`},
	} {
		pv, err := Decode([]byte(tc.rules))
		if err != nil {
			t.Fatal(err)
		}
		tab, err := MergeRules(def, pv, "你的 v3")
		if err != nil {
			t.Fatal(err)
		}
		switch tc.name {
		case "person":
			if len(tab.Rows) != 1 || tab.Rows[0].N != 100 || len(tab.Problems) != 0 || tab.Version == "" {
				t.Errorf("person: rows %d problems %v version %q", len(tab.Rows), tab.Problems, tab.Version)
			}
		case "bad":
			if !strings.Contains(strings.Join(tab.Problems, ""), "starts at 100") {
				t.Errorf("bad: %v", tab.Problems)
			}
		}
	}
}
