package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

const svcTestAgentV2 = "---\nname: report\ndescription: 行业日报\n---\n按要求整理，附出处。\n"

func svcPutTemplate(t *testing.T, h *harness, tok string, req SvcTemplateRequest) (int, map[string]any) {
	t.Helper()
	return svcDo(t, h, http.MethodPost, SvcTemplatesPath, tok, req)
}

// Registered through the door, the digest runs: its Job is asked for and its
// spec hands the registered text. A changed text is a new digest; the old one
// stays and still runs. Registering again is the same row.
func TestSvcTemplateRegisterThenRun(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	st, out := svcPutTemplate(t, h, tok, SvcTemplateRequest{Name: "report", AgentMD: svcTestAgent})
	d1, _ := out["digest"].(string)
	if st != http.StatusOK || d1 != SvcTemplateDigest(svcTestAgent) || out["name"] != "report" {
		t.Fatalf("register: %d %v", st, out)
	}
	if !svcAudited(t, h, "svc.template.put", "ok") {
		t.Error("no svc.template.put audit row")
	}
	created := out["created"]
	time.Sleep(5 * time.Millisecond)
	if st, again := svcPutTemplate(t, h, tok, SvcTemplateRequest{AgentMD: svcTestAgent}); st != http.StatusOK ||
		again["digest"] != d1 || again["created"] != created {
		t.Errorf("re-register is not the same row: %d %v (first created %v)", st, again, created)
	}
	_, out = svcPutTemplate(t, h, tok, SvcTemplateRequest{AgentMD: svcTestAgentV2})
	d2, _ := out["digest"].(string)
	if d2 == "" || d2 == d1 {
		t.Fatalf("a changed text kept its digest: %v", out)
	}

	for i, d := range []string{"sha256:" + d1, d2} {
		req := svcReq("space:ws:"+string(rune('a'+i)), "t"+string(rune('a'+i)))
		req.Template, req.TemplateDigest = "report", d
		ref := svcSubmit(t, h, tok, req)["run_id"].(string)
		tk := ops.expect(control.ClusterCreateSvcRun)
		if tk.Run != ref {
			t.Fatalf("ticket %+v for %s", tk, ref)
		}
		st, spec := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec?attempt=1", tk.Token, nil)
		want := map[int]string{0: svcTestAgent, 1: svcTestAgentV2}[i]
		if st != http.StatusOK || spec["agent_md"] != want || spec["template_digest"] != strings.TrimPrefix(d, "sha256:") {
			t.Errorf("run %d spec: %d %v", i, st, spec)
		}
	}

	req := svcReq("space:ws:c", "never")
	req.TemplateDigest = SvcTemplateDigest("---\nname: report\n---\nnever registered\n")
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	ops.quiet(300 * time.Millisecond)
	if got := svcState(t, h, tok, ref); got["state"] != store.SvcRunFailed || got["error_code"] != SvcErrTemplateInvalid {
		t.Errorf("unregistered digest: %v", got)
	}

	st, out = svcDo(t, h, http.MethodGet, SvcTemplatesPath, tok, nil)
	list, _ := out["templates"].([]any)
	digests := map[string]bool{}
	for _, x := range list {
		m := x.(map[string]any)
		if _, has := m["agent_md"]; has {
			t.Errorf("the list carries a text: %v", m)
		}
		digests[m["digest"].(string)] = true
	}
	if st != http.StatusOK || !digests[d1] || !digests[d2] || !digests[svcTestDigest] || len(list) != 3 {
		t.Errorf("list: %d %v", st, out)
	}
}

// A principal sees and runs only its own templates; templates:write is the
// write's scope.
func TestSvcTemplateOwnOnly(t *testing.T) {
	h := newFleetHarness(t)
	a := svcSetup(t, h, "alpha", "runs:write runs:read templates:write")
	b := svcSetup(t, h, "beta", "runs:write runs:read templates:write")
	reader := svcSetup(t, h, "gamma", "runs:read")
	if st, out := svcPutTemplate(t, h, a, SvcTemplateRequest{AgentMD: svcTestAgent}); st != http.StatusOK {
		t.Fatalf("register: %d %v", st, out)
	}
	if st, out := svcDo(t, h, http.MethodGet, SvcTemplatesPath, b, nil); st != http.StatusOK ||
		len(out["templates"].([]any)) != 0 {
		t.Errorf("beta sees alpha's: %d %v", st, out)
	}
	if _, err := h.srv.Store.SvcTemplateOf("svc:beta", SvcTemplateDigest(svcTestAgent)); err == nil {
		t.Error("beta may run alpha's digest")
	}
	if st, _ := svcPutTemplate(t, h, reader, SvcTemplateRequest{AgentMD: svcTestAgent}); st != http.StatusForbidden {
		t.Errorf("runs:read registered a template: %d", st)
	}
	if st, _ := svcDo(t, h, http.MethodGet, SvcTemplatesPath, reader, nil); st != http.StatusOK {
		t.Errorf("runs:read cannot list: %d", st)
	}
}

// What a template must be: a frontmatter name (matching name when given), at
// most 256 KiB.
func TestSvcTemplateRefusals(t *testing.T) {
	h := newFleetHarness(t)
	tok := svcSetup(t, h, "livepage", "templates:write runs:read")
	for why, req := range map[string]SvcTemplateRequest{
		"empty":          {},
		"no frontmatter": {AgentMD: "just words\n"},
		"no name":        {AgentMD: "---\ndescription: x\n---\nbody\n"},
		"open front":     {AgentMD: "---\nname: x\nbody\n"},
		"name mismatch":  {Name: "other", AgentMD: svcTestAgent},
	} {
		if st, out := svcPutTemplate(t, h, tok, req); st != http.StatusBadRequest {
			t.Errorf("%s: %d %v", why, st, out)
		}
	}
	big := "---\nname: big\n---\n" + strings.Repeat("x", svcTemplateMax)
	if st, _ := svcPutTemplate(t, h, tok, SvcTemplateRequest{AgentMD: big}); st != http.StatusRequestEntityTooLarge {
		t.Errorf("over 256 KiB: %d", st)
	}
	if _, why := svcTemplateName("---\nname: x\n---\n\xff\n"); why == "" {
		t.Error("non-UTF-8 text accepted")
	}
	if st, out := svcDo(t, h, http.MethodGet, SvcTemplatesPath, tok, nil); st != http.StatusOK ||
		len(out["templates"].([]any)) != 0 {
		t.Errorf("a refusal left a row: %v", out)
	}
}
