package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

type scheduleListBody struct {
	Schedules []json.RawMessage `json:"schedules"`
	Limits    map[string]int    `json:"limits"`
	Used      map[string]int    `json:"used"`
	Others    *[]scheduleOther  `json:"others"`
}

// Task PVG9: one owner's limits raised by the hub's config, everyone else on
// the documented defaults; the list shows what is enforced, and a login sees
// (read only) what its owner's other logins hold.
func TestScheduleLimitsOverridePerOwner(t *testing.T) {
	h, token, _ := newVaultHarness(t)
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(token))
	if err != nil {
		t.Fatal(err)
	}
	h.srv.ScheduleLimits = store.ScheduleOverrides{pAlice: {Tasks: 12, DailySlots: 72, DailyStarts: 31}}
	now := time.Now()
	spec := func(id, at, cron string) schedule.Spec {
		return schedule.Spec{ID: id, Revision: 1, Name: id, Prompt: "secret prompt", At: at, Cron: cron, Timezone: "Asia/Shanghai", Enabled: true}
	}
	here, err := h.srv.Store.SaveScheduleWithin(h.srv.scheduleLimitsFor(pAlice), pAlice, "here", "here", store.Schedule{Endpoint: ep.ID, Hostname: "mac-c", Login: "alice", Spec: spec("schedule-here", "", "7 * * * *")}, 0, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.srv.Store.SaveScheduleWithin(h.srv.scheduleLimitsFor(pAlice), pAlice, "there", "there", store.Schedule{Endpoint: "ep-other", Hostname: "mac-z", Login: "alice2", Spec: spec("schedule-there", "08:00", "")}, 0, now); err != nil {
		t.Fatal(err)
	}
	if _, err = h.srv.Store.SaveSchedule("bob", "bob", "bob", store.Schedule{Endpoint: "ep-bob", Spec: spec("schedule-bob", "", "9 * * * *")}, 0, now); err != nil {
		t.Fatal(err)
	}

	node := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		h.srv.handleNodeSchedules(w, r)
		return w
	}
	web := func(owner, method, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, SchedulesPath, bytes.NewBufferString(body))
		w := httptest.NewRecorder()
		h.srv.scheduleRequest(w, r, owner, nil)
		return w
	}
	decode := func(w *httptest.ResponseRecorder) scheduleListBody {
		t.Helper()
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		var b scheduleListBody
		if err := json.Unmarshal(w.Body.Bytes(), &b); err != nil {
			t.Fatal(err)
		}
		return b
	}

	// The node's list: the override, this login's one schedule, and the other
	// login's as a compact read-only row (no prompt).
	w := node("GET", NodeSchedulesPath, "")
	b := decode(w)
	if fmt.Sprint(b.Limits) != fmt.Sprint(map[string]int{"tasks": 12, "daily_slots": 72, "daily_starts": 31, "concurrent": 1}) {
		t.Fatal("limits", b.Limits)
	}
	if len(b.Schedules) != 1 || b.Others == nil || len(*b.Others) != 1 {
		t.Fatal("split", w.Body.String())
	}
	o := (*b.Others)[0]
	if o != (scheduleOther{ID: "schedule-there", Name: "schedule-there", Login: "alice2", Machine: "mac-z", At: "08:00", Timezone: "Asia/Shanghai", Enabled: true, Slots: 1}) {
		t.Fatalf("other: %+v", o)
	}
	if b.Used["tasks"] != 2 || b.Used["daily_slots"] != 25 {
		t.Fatal("used", b.Used)
	}
	if bytes.Contains(w.Body.Bytes(), []byte("schedule-bob")) || bytes.Count(w.Body.Bytes(), []byte("secret prompt")) != 1 {
		t.Fatal("leak", w.Body.String())
	}
	// The other login's schedule stays read-only from here.
	if w := node("POST", NodeSchedulesPath, `{"action":"pause","id":"schedule-there","revision":1,"idempotency_key":"pause-there"}`); w.Code != 404 {
		t.Fatal("edited another login's schedule", w.Code, w.Body.String())
	}

	// The web list: everything, no "others"; bob on the defaults.
	if b := decode(web(pAlice, "GET", "")); len(b.Schedules) != 2 || b.Others != nil || b.Limits["daily_slots"] != 72 {
		t.Fatalf("web: %+v", b)
	}
	if b := decode(web("bob", "GET", "")); fmt.Sprint(b.Limits) != fmt.Sprint(map[string]int{"tasks": 10, "daily_slots": 24, "daily_starts": 30, "concurrent": 1}) {
		t.Fatal("default owner", b.Limits)
	}

	// Create: bob's hourly task already holds 24 slots; alice's 25 of 72.
	create := `{"action":"create","idempotency_key":"%s","name":"Hourly","prompt":"p","cron":"17 * * * *"}`
	if w := web("bob", "POST", fmt.Sprintf(create, "bob-2")); w.Code != 429 {
		t.Fatal("default owner past 24 slots", w.Code, w.Body.String())
	}
	if w := web(pAlice, "POST", fmt.Sprintf(create, "alice-2")); w.Code != 200 {
		t.Fatal("override slots", w.Code, w.Body.String())
	}

	// Admit: 30 starts used today, the 31st is the override's.
	_ = h.srv.Store.ScheduleSynced(here, "synced", "", "{}")
	for i := 0; i < 30; i++ {
		slot := fmt.Sprintf("manual-%d", i)
		_ = h.srv.Store.ScheduleManual(pAlice, here.Spec.ID, slot, now)
		run, err := h.srv.Store.AdmitScheduleWithin(h.srv.scheduleLimitsFor(pAlice), pAlice, ep.ID, here.Spec.ID, slot, 1, 1, true, now)
		if err != nil {
			t.Fatal(i, err)
		}
		if _, err = h.srv.Store.FinishSchedule(pAlice, ep.ID, run.ID, "succeeded", "done", "", "fid", now); err != nil {
			t.Fatal(err)
		}
	}
	conn := &nodeConn{canSchedule: true, canScheduleAgent: true}
	h.srv.nodes.put(ep.ID, conn)
	defer h.srv.nodes.drop(ep.ID, conn)
	admit := func(slot string) *httptest.ResponseRecorder {
		_ = h.srv.Store.ScheduleManual(pAlice, here.Spec.ID, slot, now)
		return node("POST", NodeSchedulesPath+"/admit", fmt.Sprintf(`{"id":"%s","revision":1,"slot":"%s","attempt":1,"manual":true}`, here.Spec.ID, slot))
	}
	if w := admit("manual-31"); w.Code != 200 {
		t.Fatal("31st start under the override", w.Code, w.Body.String())
	}
	run, _ := h.srv.Store.ScheduleRun(pAlice, here.Spec.ID+"-manual-31-1")
	_, _ = h.srv.Store.FinishSchedule(pAlice, ep.ID, run.ID, "succeeded", "done", "", "fid", now)
	if w := admit("manual-32"); w.Code != 429 {
		t.Fatal("32nd start", w.Code, w.Body.String())
	}
}
