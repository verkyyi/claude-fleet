package store

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestTaskParentWriteRetired(t *testing.T) {
	s := taskStore(t)
	parent := acceptedTask(t, s, "retired-parent", "")
	in := FleetTask{Owner: "alice", Title: "independent task", AuthorityVersion: 1,
		RequestedAgent: "codex", ResolvedAgent: "codex", ParentTask: parent.Ref, ParentSession: "old/session",
		RequestPayload: `{"action":"worker_start","params":{"origin_wid":"old/session","body":{"origin_wid":"user value"}}}`}
	rec, err := s.CreateFleetTask(in, "retired-write", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if rec.ParentTask != "" || rec.ParentSession != "" || rec.ParentGeneration != 0 {
		t.Fatalf("new relationship: %+v", rec)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(rec.RequestPayload), &payload); err != nil {
		t.Fatal(err)
	}
	params := payload["params"].(map[string]any)
	if _, ok := params["origin_wid"]; ok {
		t.Fatal("new transport parent persisted")
	}
	if params["body"].(map[string]any)["origin_wid"] != "user value" {
		t.Fatal("user payload changed")
	}
}

func TestTaskParentHistoricalReplayPreservesBytes(t *testing.T) {
	s := taskStore(t)
	for _, payload := range []string{
		`{"dispatch":{"request_id":"old"},"body":{"parent_task":"user task","origin_wid":"user origin"}}`,
		`{"action":"worker_start","params":{"origin_wid":"old/session","body":{"origin_wid":"user origin"}}}`,
		`{"origin_wid":"user origin","parent_task":"user task","parent_session":"user session","body":9007199254740993}`,
		`{"action":"custom","params":{"origin_wid":"user origin"}}`,
	} {
		in := FleetTask{Owner: "alice", Title: payload, AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex", RequestPayload: payload}
		token := "old-" + payload
		rec, err := s.CreateFleetTask(in, token, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		// Seed actual old serialized bytes directly; never recreate history by
		// going through the new acceptance path.
		old := acceptedTaskInput{Title: in.Title, RequestedAgent: "codex", ResolvedAgent: "codex", ParentTask: "T999", ParentSession: "old/session", Payload: json.RawMessage(payload)}
		raw, err := json.MarshalIndent(old, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if _, err = s.write.Exec(`UPDATE fleet_tasks SET parent_task='T999', parent_session='old/session', parent_generation=7, accepted_request=?, request_payload=? WHERE id=?`, string(raw), payload, rec.ID); err != nil {
			t.Fatal(err)
		}
		// Do not round-trip user numbers through float64 in the fixture.
		in.RequestPayload = strings.Replace(payload, `"origin_wid":"old/session",`, "", 1)
		again, err := s.CreateFleetTask(in, token, time.Now())
		if err != nil || again.ID != rec.ID {
			t.Fatalf("parent-free old replay: %+v %v", again, err)
		}
		if again.acceptedRequest != string(raw) || again.RequestPayload != payload || again.ParentTask != "T999" || again.ParentGeneration != 7 {
			t.Fatal("historical bytes/columns rewritten")
		}
		for _, field := range []string{"body", "title", "provider"} {
			changed := in
			switch field {
			case "body":
				changed.RequestPayload = `{"body":{"origin_wid":"different user value"}}`
			case "title":
				changed.Title += "changed"
			case "provider":
				changed.RequestedAgent, changed.ResolvedAgent = "claude", "claude"
			}
			if _, err := s.CreateFleetTask(changed, token, time.Now()); !errors.Is(err, ErrTaskConflict) {
				t.Fatalf("%s difference accepted: %v", field, err)
			}
		}
		// The retired names inside user content still participate in replay.
		changed := in
		changed.RequestPayload = strings.Replace(in.RequestPayload, "user origin", "different origin", 1)
		if changed.RequestPayload == in.RequestPayload {
			t.Fatal("fixture has no user origin")
		}
		if _, err := s.CreateFleetTask(changed, token, time.Now()); !errors.Is(err, ErrTaskConflict) {
			t.Fatalf("nested/user Parent field ignored: %v", err)
		}
		if again, err := s.FleetTask(rec.ID); err != nil || again.acceptedRequest != string(raw) {
			t.Fatal("conflicting replay modified original bytes")
		}
	}
}
