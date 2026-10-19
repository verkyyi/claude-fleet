package rolemerge

import (
	"strings"
	"testing"
)

// A person bundle's `rules` is a list of rows (or a table's text); a row the
// format cannot read is refused (the hub's 422 on a PUT).
func TestPersonRules(t *testing.T) {
	pv, err := Decode([]byte(`[{"n": 4, "role": "worker", "cond": "x", "action": "y", "tier": "off", "keywords": ""},
	 {"n": 100, "role": "steward", "cond": "新的", "action": "问你（never:money）", "tier": "ask", "keywords": ["钱"]}]`))
	if err != nil {
		t.Fatal(err)
	}
	rows, err := PersonRules(pv)
	if err != nil || len(rows) != 2 || rows[1].N != 100 || rows[1].Class != "money" {
		t.Fatalf("rows %+v err %v", rows, err)
	}
	if rows, err := PersonRules(nil); rows != nil || err != nil {
		t.Fatalf("no rules: %v %v", rows, err)
	}
	if _, err := PersonRules([]any{"x"}); err == nil {
		t.Fatal("a row that is not a row was read")
	}
	text := "| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 报价, 金额 |\n"
	if rows, err := PersonRules(text); err != nil || len(rows) != 1 || !strings.Contains(rows[0].Cond, "金额") {
		t.Fatalf("table: %+v %v", rows, err)
	}
}

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
