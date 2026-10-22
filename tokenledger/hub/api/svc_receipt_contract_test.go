package api

import (
	"encoding/json"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestSvcReceiptSuccessVocabularyCompatibility(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	ref := svcSubmit(t, h, tok, svcReq("probe", "receipt-vocabulary"))["run_id"].(string)
	id := svcRunID(t, ref)
	if err := h.srv.Store.SetSvcRunEngine(id, 1, "claude"); err != nil {
		t.Fatal(err)
	}
	run, err := h.srv.SvcRunFinish(id, store.SvcRunSucceeded, "", svcGoodResult, json.RawMessage(`{"input_tokens":7,"wall_s":3}`))
	if err != nil {
		t.Fatal(err)
	}
	view := svcRunView(run, true)
	var attempts []svcAttempt
	if err := json.Unmarshal(view.Attempts, &attempts); err != nil {
		t.Fatal(err)
	}
	if view.State != "succeeded" || view.ErrorCode != "" || view.Progress.Stage != "completed" || len(attempts) != 1 || attempts[0].Code != "ok" {
		t.Fatalf("incompatible success vocabulary: %+v attempts=%+v", view, attempts)
	}
	// A legacy consumer ignores additive fields and still sees the same terminal state.
	body, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	var old struct {
		RunID string `json:"run_id"`
		State string `json:"state"`
	}
	if err := json.Unmarshal(body, &old); err != nil || old.RunID != ref || old.State != "succeeded" {
		t.Fatalf("legacy consumer: %+v %v", old, err)
	}
	// A duplicate result cannot add another success or change the stored vocabulary.
	again, err := h.srv.SvcRunFinish(id, store.SvcRunSucceeded, "", svcGoodResult, json.RawMessage(`{"input_tokens":99}`))
	if err != nil || again.AttemptsJSON != run.AttemptsJSON || again.UsageJSON != run.UsageJSON {
		t.Fatalf("duplicate changed receipt: %+v %v", again, err)
	}
	legacy := svcRunView(store.SvcRun{State: store.SvcRunSucceeded}, false)
	if string(legacy.Attempts) != "[]" || len(legacy.Usage) != 0 || legacy.Progress.Stage != "completed" {
		t.Fatalf("legacy receipt fabricated usage: %+v", legacy)
	}
}
