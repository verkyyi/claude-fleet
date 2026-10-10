package rolemerge

import (
	"encoding/json"
	"os"
	"os/exec"
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

// TestBuiltinRoles: the four shipped definitions parse, and with no layer the
// merge is the definition itself.
func TestBuiltinRoles(t *testing.T) {
	list, _ := os.ReadFile(filepath.Join(repo, "conf", "agent-locked.list"))
	for _, role := range Roles {
		raw, err := os.ReadFile(filepath.Join(repo, "agents", role+".md"))
		if err != nil {
			t.Fatal(err)
		}
		f, b, err := Parse(string(raw))
		if err != nil {
			t.Fatalf("%s: %v", role, err)
		}
		if n, _ := f.Get("name"); n != role {
			t.Errorf("%s: name %v", role, n)
		}
		m := Merge(f, b, nil, RoleLocks(role, string(list)))
		if Canonical(m.Fields) != Canonical(f) || m.Body != b {
			t.Errorf("%s: no layer changed the definition", role)
		}
	}
	if l := RoleLocks("worker", string(list)); !in("permissionMode", l) {
		t.Errorf("worker locks: %v", l)
	}
}

// TestRulesMatchPython: the built-in table, alone and under a person layer,
// merges to the rows and version bin/fleet_rules.py gives.
func TestRulesMatchPython(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	def, err := os.ReadFile(filepath.Join(repo, "conf", "role-rules.default.md"))
	if err != nil {
		t.Fatal(err)
	}
	person := `[{"n": 11, "role": "orchestrator", "cond": "单子没写优先级", "action": "按 p2", "tier": "default", "keywords": []},
	 {"n": 4, "role": "orchestrator", "cond": "x", "action": "y", "tier": "off", "keywords": ""},
	 {"n": 100, "role": "steward", "cond": "新的", "action": "问你（never:money）", "tier": "ask", "keywords": ["钱", "Pay"]}]`
	for _, tc := range []struct{ name, rules string }{{"alone", ""}, {"person", person}, {"bad", `[{"n": 50, "role": "worker", "cond": "a", "action": "b", "tier": "auto"}]`}} {
		conf := t.TempDir()
		var pv any
		if tc.rules != "" {
			b := `{"version": 3, "bundle": {"rules": ` + tc.rules + `}}`
			if err := os.WriteFile(filepath.Join(conf, "person-bundle.json"), []byte(b), 0o600); err != nil {
				t.Fatal(err)
			}
			if pv, err = Decode([]byte(tc.rules)); err != nil {
				t.Fatal(err)
			}
		}
		cmd := exec.Command(py, "-c", `
import json, sys
sys.path.insert(0, sys.argv[1])
import fleet_rules
t = fleet_rules.load()
print(json.dumps({"version": t["version"], "rows": t["rows"], "problems": t["problems"]}, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
`, filepath.Join(repo, "bin"))
		cmd.Env = append(os.Environ(), "FLEET_CONF_DIR="+conf, "FLEET_RULES_DEFAULT="+filepath.Join(repo, "conf", "role-rules.default.md"))
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s: python: %v", tc.name, err)
		}
		tab, err := MergeRules(string(def), pv, "你的 v3")
		if err != nil {
			t.Fatal(err)
		}
		gb, _ := json.Marshal(map[string]any{"version": tab.Version, "rows": tab.Rows, "problems": tab.Problems})
		gd, _ := Decode(gb)
		pd, _ := Decode(out)
		if g, p := Canonical(gd), Canonical(pd); g != p {
			t.Errorf("%s:\n go     %s\n python %s", tc.name, g, p)
		}
		if tc.name == "bad" && !strings.Contains(strings.Join(tab.Problems, ""), "starts at 100") {
			t.Errorf("bad: %v", tab.Problems)
		}
	}
}
