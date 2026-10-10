package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2893 (EPIC #2889 C4): the hub takes a computer's diagnostic
// bundle on its ticket, keeps it seven days, opens a debugger for it, and
// serves what the debugger concluded as one page at a short link only that
// computer and an admin can open.

// debugReportHarness: debug tickets on, the repo's own shape table, the
// debugger's start replaced by a recorder, and a node enrolled as the
// debugger's login ("dbg") and one as the orchestrator's ("orch").
type debugStarts struct {
	mu    sync.Mutex
	seeds []string
	err   error
}

func (d *debugStarts) start(_ context.Context, rep store.DebugReport, seed string) (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.seeds = append(d.seeds, seed)
	if d.err != nil {
		return "", d.err
	}
	return "ep_dbg", nil
}

func (d *debugStarts) n() int { d.mu.Lock(); defer d.mu.Unlock(); return len(d.seeds) }

func debugReportHarness(t *testing.T) (*harness, *debugClock, *debugStarts) {
	t.Helper()
	h, clk, _ := debugHarness(t)
	starts := &debugStarts{}
	h.srv.Debug.ShapesFile = filepath.Join("..", "..", "..", "conf", "secret-shapes.list")
	h.srv.Debug.Start = starts.start
	h.srv.Debug.Notify = "macmini/verky"
	for label, who := range map[string][2]string{"dbg": {"macmini", "fleetdebug"}, "orch": {"macmini", "verky"}} {
		h.enroll(t, label)
		ident := model.Identity{AccountUUID: "acct-" + label, Hostname: who[0], OSUser: who[1]}
		if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
			t.Fatal(err)
		}
		if _, _, err := h.srv.Store.TouchEndpoint("ep_"+label, ident, "test", true, nil); err != nil {
			t.Fatal(err)
		}
	}
	return h, clk, starts
}

// debugBundleTGZ is a C1-shaped bundle: files under one top directory, a
// manifest naming each with its sha256. tamper edits a file after the
// manifest is written; extra adds a file the manifest does not name.
func debugBundleTGZ(t *testing.T, files map[string]string, tamper, extra map[string]string) []byte {
	t.Helper()
	type mf struct {
		Path   string `json:"path"`
		SHA256 string `json:"sha256"`
	}
	m := struct {
		V     int  `json:"v"`
		Files []mf `json:"files"`
	}{V: 1}
	for _, n := range sortedKeysS(files) {
		sum := sha256.Sum256([]byte(files[n]))
		m.Files = append(m.Files, mf{n, hex.EncodeToString(sum[:])})
	}
	man, _ := json.Marshal(m)
	all := map[string]string{"manifest.json": string(man)}
	for k, v := range files {
		all[k] = v
	}
	for k, v := range tamper {
		all[k] = v
	}
	for k, v := range extra {
		all[k] = v
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	_ = tw.WriteHeader(&tar.Header{Name: "bundle/", Typeflag: tar.TypeDir, Mode: 0o755})
	for _, n := range sortedKeysS(all) {
		_ = tw.WriteHeader(&tar.Header{Name: "bundle/" + n, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(all[n]))})
		_, _ = tw.Write([]byte(all[n]))
	}
	_ = tw.Close()
	_ = zw.Close()
	return buf.Bytes()
}

var debugGoodFiles = map[string]string{
	"doctor.txt":       "  FAIL  tls  CERTIFICATE_VERIFY_FAILED (python.org python3 has no CA bundle)\n",
	"route.txt":        "hub: dns ok · tls: <redacted:authorization>\n",
	"logs/connect.log": "2026-10-10T06:00:00Z connect m5 via relay: closed by client after 1s\n",
	"system.txt":       "macOS 15.1 · arm64\n",
	"tools.txt":        "python3 /Library/Frameworks/Python.framework/Versions/3.13/bin/python3\n",
}

func debugUpload(t *testing.T, h *harness, tok, fp string, bundle []byte, note string) (int, map[string]any, string) {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, _ := mw.CreateFormFile("bundle", "fleet-debug.tar.gz")
	_, _ = fw.Write(bundle)
	if note != "" {
		_ = mw.WriteField("note", note)
	}
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+DebugBundlePath, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "FleetDebug "+tok)
	req.Header.Set("X-Fleet-FP", fp)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return resp.StatusCode, out, string(b)
}

func debugGet(t *testing.T, url string, hdr map[string]string, cookies ...*http.Cookie) (int, string, *http.Response) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	for _, c := range cookies {
		req.AddCookie(c)
	}
	cl := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := cl.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp
}

func debugNode(t *testing.T, h *harness, label, method, path string, body any) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	req.Header.Set("Authorization", "Bearer "+h.tokens[label])
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func waitDebugState(t *testing.T, h *harness, id, want string) *store.DebugReport {
	t.Helper()
	for i := 0; i < 200; i++ {
		rep, err := h.srv.Store.DebugReport(id)
		if err != nil {
			t.Fatal(err)
		}
		if rep != nil && rep.State == want {
			return rep
		}
		time.Sleep(10 * time.Millisecond)
	}
	rep, _ := h.srv.Store.DebugReport(id)
	t.Fatalf("report %s never reached %s: %+v", id, want, rep)
	return nil
}

var goodResult = map[string]any{
	"cause":    "这台电脑的 python3 是 python.org 装的，没装证书库，连入口的 TLS 握手失败。",
	"evidence": []string{"doctor.txt：tls 行 FAIL CERTIFICATE_VERIFY_FAILED", "tools.txt：python3 来自 python.org"},
	"steps": []map[string]any{
		{"why": "给这份 python3 装上证书库", "cmd": "/Applications/Python\\ 3.13/Install\\ Certificates.command", "system": true},
		{"why": "重新登录", "cmd": "fleet login"},
	},
	"ours": []string{"安装时检查 python3 的证书库，缺了就提示"},
}

func TestDebugBundleToPage(t *testing.T) {
	h, _, starts := debugReportHarness(t)
	tok := issueTicket(t, h, fpA, "203.0.113.7")
	auth := map[string]string{"Authorization": "FleetDebug " + tok, "X-Fleet-FP": fpA}
	bundle := debugBundleTGZ(t, debugGoodFiles, nil, nil)

	code, out, raw := debugUpload(t, h, tok, fpA, bundle, "登不进去，卡在正在连接 m5")
	if code != 200 {
		t.Fatalf("upload = %d %s", code, raw)
	}
	id, _ := out["id"].(string)
	if !debugIDRe.MatchString(id) || out["url"] != h.http.URL+"/s/"+id || out["again"] != false ||
		!strings.HasPrefix(out["open_url"].(string), h.http.URL+"/s/"+id+"?k=") {
		t.Fatalf("upload answer = %s", raw)
	}
	if !regexp.MustCompile(`https?://[^[:space:]]+/s/[A-Za-z0-9]{8}`).MatchString(out["url"].(string)) {
		t.Fatalf("the short link is not the drill's shape: %v", out["url"])
	}
	waitDebugState(t, h, id, store.DebugDiagnosing)
	if starts.n() != 1 {
		t.Fatalf("starts = %d", starts.n())
	}
	seed := starts.seeds[0]
	first := strings.SplitN(seed, "\n", 2)[0]
	if !strings.Contains(first, "/s/"+id) || !strings.Contains(first, "dt_") || strings.Contains(first, "m5") {
		t.Fatalf("the seed's first line (the desk ticket's) must carry the ticket and link only: %q", first)
	}
	if !strings.Contains(seed, "「登不进去，卡在正在连接 m5」") || !strings.Contains(seed, "debug_bundle") {
		t.Fatalf("seed = %q", seed)
	}
	dir := filepath.Join(h.srv.Debug.Dir, id)
	for _, f := range []string{"bundle.tar.gz", "hub.json"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Fatalf("%s not kept: %v", f, err)
		}
	}

	// the same bytes again: the same report, the upload given back
	code, out2, raw := debugUpload(t, h, tok, fpA, bundle, "")
	if code != 200 || out2["id"] != id || out2["again"] != true {
		t.Fatalf("the same bundle again = %d %s", code, raw)
	}
	if starts.n() != 1 {
		t.Fatalf("a re-upload opened a second debugger")
	}

	// status: the ticket of this computer, the admin; never a stranger's ticket
	code, body, _ := debugGet(t, h.http.URL+"/v1/fleet/debug/"+id, auth)
	if code != 200 || !strings.Contains(body, `"state":"diagnosing"`) || regexp.MustCompile(`已出结论|concluded|没看完|unfinished`).MatchString(body) {
		t.Fatalf("status while diagnosing = %d %s", code, body)
	}
	tokB := issueTicket(t, h, fpB, "203.0.113.8")
	if code, body, _ := debugGet(t, h.http.URL+"/v1/fleet/debug/"+id, map[string]string{"Authorization": "FleetDebug " + tokB, "X-Fleet-FP": fpB}); code != 404 {
		t.Fatalf("another computer's ticket read the status: %d %s", code, body)
	}
	if code, _, _ := debugGet(t, h.http.URL+"/v1/fleet/debug/"+id, map[string]string{"Authorization": "Bearer " + viewerToken}); code != 200 {
		t.Fatalf("the admin cannot read the status: %d", code)
	}

	// the page: nobody else → 404; the ticket's headers or its browser cookie → the page
	if code, _, _ := debugGet(t, h.http.URL+"/s/"+id, nil); code != 404 {
		t.Fatalf("/s/<id> with no ticket = %d, want 404", code)
	}
	if code, _, _ := debugGet(t, h.http.URL+"/s/"+id, map[string]string{"Authorization": "FleetDebug " + tokB, "X-Fleet-FP": fpB}); code != 404 {
		t.Fatalf("/s/<id> with another computer's ticket = %d, want 404", code)
	}
	if code, body, _ := debugGet(t, h.http.URL+"/s/"+id, auth); code != 200 || !strings.Contains(body, "诊断员正在看") {
		t.Fatalf("/s/<id> with the ticket = %d %s", code, body)
	}
	code, _, resp := debugGet(t, out["open_url"].(string), nil)
	if code != 302 || len(resp.Cookies()) != 1 {
		t.Fatalf("open_url = %d %v", code, resp.Cookies())
	}
	if code, _, _ := debugGet(t, h.http.URL+"/s/"+id, nil, resp.Cookies()[0]); code != 200 {
		t.Fatalf("/s/<id> with the open_url cookie = %d", code)
	}
	if code, _, _ := debugGet(t, h.http.URL+"/s/"+id+"?k=nope", nil); code != 404 {
		t.Fatalf("a wrong k = %d, want 404", code)
	}

	// the node doors: only the login the report was sent to
	if code, _ := debugNode(t, h, "orch", "GET", NodeDebugPrefix+id+"/bundle", nil); code != 404 {
		t.Fatalf("another login read the bundle: %d", code)
	}
	if code, body := debugNode(t, h, "dbg", "GET", NodeDebugPrefix+id+"/bundle", nil); code != 200 || body != string(bundle) {
		t.Fatalf("the debugger's login cannot read the bundle: %d", code)
	}
	code, body = debugNode(t, h, "dbg", "GET", NodeDebugPrefix+id+"/hub.json", nil)
	if code != 200 || !strings.Contains(body, `"report": "`+id+`"`) || !strings.Contains(body, "这张票不知道是谁的") {
		t.Fatalf("hub.json = %d %s", code, body)
	}

	// publish: a broken result is refused, naming what is wrong
	for _, c := range []struct {
		name string
		edit func(m map[string]any)
		want string
	}{
		{"no cause", func(m map[string]any) { m["cause"] = "" }, "缺「是什么问题」"},
		{"no evidence", func(m map[string]any) { m["evidence"] = []string{} }, "缺「证据」"},
		{"four steps", func(m map[string]any) {
			m["steps"] = []map[string]any{{"why": "a", "cmd": "a"}, {"why": "b", "cmd": "b"}, {"why": "c", "cmd": "c"}, {"why": "d", "cmd": "d"}}
		}, "最多 3 步"},
		{"no ours", func(m map[string]any) { delete(m, "ours") }, "缺「要我们改的」"},
		{"a token in a step", func(m map[string]any) {
			m["steps"] = []map[string]any{{"why": "登录", "cmd": "export GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789"}}
		}, "steps[0].cmd 里有像"},
		{"two lines", func(m map[string]any) { m["steps"] = []map[string]any{{"why": "x", "cmd": "a\nb"}} }, "要是一行"},
	} {
		m := map[string]any{}
		for k, v := range goodResult {
			m[k] = v
		}
		c.edit(m)
		if code, body := debugNode(t, h, "dbg", "POST", NodeDebugPrefix+id+"/page", m); code != 400 || !strings.Contains(body, c.want) {
			t.Fatalf("%s: publish = %d %s", c.name, code, body)
		}
	}
	if code, _ := debugNode(t, h, "orch", "POST", NodeDebugPrefix+id+"/page", goodResult); code != 404 {
		t.Fatalf("another login published: %d", code)
	}
	if code, body := debugNode(t, h, "dbg", "POST", NodeDebugPrefix+id+"/page", goodResult); code != 200 || !strings.Contains(body, "concluded") {
		t.Fatalf("publish = %d %s", code, body)
	}
	code, body, _ = debugGet(t, h.http.URL+"/v1/fleet/debug/"+id, auth)
	if code != 200 || !strings.Contains(body, "已出结论") || !strings.Contains(body, "took_secs") {
		t.Fatalf("status once concluded = %d %s", code, body)
	}
	code, page, _ := debugGet(t, h.http.URL+"/s/"+id, auth)
	if code != 200 {
		t.Fatalf("page = %d", code)
	}
	heads := regexp.MustCompile(`(?is)<h[1-4][^>]*>(.*?)</h[1-4]>`).FindAllStringSubmatch(page, -1)
	var hs []string
	for _, hm := range heads {
		hs = append(hs, hm[1])
	}
	if strings.Join(hs, "|") != "远端诊断|是什么问题|证据|请你做|要我们改的" {
		t.Fatalf("the page's headings = %v", hs)
	}
	codes := regexp.MustCompile(`(?is)<code[^>]*>(.*?)</code>`).FindAllStringSubmatch(page, -1)
	if len(codes) != 2 || codes[1][1] != "fleet login" || !strings.Contains(page, "会改系统设置") {
		t.Fatalf("请你做's commands = %v", codes)
	}

	// propose: a line for the orchestrator, never twice
	for i := 0; i < 2; i++ {
		if code, body := debugNode(t, h, "dbg", "POST", NodeDebugPrefix+id+"/propose", map[string]string{"text": "client 连续失败时自动提示"}); code != 200 {
			t.Fatalf("propose = %d %s", code, body)
		}
	}
	rep, _ := h.srv.Store.DebugReport(id)
	if len(rep.Ours) != 2 || rep.Ours[1] != "client 连续失败时自动提示" {
		t.Fatalf("ours = %v", rep.Ours)
	}

	// the feed: the orchestrator's login only
	if code, _ := debugNode(t, h, "dbg", "GET", NodeDebugPrefix+"feed", nil); code != 404 {
		t.Fatalf("the debugger's login read the feed: %d", code)
	}
	code, body = debugNode(t, h, "orch", "GET", NodeDebugPrefix+"feed", nil)
	var feed struct {
		Reports []map[string]any `json:"reports"`
	}
	_ = json.Unmarshal([]byte(body), &feed)
	if code != 200 || len(feed.Reports) != 1 || feed.Reports[0]["state"] != "concluded" ||
		!strings.Contains(fmt.Sprint(feed.Reports[0]["cause"]), "证书库") || feed.Reports[0]["who"] != "fp aaaaaaaa" {
		t.Fatalf("feed = %d %s", code, body)
	}
	after := feed.Reports[0]["updated_at"].(string)
	code, body = debugNode(t, h, "orch", "GET", NodeDebugPrefix+"feed?after="+after, nil)
	if code != 200 || strings.Contains(body, id) {
		t.Fatalf("the feed after its cursor = %d %s", code, body)
	}

	// the admin deletes it: gone, the page a 404 (C6's teardown)
	req, _ := http.NewRequest(http.MethodDelete, h.http.URL+"/v1/fleet/debug/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("delete = %v %v", resp, err)
	}
	resp.Body.Close()
	if code, _, _ := debugGet(t, h.http.URL+"/s/"+id, auth); code != 404 {
		t.Fatalf("/s/<id> after delete = %d", code)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("the report's directory survived the delete: %v", err)
	}
}

func TestDebugBundleRefusals(t *testing.T) {
	h, _, starts := debugReportHarness(t)
	tok := issueTicket(t, h, fpA, "203.0.113.9")
	for _, c := range []struct {
		name   string
		bundle []byte
		want   string
	}{
		{"tampered", debugBundleTGZ(t, debugGoodFiles, map[string]string{"doctor.txt": "all fine\n"}, nil), "sha256"},
		{"an unlisted file", debugBundleTGZ(t, debugGoodFiles, nil, map[string]string{"extra.txt": "x"}), "不在 manifest.json 里"},
		{"a token left in", debugBundleTGZ(t, map[string]string{"route.txt": "Authorization: Bearer abcdefghijklmnop"}, nil, nil), "里还有"},
		{"a github token", debugBundleTGZ(t, map[string]string{"logs/x.log": "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"}, nil, nil), "里还有"},
		{"not a tar.gz", []byte("hello"), "tar.gz"},
	} {
		code, _, raw := debugUpload(t, h, tok, fpA, c.bundle, "")
		if code != 400 || !strings.Contains(raw, c.want) {
			t.Fatalf("%s: upload = %d %s", c.name, code, raw)
		}
	}
	if starts.n() != 0 {
		t.Fatalf("a refused bundle opened a debugger")
	}
	if rows, _ := h.srv.Store.DebugReports(time.Time{}); len(rows) != 0 {
		t.Fatalf("a refused bundle left a report: %v", rows)
	}
	big := make([]byte, debugMaxBundleBytes+10)
	if code, _, raw := debugUpload(t, h, tok, fpA, big, ""); code != 413 && code != 429 {
		t.Fatalf("an oversize bundle = %d %s", code, raw)
	}
	if code, _, _ := debugUpload(t, h, "fdt1.forged.sig", fpA, debugBundleTGZ(t, debugGoodFiles, nil, nil), ""); code != 401 {
		t.Fatalf("a forged ticket = %d", code)
	}
}

func TestDebugTickUnfinishedAndPrune(t *testing.T) {
	h, clk, starts := debugReportHarness(t)
	tok := issueTicket(t, h, fpA, "203.0.113.10")
	_, out, raw := debugUpload(t, h, tok, fpA, debugBundleTGZ(t, debugGoodFiles, nil, nil), "")
	id, _ := out["id"].(string)
	if id == "" {
		t.Fatalf("upload: %s", raw)
	}
	waitDebugState(t, h, id, store.DebugDiagnosing)
	clk.add(10 * time.Minute)
	h.srv.debugTick(clk.now())
	waitDebugState(t, h, id, store.DebugDiagnosing)
	clk.add(6 * time.Minute)
	h.srv.debugTick(clk.now())
	rep := waitDebugState(t, h, id, store.DebugUnfinished)
	if !strings.Contains(rep.Why, "已转给管理员") {
		t.Fatalf("why = %q", rep.Why)
	}
	auth := map[string]string{"Authorization": "FleetDebug " + tok, "X-Fleet-FP": fpA}
	if _, body, _ := debugGet(t, h.http.URL+"/v1/fleet/debug/"+id, auth); !strings.Contains(body, "没看完") || strings.Contains(body, "concluded") {
		t.Fatalf("status once unfinished = %s", body)
	}

	// a debugger that cannot be opened: unfinished at once, why said
	starts.err = fmt.Errorf("macmini/fleetdebug 上没有在线的 fleet")
	_, out2, _ := debugUpload(t, h, tok, fpA, debugBundleTGZ(t, map[string]string{"doctor.txt": "other\n"}, nil, nil), "")
	rep2 := waitDebugState(t, h, out2["id"].(string), store.DebugUnfinished)
	if !strings.Contains(rep2.Why, "没能开诊断会话") {
		t.Fatalf("why = %q", rep2.Why)
	}

	// seven days on: the report, its bundle and its page are gone
	clk.add(debugKeep + time.Minute)
	h.srv.debugTick(clk.now())
	for _, x := range []string{id, out2["id"].(string)} {
		if rep, _ := h.srv.Store.DebugReport(x); rep != nil {
			t.Fatalf("report %s survived seven days", x)
		}
		if _, err := os.Stat(filepath.Join(h.srv.Debug.Dir, x)); !os.IsNotExist(err) {
			t.Fatalf("report %s's directory survived seven days", x)
		}
	}
}

func TestDebugSessionsQueueWhenSpent(t *testing.T) {
	h, _, starts := debugReportHarness(t)
	tok := issueTicket(t, h, fpA, "203.0.113.11")
	var ids []string
	for i := 0; i < debugSessionsPerDay+1; i++ {
		_, out, raw := debugUpload(t, h, tok, fpA, debugBundleTGZ(t, map[string]string{"doctor.txt": fmt.Sprintf("run %d\n", i)}, nil, nil), "")
		id, _ := out["id"].(string)
		if id == "" {
			t.Fatalf("upload %d: %s", i, raw)
		}
		ids = append(ids, id)
	}
	last := ids[len(ids)-1]
	rep := waitDebugState(t, h, last, store.DebugQueued)
	if !strings.Contains(rep.Why, "等管理员点头") {
		t.Fatalf("why = %q", rep.Why)
	}
	for _, id := range ids[:len(ids)-1] {
		waitDebugState(t, h, id, store.DebugDiagnosing)
	}
	if starts.n() != debugSessionsPerDay {
		t.Fatalf("starts = %d, want %d", starts.n(), debugSessionsPerDay)
	}
	// the admin nods: the queued report gets its debugger
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/debug/"+last+"/start", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusAccepted {
		t.Fatalf("start = %v %v", resp, err)
	}
	resp.Body.Close()
	waitDebugState(t, h, last, store.DebugDiagnosing)
}

func TestDebugWorkerStartArgument(t *testing.T) {
	ok := map[string]any{"idempotency_key": "k1", "kind": "scratch", "no_repo": true, "debug": "abcdefgh", "body": "x"}
	w, _, err := parseWrite("worker_start", ok)
	if err != nil || w.params["debug"] != "abcdefgh" {
		t.Fatalf("a debugger start = %v %v", w.params, err)
	}
	for name, args := range map[string]map[string]any{
		"issue kind":    {"idempotency_key": "k", "issue": 5, "debug": "abcdefgh"},
		"repo scratch":  {"idempotency_key": "k", "kind": "scratch", "repo": "o/r", "debug": "abcdefgh"},
		"bad id":        {"idempotency_key": "k", "kind": "scratch", "no_repo": true, "debug": "ABC;rm -rf"},
		"with the test": {"idempotency_key": "k", "kind": "scratch", "no_repo": true, "test": true, "debug": "abcdefgh"},
	} {
		if _, _, err := parseWrite("worker_start", args); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}

func TestDebugReportsOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	for _, p := range []string{DebugBundlePath, "/v1/fleet/debug/abcdefgh", DebugReportsPath} {
		code, body := debugPost(t, h.http.URL+p, map[string]string{"fp": fpA}, nil)
		ucode, ubody := debugPost(t, h.http.URL+"/v1/fleet/no-such-route", map[string]string{"fp": fpA}, nil)
		if code != ucode || string(body) != string(ubody) {
			t.Fatalf("%s off = %d %q, an unknown path = %d %q", p, code, body, ucode, ubody)
		}
	}
	for _, p := range []string{"/s/abcdefgh", NodeDebugPrefix + "feed", NodeDebugPrefix + "abcdefgh/bundle"} {
		code, body, _ := debugGet(t, h.http.URL+p, nil)
		ucode, ubody, _ := debugGet(t, h.http.URL+"/zz/no-such-route", nil)
		if strings.HasPrefix(p, "/v1/") {
			ucode, ubody, _ = debugGet(t, h.http.URL+"/v1/node/no-such-route", nil)
		}
		if code != ucode || body != ubody {
			t.Fatalf("%s off = %d %q, an unknown path = %d %q", p, code, body, ucode, ubody)
		}
	}
}
