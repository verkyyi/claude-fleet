package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/rolemerge"
)

// The /config page's merged roles view (claude-fleet#2787, EPIC #2781 C6).

// repoRoleTree serves the checkout's own agents/ and conf/ as stable's tree.
func repoRoleTree(t *testing.T) func() (string, map[string][]byte, string) {
	t.Helper()
	root := filepath.Join("..", "..", "..")
	files := map[string][]byte{}
	for _, n := range roleTreeFiles {
		b, err := os.ReadFile(filepath.Join(root, n))
		if err != nil {
			t.Fatal(err)
		}
		files[n] = b
	}
	return func() (string, map[string][]byte, string) { return "0123456789abcdef", files, "" }
}

func rolesCall(t *testing.T, h *harness, method string, auth func(http.Header)) (int, PersonRolesResponse, []byte) {
	t.Helper()
	req, _ := http.NewRequest(method, h.http.URL+control.PersonBundlePath+"/roles?merged=1", nil)
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	var out PersonRolesResponse
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.Bytes()
}

var personRolesEdit = map[string]any{"bundle": map[string]any{
	"roles": map[string]any{
		"steward": map[string]any{"model": "sonnet"},
		"worker":  map[string]any{"front": map[string]any{"effort": "high", "permissionMode": "bypassPermissions", "skills": []string{"+notes"}}, "body": "Write one line after each round.\n"},
	},
	"rules": []any{
		map[string]any{"n": 1, "role": "orchestrator", "cond": "一个仓库里的一处改动，已经清楚", "action": "建单前先问你", "tier": "ask", "keywords": []string{}},
		map[string]any{"n": 101, "role": "steward", "cond": "问的是金额", "action": "必须问你（never:money）", "tier": "ask", "keywords": []string{"报价", "金额"}},
	},
}}

// The completion criterion: the page's merged view of a layer is what
// `fleet role show <role> --json` and `fleet role rules --json` print on a
// machine holding that layer and no local one.
func TestPersonRolesViewMatchesCommand(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	h.srv.roleTreeFn = repoRoleTree(t)

	code, out, raw := rolesCall(t, h, http.MethodGet, asSession(pAlice))
	if code != 200 || out.Version != 0 || out.Stable == "" || len(out.Roles) != 4 || len(out.Rules.Rows) < 10 {
		t.Fatalf("an empty layer: HTTP %d %s", code, raw)
	}
	if w := out.Roles["worker"]; w.Changed != 0 || w.Layer != nil || w.Base == nil {
		t.Fatalf("worker with no layer: %+v", w)
	}
	if c, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), personRolesEdit, ""); c != 200 {
		t.Fatalf("PUT: HTTP %d %s", c, raw)
	}
	code, out, raw = rolesCall(t, h, http.MethodGet, asSession(pAlice))
	if code != 200 || out.Version != 1 {
		t.Fatalf("after PUT: HTTP %d %s", code, raw)
	}
	st := out.Roles["steward"]
	if m, _ := st.Fields.Get("model"); m != "sonnet" || st.Changed != 1 {
		t.Fatalf("steward: %s", raw)
	}
	w := out.Roles["worker"]
	if !strings.Contains(strings.Join(w.Locked, " "), "permissionMode") {
		t.Fatalf("worker's lock: %s", raw)
	}
	if w.Changed != 4 || !strings.Contains(w.Body, "## （你加的）") {
		t.Fatalf("worker: %s", raw)
	}
	if r := out.Rules.Rows[0]; r.N != 1 || r.Tier != "ask" || r.Source != "你的 v1" {
		t.Fatalf("rule 1: %+v", r)
	}

	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	_, stored, _, _ := personCall(t, h, http.MethodGet, asSession(pAlice), nil, "")
	conf := t.TempDir()
	cache, _ := json.Marshal(map[string]any{"version": stored.Version, "bundle": stored.Bundle})
	if err := os.WriteFile(filepath.Join(conf, "person-bundle.json"), cache, 0o600); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join("..", "..", "..", "bin", "fleet-role.py")
	runPy := func(args ...string) any {
		cmd := exec.Command(py, append([]string{bin}, args...)...)
		cmd.Env = append(os.Environ(), "FLEET_CONF_DIR="+conf, "FLEET_ROLE_STALE=999999999")
		b, err := cmd.Output()
		if err != nil {
			t.Fatalf("fleet-role.py %v: %v", args, err)
		}
		d, err := rolemerge.Decode(b)
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	for _, role := range rolemerge.Roles {
		d := runPy("show", role, "--json").(*rolemerge.OMap)
		pr := out.Roles[role]
		for k, got := range map[string]any{"front": pr.Fields, "body": pr.Body, "sources": pr.Sources, "locked": pr.Locked} {
			want, _ := d.Get(k)
			if g, w := canonOf(t, got), rolemerge.Canonical(want); g != w {
				t.Errorf("%s %s:\n page    %s\n command %s", role, k, g, w)
			}
		}
	}
	d := runPy("rules", "--json").(*rolemerge.OMap)
	for k, got := range map[string]any{"version": out.Rules.Version, "rows": out.Rules.Rows} {
		want, _ := d.Get(k)
		if g, w := canonOf(t, got), rolemerge.Canonical(want); g != w {
			t.Errorf("rules %s:\n page    %s\n command %s", k, g, w)
		}
	}
}

func canonOf(t *testing.T, v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	d, err := rolemerge.Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	return rolemerge.Canonical(d)
}

// No release store: the person's layer alone, and a note saying why; the view
// is read-only; a layer every machine would refuse is refused at the PUT.
func TestPersonRolesViewNoTree(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	if c, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), personRolesEdit, ""); c != 200 {
		t.Fatalf("PUT: HTTP %d %s", c, raw)
	}
	code, out, raw := rolesCall(t, h, http.MethodGet, asSession(pAlice))
	if code != 200 || out.Note == "" || out.Stable != "" {
		t.Fatalf("no tree: HTTP %d %s", code, raw)
	}
	if st := out.Roles["steward"]; st.Fields != nil || st.Layer == nil || st.Changed != 1 {
		t.Fatalf("steward with no tree: %s", raw)
	}
	if len(out.Rules.Rows) != 2 || out.Rules.Rows[1].N != 101 {
		t.Fatalf("rules with no tree: %s", raw)
	}
	if code, _, _ := rolesCall(t, h, http.MethodPut, asSession(pAlice)); code != http.StatusMethodNotAllowed {
		t.Fatalf("PUT on the view: HTTP %d", code)
	}
	if code, _, _ := rolesCall(t, h, http.MethodGet, nil); code != http.StatusUnauthorized {
		t.Fatalf("no credential: HTTP %d", code)
	}
	for name, b := range map[string]map[string]any{
		"bad effort":     {"roles": map[string]any{"steward": map[string]any{"effort": "turbo"}}},
		"subagent field": {"roles": map[string]any{"worker": "---\nmaxTurns: 3\n---\n"}},
		"other name":     {"roles": map[string]any{"worker": map[string]any{"name": "steward"}}},
		"bad tier":       {"rules": []any{map[string]any{"n": 101, "role": "steward", "cond": "a", "action": "b", "tier": "maybe"}}},
		"bad role":       {"rules": []any{map[string]any{"n": 101, "role": "reviewer", "cond": "a", "action": "b", "tier": "ask"}}},
	} {
		if code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": b}, ""); code != http.StatusUnprocessableEntity {
			t.Errorf("%s: HTTP %d %s, want 422", name, code, raw)
		}
	}
}
