package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// task J7BN: /v1/chat/open with a DeepSeek model is placed by the hub on a
// mainland (cn) machine of the person's — never relayed to the home — and the
// new-session page is told whether to offer it (/v1/chat/home's models).

// regionChatRig: frank's mac-d (busy, the home) and mac-c (idle), both
// alice's; the cluster fleet.clusters lists may be named mac-c.
func regionChatRig(t *testing.T) (*harness, *writeNode, *writeNode, string) {
	t.Helper()
	h, macD, macC, _, f4 := twoNodes(t)
	enablePeople(t, h, pAlice, pBob)
	p, err := h.srv.Store.AdoptPrincipal(pAlice, "frank", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range []string{"mac-c", "mac-d"} {
		if err := h.srv.Store.AdoptAccount(p, m, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	setChatHome(t, h, pAlice, "mac-d", "frank")
	return h, macD, macC, f4.FleetID
}

var regionChatHdr = map[string]string{"X-Fleet-Webchat": "1", "Content-Type": "application/json"}

func regionOpen(t *testing.T, h *harness, who, body string) (*http.Response, map[string]any) {
	t.Helper()
	resp := chatDo(t, h, http.MethodPost, "/v1/chat/open", personCookie(who, "alice"), regionChatHdr, body)
	b, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return resp, out
}

func TestChatOpenRegionRefusals(t *testing.T) {
	h, macD, macC, _ := regionChatRig(t)
	for _, c := range []struct {
		body string
		st   int
		code string
	}{
		{`{"agent":"claude","model":"gpt-5","text":"hi"}`, 400, "model"},
		{`{"agent":"codex","model":"deepseek","text":"hi"}`, 400, "model"},
		{`{"model":7}`, 400, "model"},
		// no cn cluster listed: DeepSeek on the web is the mainland region's
		{`{"model":"deepseek","text":"hi"}`, 503, "no_region_machine"},
	} {
		resp, out := regionOpen(t, h, pAlice, c.body)
		if resp.StatusCode != c.st || out["code"] != c.code {
			t.Fatalf("%s = %d %v; want %d %s", c.body, resp.StatusCode, out, c.st, c.code)
		}
	}
	setRegion(t, h, ClustersKey, "mac-c", ClusterRegionPrefix+"mac-c", regionCN, RegionCNPeopleKey, pBob)
	if resp, out := regionOpen(t, h, pAlice, `{"model":"deepseek-pro","text":"hi"}`); resp.StatusCode != 403 || out["code"] != "region_not_allowed" {
		t.Fatalf("unlisted alice = %d %v; want 403 region_not_allowed", resp.StatusCode, out)
	}
	// Listed, but the cn cluster is none of alice's machines.
	setRegion(t, h, ClustersKey, "ack-sz", ClusterRegionPrefix+"ack-sz", regionCN, RegionCNPeopleKey, pAlice)
	if resp, out := regionOpen(t, h, pAlice, `{"model":"deepseek","text":"hi"}`); resp.StatusCode != 503 || out["code"] != "no_region_machine" {
		t.Fatalf("no cn machine of alice's = %d %v; want 503 no_region_machine", resp.StatusCode, out)
	}
	if macD.count() != 0 || macC.count() != 0 {
		t.Fatalf("a refused open sent a write: mac-d=%d mac-c=%d", macD.count(), macC.count())
	}
}

func TestChatOpenRegionPlacesOnCN(t *testing.T) {
	h, macD, macC, fleet := regionChatRig(t)
	setRegion(t, h, ClustersKey, "mac-c", ClusterRegionPrefix+"mac-c", regionCN, RegionCNPeopleKey, "*",
		CredPodProvidersPrefix+"mac-c", "*")
	const fid = "5d0b1b0e-7f43-4f3e-9a51-6c1f6c2b8e11"
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": fleet + "/" + fid, "identity": fid}}}))
	resp, out := regionOpen(t, h, pAlice, `{"agent":"claude","model":"DeepSeek","text":"  整理这周的日报  "}`)
	if resp.StatusCode != 200 || out["state"] != "sent" || out["fid"] != fid || out["worker"] != fleet+"/"+fid ||
		out["model"] != "deepseek" || out["agent"] != "claude" || out["machine"] != "mac-c" {
		t.Fatalf("open = %d %v; want sent on mac-c with its fid and worker", resp.StatusCode, out)
	}
	if macD.count() != 0 || macC.count() != 1 {
		t.Fatalf("writes mac-d=%d mac-c=%d; want 0 and 1 (never the home)", macD.count(), macC.count())
	}
	env := macC.writes[0]
	params := env["params"].(map[string]any)
	if env["action"] != "worker_start" || params["model"] != "deepseek" || params["agent"] != "claude" ||
		params["no_repo"] != true || params["kind"] != "scratch" || params["body"] != "整理这周的日报" {
		t.Fatalf("mac-c was sent %v; want a no-repo claude scratch, model deepseek, the words its seed", env)
	}
	if _, ok := params["repo"]; ok {
		t.Fatalf("a repo went with a no-repo open: %v", params)
	}
}

// No model: the home's open, as before — here a home whose agent has no chat
// relay, so the relay's own answer (never a placement).
func TestChatOpenNoModelGoesHome(t *testing.T) {
	h, macD, macC, _ := regionChatRig(t)
	setRegion(t, h, ClustersKey, "mac-c", ClusterRegionPrefix+"mac-c", regionCN, RegionCNPeopleKey, "*")
	resp, out := regionOpen(t, h, pAlice, `{"agent":"claude","text":"hi"}`)
	if code, _ := out["code"].(string); resp.StatusCode == 200 || strings.HasPrefix(code, "region") || code == "no_region_machine" || code == "model" {
		t.Fatalf("no-model open = %d %v; want the home relay's refusal", resp.StatusCode, out)
	}
	if macD.count() != 0 || macC.count() != 0 {
		t.Fatalf("a no-model open placed a start: mac-d=%d mac-c=%d", macD.count(), macC.count())
	}
}

func TestChatHomeModels(t *testing.T) {
	h, _, _, _ := regionChatRig(t)
	read := func(who string) map[string]any {
		resp := chatDo(t, h, http.MethodGet, "/v1/chat/home", personCookie(who, "x"), nil, "")
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return out
	}
	if out := read(pAlice); out["models"] != nil {
		t.Fatalf("no cn cluster: models offered %v", out)
	}
	setRegion(t, h, ClustersKey, "mac-c", ClusterRegionPrefix+"mac-c", regionCN, RegionCNPeopleKey, pAlice)
	out := read(pAlice)
	ms, _ := out["models"].([]any)
	if len(ms) != 2 || ms[0].(map[string]any)["id"] != "deepseek" || ms[1].(map[string]any)["label"] != "DeepSeek Pro" {
		t.Fatalf("listed alice: models %v", out)
	}
	if out := read(pBob); out["models"] != nil || out["state"] != "no_home" {
		t.Fatalf("unlisted bob (no home): %v; want no models", out)
	}
}
