package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestScheduleWebOwnerBoundary(t *testing.T) {
	h := newFleetHarness(t)
	fixture := store.Schedule{Spec: schedule.Spec{ID: "schedule-test", Revision: 1, Name: "Private", Prompt: "Alice only", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}
	if _, e := h.srv.Store.SaveSchedule("alice", "create", "create", fixture, 0, time.Now()); e != nil {
		t.Fatal(e)
	}
	get := func(owner, path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", path, nil)
		r = r.WithContext(context.WithValue(r.Context(), principalKey{}, owner))
		w := httptest.NewRecorder()
		h.srv.handleSchedules(w, r)
		return w
	}
	if w := get("bob", SchedulesPath+"?id=schedule-test"); w.Code != 404 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := get("alice", SchedulesPath+"?id=schedule-test"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := get("", SchedulesPath); w.Code != 401 {
		t.Fatal("shared admin token got personal schedules", w.Code)
	}
	raw := []byte(`{"action":"pause","id":"schedule-test","revision":1,"idempotency_key":"edit"}`)
	r := httptest.NewRequest("POST", SchedulesPath, bytes.NewReader(raw))
	w := httptest.NewRecorder()
	h.srv.scheduleRequest(w, r, "bob", nil)
	if w.Code != 404 {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestScheduleNodeCannotSelectAnotherLogin(t *testing.T) {
	h, token, _ := newVaultHarness(t)
	fixture := store.Schedule{Endpoint: "another-node", Spec: schedule.Spec{ID: "schedule-other", Revision: 1, Name: "Own other login", Prompt: "notes", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}
	_, e := h.srv.Store.SaveSchedule(pAlice, "create", "create", fixture, 0, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("GET", NodeSchedulesPath+"?id=schedule-other", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.srv.handleNodeSchedules(w, r)
	if w.Code != 404 {
		t.Fatal(w.Code, w.Body.String())
	}
	r = httptest.NewRequest("GET", NodeSchedulesPath, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set(workerAssertHeader, "forged")
	w = httptest.NewRecorder()
	h.srv.handleNodeSchedules(w, r)
	if w.Code != 401 {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestScheduleNoticeNeverUsesToolTranscript(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	fixture := store.Schedule{Endpoint: "node", Spec: schedule.Spec{ID: "schedule-result", Revision: 1, Name: "Summary", Prompt: "private prompt", Delivery: schedule.Delivery{WeChat: true}, At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}
	row, e := h.srv.Store.SaveSchedule("alice", "create", "create", fixture, 0, now)
	if e != nil {
		t.Fatal(e)
	}
	_ = h.srv.Store.ScheduleSynced(row, "synced", "", "{}")
	run, e := h.srv.Store.AdmitSchedule("alice", "node", row.Spec.ID, "slot", 1, 1, false, now)
	if e != nil {
		t.Fatal(e)
	}
	run, e = h.srv.Store.FinishSchedule("alice", "node", run.ID, "succeeded", "final conclusion", "", "fid", now)
	if e != nil {
		t.Fatal(e)
	}
	msg, ok, e := h.srv.noticeMsg(store.Notice{Owner: "alice", Kind: "schedule_result", Refs: []string{run.ID}})
	if e != nil || !ok {
		t.Fatal(e)
	}
	raw, _ := json.Marshal(msg)
	if bytes.Contains(raw, []byte("private prompt")) || !bytes.Contains(raw, []byte("final conclusion")) {
		t.Fatal(string(raw))
	}
}
func TestScheduleCreateRejectsAdministrativeFields(t *testing.T) {
	h := newFleetHarness(t)
	for _, field := range []string{"login", "owner", "exec", "env", "credentials"} {
		raw := []byte(`{"action":"create","idempotency_key":"key","` + field + `":"bad"}`)
		r := httptest.NewRequest(http.MethodPost, SchedulesPath, bytes.NewReader(raw))
		w := httptest.NewRecorder()
		h.srv.scheduleRequest(w, r, "alice", nil)
		if w.Code != 400 {
			t.Fatal(field, w.Code)
		}
	}
}

func TestScheduleAgentCreateUpdateAndDefault(t *testing.T) {
	h := newFleetHarness(t)
	request := func(body string, status int) store.Schedule {
		t.Helper()
		w := httptest.NewRecorder()
		h.srv.scheduleRequest(w, httptest.NewRequest("POST", SchedulesPath, bytes.NewBufferString(body)), "alice", nil)
		if w.Code != status {
			t.Fatalf("%d: %s", w.Code, w.Body.String())
		}
		var response struct {
			Action   string         `json:"action"`
			Schedule store.Schedule `json:"schedule"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &response)
		if status == 200 {
			var input struct {
				Action string `json:"action"`
			}
			_ = json.Unmarshal([]byte(body), &input)
			if response.Action != input.Action {
				t.Fatalf("receipt action = %q, want %q", response.Action, input.Action)
			}
		}
		return response.Schedule
	}
	row := request(`{"action":"create","idempotency_key":"agent-create","name":"Brief","prompt":"Summarize","at":"07:00","agent":"claude"}`, 200)
	if row.Spec.Agent != "claude" {
		t.Fatal(row.Spec)
	}
	for i, tt := range []struct{ field, want string }{
		{`"name":"Renamed"`, "claude"},
		{`"agent":"codex"`, "codex"},
		{`"agent":""`, ""},
	} {
		row = request(fmt.Sprintf(`{"action":"update","id":"%s","revision":%d,"idempotency_key":"agent-edit-%d",%s}`, row.Spec.ID, row.Spec.Revision, i, tt.field), 200)
		if row.Spec.Agent != tt.want {
			t.Fatal(row.Spec)
		}
	}
	request(fmt.Sprintf(`{"action":"update","id":"%s","revision":%d,"idempotency_key":"agent-bad","agent":"other"}`, row.Spec.ID, row.Spec.Revision), 400)
	got, err := h.srv.Store.Schedule("alice", row.Spec.ID)
	if err != nil || got.Spec.Revision != row.Spec.Revision {
		t.Fatal(got, err)
	}
}

func TestScheduleAgentWaitsForCapableNode(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	row := store.Schedule{Owner: pAlice, Endpoint: "schedule-node", Hostname: "mac-c", Login: "alice", Spec: schedule.Spec{Agent: "claude"}}
	for _, capable := range []bool{false, true} {
		conn := &nodeConn{canSchedule: true, canScheduleAgent: capable}
		h.srv.nodes.put(row.Endpoint, conn)
		_, err := h.srv.scheduleTarget(context.Background(), row)
		if (err == nil) != capable {
			t.Fatalf("capable %v: %v", capable, err)
		}
		legacy := row
		legacy.Spec.Agent = ""
		if _, err := h.srv.scheduleTarget(context.Background(), legacy); err != nil {
			t.Fatal(err)
		}
		h.srv.nodes.drop(row.Endpoint, conn)
	}
}

func TestScheduleRequestsRuntimeWithSignInPlacementOff(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "none")
	const owner = "gh:6011"
	listPerson(t, h, owner, "scheduleuser")
	h.srv.placePrincipalRuntime(owner, "scheduleuser", owner, true)
	_, op := expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Login != "scheduleuser" {
		t.Fatal(op)
	}
}

func TestScheduleConsentSnapshotAndOutboxRecovery(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	row, e := h.srv.Store.SaveSchedule("alice", "create", "create", store.Schedule{Endpoint: "node", Spec: schedule.Spec{ID: "schedule-consent", Revision: 1, Name: "Notes", Prompt: "notes", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}, 0, now)
	if e != nil {
		t.Fatal(e)
	}
	_ = h.srv.Store.ScheduleSynced(row, "synced", "", "{}")
	run, e := h.srv.Store.AdmitSchedule("alice", "node", row.Spec.ID, "slot", 1, 1, false, now)
	if e != nil {
		t.Fatal(e)
	}
	row.Spec.Revision = 2
	row.Spec.Delivery.WeChat = true
	if _, e = h.srv.Store.SaveSchedule("alice", "edit", "edit", row, 1, now); e != nil {
		t.Fatal(e)
	}
	run, e = h.srv.Store.FinishSchedule("alice", "node", run.ID, "succeeded", "answer", "", "fid", now)
	if e != nil {
		t.Fatal(e)
	}
	h.srv.scheduleNotify(run)
	if n, _ := h.srv.Store.Notice("nt-schedule-" + run.ID); n != nil {
		t.Fatal("new opt-in sent an old run")
	}
	pending, e := h.srv.Store.ScheduleUnqueued()
	if e != nil || len(pending) != 0 {
		t.Fatal(pending, e)
	}
}

func TestScheduleSpaceProtocolAndUnknownPublication(t *testing.T) {
	initialized := false
	published := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("missing authorization")
		}
		var req struct {
			ID     int    `json:"id"`
			Method string `json:"method"`
			Params struct {
				Name string `json:"name"`
			} `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.Method == "notifications/initialized" {
			initialized = true
			w.WriteHeader(202)
			return
		}
		out := map[string]any{}
		if req.Method == "tools/call" {
			if !initialized {
				t.Error("tool before initialized notification")
			}
			published++
			out = map[string]any{"structuredContent": map[string]any{"proposal_id": "p", "url": "https://example.com/p", "status": "review"}}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": out})
	}))
	defer server.Close()
	m := &scheduleSpace{server: &Server{LivePage: &LivePagePartner{URL: server.URL}}, token: "test-key"}
	ctx := context.Background()
	if _, e := m.rpc(ctx, "initialize", map[string]any{}); e != nil {
		t.Fatal(e)
	}
	if _, e := m.rpc(ctx, "notifications/initialized", map[string]any{}); e != nil {
		t.Fatal(e)
	}
	out, e := m.tool(ctx, "publish_file", map[string]any{"quiet": true})
	if e != nil || out["status"] != "review" || published != 1 {
		t.Fatal(out, e)
	}
}

func TestSchedulePageDeliveryReceiptNeverPublishesTwice(t *testing.T) {
	for _, confirmed := range []bool{true, false} {
		t.Run(fmt.Sprint(confirmed), func(t *testing.T) {
			h, _, partner := livePageHarness(t)
			now := time.Now()
			published := 0
			initialized := false
			mcp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/mcp" {
					partner.srv.Config.Handler.ServeHTTP(w, r)
					return
				}
				var req struct {
					ID     int    `json:"id"`
					Method string `json:"method"`
					Params struct {
						Name      string         `json:"name"`
						Arguments map[string]any `json:"arguments"`
					} `json:"params"`
				}
				_ = json.NewDecoder(r.Body).Decode(&req)
				if req.Method == "notifications/initialized" {
					initialized = true
					w.WriteHeader(202)
					return
				}
				out := map[string]any{}
				if req.Method == "tools/call" && req.Params.Name == "publish_file" {
					if !initialized || req.Params.Arguments["quiet"] != true {
						t.Error("publication protocol")
					}
					published++
					if !confirmed {
						w.WriteHeader(503)
						return
					}
					out = map[string]any{"structuredContent": map[string]any{"proposal_id": "page", "url": "https://example.com/private", "status": "published", "version_id": "version"}}
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": out})
			}))
			defer mcp.Close()
			h.srv.LivePage.URL = mcp.URL
			row, e := h.srv.Store.SaveSchedule(pAlice, "create", "create", store.Schedule{Endpoint: "node", Spec: schedule.Spec{ID: "schedule-page", Revision: 1, Name: "Private notes", Prompt: "summarize", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true, Delivery: schedule.Delivery{LivePage: true}}}, 0, now)
			if e != nil {
				t.Fatal(e)
			}
			_ = h.srv.Store.ScheduleSynced(row, "synced", "", "{}")
			run, e := h.srv.Store.AdmitSchedule(pAlice, "node", row.Spec.ID, "slot", 1, 1, false, now)
			if e != nil {
				t.Fatal(e)
			}
			run, e = h.srv.Store.FinishSchedule(pAlice, "node", run.ID, "succeeded", "<private conclusion>", "", "fid", now)
			if e != nil {
				t.Fatal(e)
			}
			n := store.Notice{ID: "page-notice", Kind: "schedule_page", Owner: pAlice, Refs: []string{run.ID}}
			if e = h.srv.Store.EnqueueNotice(n, now); e != nil {
				t.Fatal(e)
			}
			h.srv.schedulePageDelivery(context.Background(), n, now)
			h.srv.schedulePageDelivery(context.Background(), n, now)
			if published != 1 {
				t.Fatalf("publication count %d", published)
			}
			run, _ = h.srv.Store.ScheduleRun(pAlice, run.ID)
			want := "sent"
			if !confirmed {
				want = "unconfirmed"
			}
			var delivery map[string]any
			_ = json.Unmarshal(run.Delivery, &delivery)
			if delivery["livepage"] != want {
				t.Fatal(string(run.Delivery))
			}
		})
	}
}

func TestScheduleConversationProvenance(t *testing.T) {
	h := newFleetHarness(t)
	st := h.srv.Store
	now := time.Now()
	fixture := store.Schedule{Endpoint: "node-a", Spec: schedule.Spec{ID: "schedule-history", Revision: 1, Name: "Group brief", Prompt: "Summary", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}
	row, err := st.SaveSchedule("alice", "create", "create", fixture, 0, now)
	if err != nil {
		t.Fatal(err)
	}
	if err = st.ScheduleSynced(row, "synced", "", "{}"); err != nil {
		t.Fatal(err)
	}
	run, err := st.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot", 1, 1, false, now)
	if err != nil {
		t.Fatal(err)
	}
	live := []FleetSession{{Worker: map[string]any{"identity": run.SessionID, "state": "working", "title": "schedule-internal"}, Availability: "online"}}
	board, err := h.srv.buildBoard("alice", live, now)
	loc, _ := time.LoadLocation("Asia/Shanghai")
	if err != nil || len(board.Rows) != 1 || board.Rows[0].ScheduleID != row.Spec.ID || board.Rows[0].RunID != run.ID || board.Rows[0].Title != "Group brief "+now.In(loc).Format("2006-01-02") {
		t.Fatalf("running source: %+v %v", board, err)
	}
	for _, owner := range []string{"alice", "bob"} {
		w := httptest.NewRecorder()
		h.srv.scheduleRequest(w, httptest.NewRequest("GET", SchedulesPath+"?session_id="+run.SessionID, nil), owner, nil)
		want := 200
		if owner == "bob" {
			want = 404
		}
		if w.Code != want {
			t.Fatalf("%s lookup: %d %s", owner, w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	h.srv.scheduleRequest(w, httptest.NewRequest("GET", SchedulesPath+"?session_id="+run.SessionID, nil), "alice", &store.Endpoint{ID: "node-b"})
	if w.Code != 404 {
		t.Fatal("another login read provenance", w.Code)
	}
	if _, err = st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "alice", EndpointID: "node-a", Machine: "mac-a", Login: "alice", ID: run.SessionID, Events: []map[string]any{
		{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "title": "internal"},
		{"ev": "named", "seq": float64(2), "ts": float64(now.Unix()), "title": "My chosen title", "source": "manual"},
		{"ev": "closed", "seq": float64(3), "ts": float64(now.Unix()), "reason": "reaped"},
	}}); err != nil {
		t.Fatal(err)
	}
	board, err = h.srv.buildBoard("alice", nil, now)
	if err != nil || len(board.Rows) != 1 || board.Rows[0].Title != "My chosen title" || board.Rows[0].RunID != run.ID {
		t.Fatalf("closed/manual source: %+v %v", board, err)
	}
}
