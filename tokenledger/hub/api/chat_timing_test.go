package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func chatTimingDo(t *testing.T, h *harness, pid string, hdr bool, body any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+ChatPathPrefix+chatTimingRoute, bytes.NewReader(b))
	if hdr {
		req.Header.Set("X-Fleet-Webchat", "1")
	}
	listPerson(t, h, pid, "")
	req.AddCookie(personCookie(pid, "timer"))
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	raw, _ := io.ReadAll(resp.Body)
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

// A new web session's wait (task PNWW): the page's clock is kept with its
// stages, the agent and the zone — never who — and the admin reads each
// stage's spread, all and mainland apart.
func TestChatTimingKeptAndStats(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	starts := []map[string]any{
		{"ms": 14000, "open_ms": 2000, "shown_ms": 3000, "agent": "claude", "tz": "Asia/Shanghai"},
		{"ms": 20000, "open_ms": 3000, "shown_ms": 5000, "agent": "codex", "tz": "Asia/Shanghai"},
		{"ms": 9000, "open_ms": 1000, "shown_ms": 2000, "agent": "claude", "tz": "America/Los_Angeles"},
	}
	for i, in := range starts {
		if code, out := chatTimingDo(t, h, "gh:8101", true, in); code != http.StatusOK || out["kept"] != true {
			t.Fatalf("timing %d = %d %v", i, code, out)
		}
	}
	// a cross-site form cannot set the header
	if code, _ := chatTimingDo(t, h, "gh:8101", false, starts[0]); code != http.StatusForbidden {
		t.Fatalf("no X-Fleet-Webchat = %d; want 403", code)
	}
	for _, bad := range []map[string]any{{"ms": 0}, {"ms": -1}, {"ms": 600*1000 + 1}, {"ms": 1000, "open_ms": 2000}, {"ms": 1000, "shown_ms": -1}} {
		if code, _ := chatTimingDo(t, h, "gh:8101", true, bad); code != http.StatusBadRequest {
			t.Fatalf("%v = %d; want 400", bad, code)
		}
	}
	// an odd zone or agent is kept unlabelled, never refused
	if code, _ := chatTimingDo(t, h, "gh:8101", true, map[string]any{"ms": 5000, "agent": "x", "tz": "<script>"}); code != http.StatusOK {
		t.Fatalf("odd labels = %d; want 200", code)
	}
	ts, err := h.srv.Store.ChatTimings(time.Now().Add(-time.Hour))
	if err != nil || len(ts) != 4 {
		t.Fatalf("kept = %v %v", ts, err)
	}
	if last := ts[3]; last.Agent != "" || last.TZ != "" {
		t.Fatalf("odd labels kept as %+v", last)
	}
	st := chatTimingStatsOf(7, ts[:3])
	if st.All.Reply.N != 3 || *st.All.Reply.MedianSecs != 14 || *st.All.Reply.P90Secs != 20 {
		t.Fatalf("all = %+v", st.All.Reply)
	}
	if st.Mainland.Reply.N != 2 || st.Mainland.Open.N != 2 || st.Mainland.Shown.N != 2 {
		t.Fatalf("mainland = %+v", st.Mainland)
	}
	// The admin's route; a member gets nothing from it.
	if code, _ := asUID(t, h, http.MethodGet, ChatTimingStatsPath, "gh:8101", "", nil); code == http.StatusOK {
		t.Fatalf("a member read the timing stats")
	}
}

// The spread never mixes a start with no stage into a stage's numbers.
func TestChatTimingSpreadSkipsMissingStages(t *testing.T) {
	sp := chatSpread([]store.ChatTiming{{MS: 8000}, {MS: 12000, OpenMS: 1500}})
	if sp.Reply.N != 2 || sp.Open.N != 1 || sp.Shown.N != 0 || sp.Shown.MedianSecs != nil {
		t.Fatalf("spread = %+v", sp)
	}
}

func TestChatTimingDailyAgentsAndIdempotentReceipt(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	in := map[string]any{"id": "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", "ms": 1200, "agent": "codex"}
	for i := 0; i < 2; i++ {
		if code, _ := chatTimingDo(t, h, "gh:8101", true, in); code != 200 {
			t.Fatal(code)
		}
	}
	xs, err := h.srv.Store.ChatTimings(time.Now().Add(-time.Hour))
	if err != nil || len(xs) != 1 {
		t.Fatalf("retry: %+v %v", xs, err)
	}
	in["id"] = "not-a-uuid"
	if code, _ := chatTimingDo(t, h, "gh:8101", true, in); code != 400 {
		t.Fatal(code)
	}
	at := time.Date(2026, 10, 20, 23, 59, 0, 0, time.UTC)
	st := chatTimingStatsOf(7, []store.ChatTiming{{At: at, Agent: "claude", MS: 1000}, {At: at.Add(time.Minute), Agent: "claude", MS: 3000}, {At: at, Agent: "codex", MS: 2000}})
	if st.Daily["2026-10-20"]["claude"].Reply.N != 1 || st.Daily["2026-10-21"]["claude"].Reply.N != 1 || st.Agents["claude"].Reply.N != 2 || *st.Agents["codex"].Reply.P90Secs != 2 {
		t.Fatalf("daily: %+v", st)
	}
}
