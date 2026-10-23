package api

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

func capacityProfile(plan string, units float64, now time.Time) store.PlanCapacityProfile {
	return store.PlanCapacityProfile{Plan: plan, Tier: "confirmed", Pool: "codex", Unit: "reference-work", Basis: "same verified workload", Source: "https://example.com/capacity-evidence", Version: "v1", Confidence: "verified", EffectiveFrom: now.Add(-time.Hour), Windows: []store.PlanCapacityWindow{{Minutes: 300, Units: units}, {Minutes: 10080, Units: units}}}
}

func TestCodexCapacityArithmeticAndWindows(t *testing.T) {
	now := time.Now()
	inputs := make([]codexQuotaInput, 2)
	for i, units := range []float64{1, 10} {
		q := selectionFixture(now)
		used := 20.0
		if i == 1 {
			used = 70
		}
		for j := range q.Windows {
			q.Windows[j].UsedPercent = used
		}
		p := capacityProfile(fmt.Sprint(i), units, now)
		inputs[i] = codexQuota(q, nil, now, &p)
		inputs[i].Capacity.Profile = &p
		applyCodexCapacity(&inputs[i], p, now)
	}
	if math.Abs(*inputs[0].Capacity.EstimatedRemaining-0.8) > 1e-9 || math.Abs(*inputs[1].Capacity.EstimatedRemaining-3) > 1e-9 {
		t.Fatal(inputs)
	}
	choices := []store.Credential{{PrincipalID: "pool", Account: "small"}, {PrincipalID: "pool", Account: "large"}}
	if codexOrder(choices, inputs)[0] != 1 {
		t.Fatal("larger capacity at lower percent did not win")
	}
	for _, tc := range []struct {
		name  string
		edit  func(*store.PlanCapacityProfile)
		state string
	}{
		{"weekly only", func(p *store.PlanCapacityProfile) { p.Windows = p.Windows[1:] }, "usable"},
		{"missing expected", func(p *store.PlanCapacityProfile) {}, "unknown"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := capacityProfile("pro", 1, now)
			tc.edit(&p)
			q := selectionFixture(now)
			q.Windows = q.Windows[1:]
			out := codexQuota(q, nil, now, &p)
			if out.State != tc.state {
				t.Fatal(out)
			}
			out.Capacity.Profile = &p
			applyCodexCapacity(&out, p, now)
			if (out.Score != nil) != (tc.state == "usable") {
				t.Fatal(out)
			}
		})
	}
	p := capacityProfile("pro", 1, now)
	for _, which := range []int{0, 1} {
		q := selectionFixture(now)
		q.Windows[which].UsedPercent = 100
		out := codexQuota(q, nil, now, &p)
		applyCodexCapacity(&out, p, now)
		if out.State != "limited" || out.Score != nil {
			t.Fatal("bottleneck hidden", out)
		}
	}
	q := selectionFixture(now)
	q.ObservedAt = now.Add(-11 * time.Minute)
	out := codexQuota(q, nil, now, &p)
	applyCodexCapacity(&out, p, now)
	if out.State != "unknown" || out.Score != nil {
		t.Fatal(out)
	}
}

func registerCapacityRig(t *testing.T) (*cpRig, time.Time, store.PlanCapacityCatalog) {
	t.Helper()
	r := newCPRig(t)
	now := time.Now()
	if err := r.h.srv.Vault.Put("pool", "codex", "poolcx2", credvault.Secret{RefreshToken: "fixture", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	p1, p10 := capacityProfile("fixture-plan", 1, now), capacityProfile("fixture-plan", 10, now)
	p1.Tier = "small"
	p10.Tier = "large"
	cat := store.PlanCapacityCatalog{Mode: "active", Profiles: []store.PlanCapacityProfile{p1, p10}}
	for i, label := range []string{"poolcx", "poolcx2"} {
		tier := "small"
		used := 20.0
		if i == 1 {
			tier = "large"
			used = 70
		}
		if err := r.h.srv.Vault.SetPlan("pool", "codex", label, "fixture-plan", tier); err != nil {
			t.Fatal(err)
		}
		codexSelectionQuota(t, r, label, now, used, used, 4*time.Hour, 6*24*time.Hour)
	}
	if _, err := r.h.srv.Store.SetPlanCapacities(cat, 0, "fixture-admin", now); err != nil {
		t.Fatal(err)
	}
	return r, now, cat
}

func TestCodexCapacitySelectionHysteresisCAS(t *testing.T) {
	r, now, cat := registerCapacityRig(t)
	s := r.h.srv
	choices, err := s.sessionBindChoices("gh:1005", "", "codex")
	if err != nil {
		t.Fatal(err)
	}
	inputs := s.codexSelectionInputs(choices, store.SessionBind{WorkerID: "new"}, now, cat)
	if inputs[0].Capacity.Calibration != 1 || inputs[0].Capacity.CalibrationStatus != "pending_matched_observations" {
		t.Fatal(inputs)
	}
	for _, tc := range []struct {
		name, setBy string
		age         time.Duration
		boundary    bool
		want        string
	}{
		{"initial", "", 0, true, "poolcx2"}, {"hold", "auto", 9 * time.Minute, true, "poolcx"}, {"exact hold", "auto", 10 * time.Minute, true, "poolcx2"}, {"manual", "operator", time.Hour, true, "poolcx"}, {"inflight", "auto", time.Hour, false, "poolcx"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := store.SessionBind{WorkerID: tc.name, SetBy: tc.setBy, UpdatedAt: now.Add(-tc.age)}
			if tc.name != "initial" {
				b.Owner = "pool"
				b.Account = "poolcx"
			}
			pick, why := s.codexSelect(choices, b, now, tc.boundary)
			if pick.Account != tc.want {
				t.Fatal(pick.Account, why)
			}
		})
	}
	_, err = s.Store.SetSessionBind(store.SessionBind{WorkerID: "capacity-parallel", Provider: "codex", Owner: "pool", Account: "poolcx", SetBy: "auto"}, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b, err := s.sessionBind("capacity-parallel", "gh:1005", "", "codex", now, true)
			if err == nil && (b.Account != "poolcx2" || b.Rev != 2) {
				err = fmt.Errorf("binding %+v", b)
			}
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	// Same percentages preserve the registered tier ratio; no fake weights.
	codexSelectionQuota(t, r, "poolcx2", now.Add(time.Second), 20, 20, 4*time.Hour, 6*24*time.Hour)
	inputs = s.codexSelectionInputs(choices, store.SessionBind{WorkerID: "new"}, now.Add(time.Second), cat)
	if math.Abs(*inputs[1].Capacity.EstimatedRemaining / *inputs[0].Capacity.EstimatedRemaining - 10) > 1e-9 {
		t.Fatal(inputs)
	}
	// A 25% threshold is strict: a similar score cannot churn the session.
	inputs[1].Score = new(float64)
	*inputs[1].Score = 1
	inputs[0].Score = new(float64)
	*inputs[0].Score = 1.25
	pick, why := codexChoose(choices, inputs, store.SessionBind{WorkerID: "hold", Owner: "pool", Account: "poolcx2", SetBy: "auto", UpdatedAt: now.Add(-time.Hour)}, now, true)
	if pick != 1 || why != "no_material_gain" {
		t.Fatal(pick, why)
	}
}

func TestCodexCapacityRendezvousAndIncomparability(t *testing.T) {
	r, now, cat := registerCapacityRig(t)
	s := r.h.srv
	cat.Profiles[1].Windows = cat.Profiles[0].Windows
	now = now.Add(time.Second)
	codexSelectionQuota(t, r, "poolcx2", now, 20, 20, 4*time.Hour, 6*24*time.Hour)
	choices, _ := s.sessionBindChoices("gh:1005", "", "codex")
	counts := map[int]int{}
	for i := 0; i < 200; i++ {
		b := store.SessionBind{WorkerID: fmt.Sprint("worker-", i)}
		a := s.codexSelectionInputs(choices, b, now, cat)
		p, _ := codexChoose(choices, a, b, now, true)
		again, _ := codexChoose(choices, s.codexSelectionInputs(choices, b, now, cat), b, now, true)
		if p != again {
			t.Fatal("unstable choice")
		}
		counts[p]++
	}
	if counts[0] < 60 || counts[1] < 60 {
		t.Fatal("alphabetical concentration", counts)
	}
	// Mixed units/bases disable capacity ranking for the whole cohort.
	cat.Profiles[1].Basis = "unrelated workload"
	a := s.codexSelectionInputs(choices, store.SessionBind{WorkerID: "cohort"}, now, cat)
	if codexComparable(a[0], a[1]) {
		t.Fatal("incomparable capacity")
	}
}

func TestCodexCapacityUnknownProfiles(t *testing.T) {
	r, now, cat := registerCapacityRig(t)
	s := r.h.srv
	c, _ := s.Store.Credential("pool", "codex", "poolcx")
	for _, tc := range []struct {
		name   string
		change func(*store.PlanCapacityCatalog)
		want   string
	}{
		{"missing", func(c *store.PlanCapacityCatalog) { c.Profiles = nil }, "baseline_unknown"},

		{"not effective", func(c *store.PlanCapacityCatalog) { c.Profiles[0].EffectiveFrom = now.Add(time.Hour) }, "baseline_outside_effective_period"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			copy := cat
			copy.Profiles = append([]store.PlanCapacityProfile{}, cat.Profiles...)
			tc.change(&copy)
			got := s.codexQuotaForCatalog(*c, now, copy)
			if got.Score != nil || got.Capacity.Status != tc.want {
				t.Fatal(got)
			}
		})
	}
	if err := s.Vault.SetPlan("pool", "codex", "poolcx", "different-plan", "small"); err != nil {
		t.Fatal(err)
	}
	c, _ = s.Store.Credential("pool", "codex", "poolcx")
	got := s.codexQuotaForCatalog(*c, now, cat)
	if got.Score != nil || got.Capacity.Status != "plan_mismatch" {
		t.Fatal(got)
	}
}

func TestCodexCapacityAdminPreviewReadOnly(t *testing.T) {
	r, now, _ := registerCapacityRig(t)
	s := r.h.srv
	_, wid := r.issue(t, fidA)
	before, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: wid, Provider: "codex", Owner: "pool", Account: "poolcx", SetBy: "operator"}, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	request := func(body string) map[string]any {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, codexPreviewPath, strings.NewReader(body))
		w := httptest.NewRecorder()
		s.handleCodexPreview(w, req)
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	out := request(fmt.Sprintf(`{"worker_id":%q}`, wid))
	if out["proposed"].(map[string]any)["reason"] != "explicit_binding" {
		t.Fatal(out)
	}
	out = request(fmt.Sprintf(`{"worker_id":%q,"new_session":true}`, wid))
	if out["proposed"].(map[string]any)["account"] != "poolcx2" {
		t.Fatal(out)
	}
	after, err := s.Store.SessionBindFor(wid, "codex")
	if err != nil || before != after {
		t.Fatal("preview mutated binding", before, after, err)
	}
	for _, body := range []string{`{"worker_id":"unknown"}`, fmt.Sprintf(`{"worker_id":%q,"principal_id":"other"}`, wid)} {
		w := httptest.NewRecorder()
		s.handleCodexPreview(w, httptest.NewRequest(http.MethodPost, codexPreviewPath, strings.NewReader(body)))
		if w.Code < 400 {
			t.Fatal("scope override accepted", w.Body.String())
		}
	}
}

func TestCapacityCatalogAPIValidationAndAuthorization(t *testing.T) {
	h, admin, user := rolesHarness(t)
	call := func(method, path, body string, cookie *http.Cookie) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(method, h.http.URL+path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		if cookie != nil {
			req.AddCookie(cookie)
		}
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(raw)
	}
	for _, path := range []string{planCapacitiesPath, codexPreviewPath} {
		if code, _ := call("POST", path, `{}`, user); code != 403 {
			t.Fatal("member allowed", path, code)
		}
		if code, _ := call("POST", path, `{}`, nil); code != 401 {
			t.Fatal("anonymous allowed", path, code)
		}
	}
	p := capacityProfile("pro", 1, time.Now())
	cat := store.PlanCapacityCatalog{Mode: "shadow", Profiles: []store.PlanCapacityProfile{p}}
	put := func(rev int64, c store.PlanCapacityCatalog) (int, string) {
		body, _ := json.Marshal(map[string]any{"expected_revision": rev, "catalog": c})
		return call("PUT", planCapacitiesPath, string(body), admin)
	}
	invalid := cat
	invalid.Profiles = append([]store.PlanCapacityProfile{}, cat.Profiles...)
	invalid.Profiles[0].Source = ""
	if code, _ := put(0, invalid); code != 400 {
		t.Fatal(code)
	}
	if code, _ := call("PUT", planCapacitiesPath, `{"expected_revision":0,"catalog":{"mode":"shadow","profiles":[]},"priority":10}`, admin); code != 400 {
		t.Fatal("unknown priority accepted", code)
	}
	if code, _ := put(-1, cat); code != 400 {
		t.Fatal("invalid revision", code)
	}
	if code, body := put(0, cat); code != 200 {
		t.Fatal(code, body)
	}
	if code, _ := put(0, cat); code != 409 {
		t.Fatal("lost update accepted", code)
	}
	if code, body := put(1, store.PlanCapacityCatalog{Mode: "off", Profiles: []store.PlanCapacityProfile{}}); code != 200 {
		t.Fatal(code, body)
	}
	if code, body := put(2, cat); code != 200 {
		t.Fatal(code, body)
	}
	code, body := call("GET", planCapacitiesPath, "", admin)
	if code != 200 || !strings.Contains(body, `"revision":3`) || !strings.Contains(body, p.Source) || !strings.Contains(body, p.Version) {
		t.Fatal(code, body)
	}
	history, err := h.srv.Store.PlanCapacityHistory()
	if err != nil || len(history) != 3 || history[0].Actor == "operator" {
		t.Fatal("unaudited actor", history, err)
	}
}

func TestCodexProviderPlanRegisteredTier(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	claims, _ := json.Marshal(map[string]any{"https://api.openai.com/auth": map[string]any{"chatgpt_plan_type": "pro", "chatgpt_account_id": "fixture-account"}})
	idToken := "h." + base64.RawURLEncoding.EncodeToString(claims) + ".s"
	if err := h.srv.Vault.Put("pool", "codex", "provider-plan", credvault.Secret{RefreshToken: "fixture", IDToken: idToken, AccountID: "fixture-account"}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	cat := store.PlanCapacityCatalog{Mode: "active", Profiles: []store.PlanCapacityProfile{capacityProfile("pro", 10, now)}}
	for _, tc := range []struct{ plan, tier, status string }{
		{"pro", "confirmed", "quota_unknown"}, {"different", "confirmed", "plan_mismatch"}, {"", "", "baseline_unknown"},
	} {
		if err := h.srv.Vault.SetPlan("pool", "codex", "provider-plan", tc.plan, tc.tier); err != nil {
			t.Fatal(err)
		}
		c, _ := h.srv.Store.Credential("pool", "codex", "provider-plan")
		meta, _ := h.srv.codexCapacityProfile(*c, nil, cat, now)
		if meta.Plan != "pro" || meta.PlanSource != "provider" || meta.Status != tc.status {
			t.Fatal(meta)
		}
		wantTier := ""
		if tc.plan == "pro" {
			wantTier = "confirmed"
		}
		if got := h.srv.Vault.PlanTier(*c); got != wantTier {
			t.Fatal("mismatched tier exposed", got)
		}
		var list struct {
			Credentials []struct {
				PlanSource string `json:"plan_source"`
				PlanTier   string `json:"plan_tier"`
			}
		}
		h.getJSON(t, "/v1/fleet/credentials?principal_id=pool", &list)
		if len(list.Credentials) != 1 || list.Credentials[0].PlanSource != "provider" || list.Credentials[0].PlanTier != wantTier {
			t.Fatal(list)
		}
	}
}

func TestCodexCapacity429KeepsExplicitBinding(t *testing.T) {
	r, now, _ := registerCapacityRig(t)
	s := r.h.srv
	pass, wid := r.issue(t, fidA)
	before, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: wid, Provider: "codex", Owner: "pool", Account: "poolcx", SetBy: "operator"}, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	c, _ := s.Store.Credential("pool", "codex", "poolcx")
	status, out := sessDo(t, r.h, http.MethodPost, CredProxyRebindPath, cpToken, "", map[string]any{"cred": pass, "provider": "codex", "account": "poolcx", "owner": "pool", "credential_id": s.Vault.CredentialID(*c)})
	if status != 200 || out["account"] != "poolcx" || out["rebind_from"] != nil {
		t.Fatal(status, out)
	}
	after, err := s.Store.SessionBindFor(wid, "codex")
	if err != nil || before != after {
		t.Fatal("quota report overwrote explicit binding", before, after, err)
	}
	if !s.limits.limited("codex", "pool", s.Vault.CredentialID(*c), now) {
		t.Fatal("quota evidence was lost")
	}
}

func TestCodexCapacityKeepsSourceAffinity(t *testing.T) {
	r, now, _ := registerCapacityRig(t)
	s := r.h.srv
	source, _ := s.Store.Credential("pool", "codex", "poolcx")
	ref := credproxy.CodexReference("id", "fixture-response")
	if err := s.Store.RecordCodexAffinity("capacity-affinity", []string{ref}, store.CodexAffinity{Owner: "pool", Account: "poolcx", CredentialID: s.Vault.CredentialID(*source), AccountKey: "source-key"}, now); err != nil {
		t.Fatal(err)
	}
	bound, _, err := s.codexAffinityBind("capacity-affinity", "gh:1005", "", credproxy.CodexRoute{Independent: true}, now)
	if err != nil || bound.Account != "poolcx2" {
		t.Fatal("capacity pick", bound, err)
	}
	origin, _, err := s.codexAffinityBind("capacity-affinity", "gh:1005", "", credproxy.CodexRoute{References: []string{ref}}, now)
	if err != nil || origin.Account != "poolcx" {
		t.Fatal("reference crossed subscription", origin, err)
	}
	actual, err := s.Store.SessionBindFor("capacity-affinity", "codex")
	if err != nil || actual != bound {
		t.Fatal("continuation changed sticky", actual, err)
	}
	s.limits.mark("codex", "pool", s.Vault.CredentialID(*source), now.Add(time.Hour))
	if _, _, err := s.codexAffinityBind("capacity-affinity", "gh:1005", "", credproxy.CodexRoute{References: []string{ref}}, now); err == nil {
		t.Fatal("unavailable source was rerouted")
	}
}

func TestCodexCapacityReviewBoundaries(t *testing.T) {
	r, now, cat := registerCapacityRig(t)
	now = now.Add(time.Second)
	cat.Profiles[0].Confidence = "provisional"
	cat.Profiles[1].Confidence = "provisional"
	s := r.h.srv
	codexSelectionQuota(t, r, "poolcx", now, 50, 50, 4*time.Hour, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", now, 90, 90, 4*time.Hour, 6*24*time.Hour)
	choices, _ := s.sessionBindChoices("gh:1005", "", "codex")
	b := store.SessionBind{WorkerID: "review", Owner: "pool", Account: "poolcx", SetBy: "auto", UpdatedAt: now.Add(-time.Hour)}
	in := s.codexSelectionInputs(choices, b, now, cat)
	if in[1].State != "tight" || in[1].Capacity.Profile.Confidence != "provisional" {
		t.Fatal(in)
	}
	pick, why := codexChoose(choices, in, b, now, true)
	if pick != 1 || why != "material_capacity_advantage" {
		t.Fatal(pick, why, in)
	}
	b.Account = "poolcx2"
	if pick, _ := codexChoose(choices, in, b, now, true); pick != 1 {
		t.Fatal("tight capacity churn")
	}
	p := capacityProfile("pro", 1, now)
	p.Windows = p.Windows[1:]
	q := selectionFixture(now)
	q.Windows = q.Windows[1:]
	q.Observation = "transcript"
	if got := codexQuota(q, nil, now, &p); got.State != "unknown" || got.Reason != "incomplete_window_evidence" {
		t.Fatal(got)
	}
	q.Observation = "app_server"
	if got := codexQuota(q, nil, now, &p); got.State != "unknown" {
		t.Fatal(got)
	}
	q = selectionFixture(now)
	q.Windows[0].UsedPercent = 100
	q.ObservedAt = now.Add(-20 * time.Minute)
	if got := codexQuota(q, nil, now, &p); got.State != "limited" {
		t.Fatal("unexpected full stale window ignored", got)
	}
}

func TestCodexCapacitySharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../shared/credproxy/testdata/capacity_policy.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors []struct {
		Name                           string
		Units, Used, Remaining, Scores []float64
		States                         []string
		Pick                           int
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for _, v := range vectors {
		t.Run(v.Name, func(t *testing.T) {
			in := []codexQuotaInput{}
			choices := []store.Credential{}
			for i, u := range v.Units {
				p := capacityProfile("vector", u, now)
				q := selectionFixture(now)
				for j := range q.Windows {
					q.Windows[j].UsedPercent = v.Used[i]
				}
				got := codexQuota(q, nil, now, &p)
				got.Capacity.Profile = &p
				applyCodexCapacity(&got, p, now)
				if got.State != v.States[i] || math.Abs(*got.Score-v.Scores[i]) > 1e-9 || math.Abs(*got.Capacity.EstimatedRemaining-v.Remaining[i]) > 1e-9 {
					t.Fatal(got)
				}
				in = append(in, got)
				choices = append(choices, store.Credential{PrincipalID: "pool", Account: fmt.Sprint(i)})
			}
			if got := codexOrder(choices, in)[0]; got != v.Pick {
				t.Fatal(got)
			}
		})
	}
}

func TestCodexCapacityNodeMetadataScopedReadOnly(t *testing.T) {
	h, tok, ref := newVaultHarness(t)
	now := time.Now()
	for _, owner := range []string{pAlice, "pool", "unrelated"} {
		if err := h.srv.Vault.Put(owner, "codex", owner, credvault.Secret{RefreshToken: "fixture", AccountID: owner}); err != nil {
			t.Fatal(err)
		}
	}
	call := func(token string) (int, string) {
		req := httptest.NewRequest("GET", nodeCapacityPath, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.srv.handleNodeCapacity(w, req)
		return w.Code, w.Body.String()
	}
	if code, _ := call(""); code != 401 {
		t.Fatal(code)
	}
	if _, err := h.srv.Store.SetPlanCapacities(store.PlanCapacityCatalog{Mode: "shadow"}, 0, "test", now); err != nil {
		t.Fatal(err)
	}
	code, raw := call(tok)
	if code != 200 || strings.Contains(raw, "unrelated") || strings.Contains(raw, "fixture") || !strings.Contains(raw, `"mutates_bindings":false`) {
		t.Fatal(code, raw)
	}
	if ref.n.Load() != 0 {
		t.Fatal("metadata refreshed credentials")
	}
	var out struct {
		Accounts  []struct{ Account string }
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil || len(out.Accounts) != 2 || out.ExpiresAt.Sub(now) > 31*time.Second {
		t.Fatal(out, err)
	}
	if err := h.srv.Store.Revoke("mac-c", pAlice, "test", now); err != nil {
		t.Fatal(err)
	}
	if code, _ := call(tok); code != 403 {
		t.Fatal("revoked node got metadata", code)
	}
}

func TestCodexCapacityPreviewUnboundWorker(t *testing.T) {
	r, _, _ := registerCapacityRig(t)
	_, wid := r.issue(t, fidA)
	w := httptest.NewRecorder()
	r.h.srv.handleCodexPreview(w, httptest.NewRequest("POST", codexPreviewPath, strings.NewReader(fmt.Sprintf(`{"worker_id":%q}`, wid))))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var out struct {
		Binding  store.SessionBind
		Proposed struct{ Account string }
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || out.Binding.WorkerID != wid || out.Proposed.Account != "poolcx2" {
		t.Fatal(out, err)
	}
	if _, err := r.h.srv.Store.SessionBindFor(wid, "codex"); err != store.ErrNoSessionBind {
		t.Fatal("preview created binding", err)
	}
	choices, _ := r.h.srv.sessionBindChoices("gh:1005", "", "codex")
	b := store.SessionBind{WorkerID: wid, Provider: "codex"}
	// Initial selection has no opportunistic boundary, including svc principals.
	actual, _ := r.h.srv.codexSelect(choices, b, time.Now(), false)
	if actual.Account != out.Proposed.Account {
		t.Fatal(actual, out)
	}
}

// Snapshot shape supplied by the operator: complete Hub account API reads with
// only a primary weekly window. Units below are arbitrary test inputs, never a
// claim about actual subscription sizes or a ratio derived from monthly price.
func TestCodexCapacityWeeklyOperatorEstimatePreview(t *testing.T) {
	r, now, _ := registerCapacityRig(t)
	now = time.Now()
	s := r.h.srv
	_, wid := r.issue(t, fidA)
	labels := []string{"poolcx", "poolcx2"}
	plans := []string{"promax", "prolite"}
	tiers := []string{"operator-confirmed-a", "operator-confirmed-b"}
	remaining := []float64{89, 15}
	cat := store.PlanCapacityCatalog{Mode: "shadow"}
	for i, label := range labels {
		if err := s.Vault.SetPlan("pool", "codex", label, plans[i], tiers[i]); err != nil {
			t.Fatal(err)
		}
		c, err := s.Store.Credential("pool", "codex", label)
		if err != nil || c == nil {
			t.Fatal(err)
		}
		reset := now.Add(6 * 24 * time.Hour)
		q := model.QuotaSnapshot{Source: "codex", AccountUUID: s.Vault.CredentialID(*c), EndpointID: HubQuotaEndpoint,
			ObservedAt: now, Observation: "account_api", Plan: plans[i],
			Pools:   []model.QuotaPool{{LimitID: "codex"}},
			Windows: []model.QuotaWindow{{ID: "codex:primary", LimitID: "codex", Minutes: 10080, UsedPercent: 100 - remaining[i], ResetsAt: &reset}}}
		if err := s.Store.InsertQuota(q); err != nil {
			t.Fatal(err)
		}
		unknown := s.codexQuotaForCatalog(*c, now.Add(time.Second), store.PlanCapacityCatalog{Mode: "off"})
		if unknown.State != "unknown" || unknown.Reason != "missing_dual_window" || unknown.Score != nil || unknown.Capacity.Status != "baseline_unknown" {
			t.Fatal(unknown)
		}
		p := capacityProfile(plans[i], 1, now)
		p.Tier, p.Confidence = tiers[i], "provisional"
		p.Source, p.Basis = "operator:explicit-low-confidence-estimate", "low-confidence normalized fixture work; no official ratio"
		p.Windows = p.Windows[1:]
		if i == 0 {
			p.Windows[0].Units = 2
		}
		cat.Profiles = append(cat.Profiles, p)
	}
	if _, err := s.Store.SetPlanCapacities(cat, 1, "fixture-operator", now); err != nil {
		t.Fatal(err)
	}
	preview := func(want float64) {
		t.Helper()
		w := httptest.NewRecorder()
		s.handleCodexPreview(w, httptest.NewRequest("POST", codexPreviewPath, strings.NewReader(fmt.Sprintf(`{"worker_id":%q,"new_session":true}`, wid))))
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		var out struct {
			Mode    string
			Mutates bool `json:"mutates_bindings"`
			Inputs  []codexQuotaInput
		}
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out.Mode != "shadow" || out.Mutates || len(out.Inputs) != 2 {
			t.Fatal(w.Body.String())
		}
		for _, input := range out.Inputs {
			if len(input.Windows) != 1 || input.Windows[0].Minutes != 10080 || input.Capacity.Status != "estimated" || input.Capacity.Profile.Confidence != "provisional" || input.Capacity.Profile.Source != cat.Profiles[0].Source {
				t.Fatal(input)
			}
			estimate := .15
			if input.Account == labels[0] {
				estimate = want
			}
			if input.Capacity.EstimatedRemaining == nil || math.Abs(*input.Capacity.EstimatedRemaining-estimate) > 1e-9 {
				t.Fatal(input)
			}
		}
		if _, err := s.Store.SessionBindFor(wid, "codex"); err != store.ErrNoSessionBind {
			t.Fatal("preview wrote binding", err)
		}
	}
	preview(1.78)
	cat.Profiles[0].Windows[0].Units = 3
	cat.Profiles[0].Version = "operator-edit-v2"
	if _, err := s.Store.SetPlanCapacities(cat, 2, "fixture-operator", now); err != nil {
		t.Fatal(err)
	}
	preview(2.67)
}
