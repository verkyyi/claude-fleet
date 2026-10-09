package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A tenant whose hello the hub refused with WRONG_LOGIN says so in lane.json
// (claude-fleet#2501) — once per streak, the first time kept — and a welcome
// clears it; a plain agent and any other refusal write nothing.
func TestLaneStateRecordsAWrongLogin(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, laneStateFile)
	plain := &Agent{cfg: Config{StateDir: d}}
	plain.laneRefused(&control.Error{Code: control.CodeWrongLogin, Message: "x"})
	if _, err := os.Stat(p); err == nil {
		t.Fatal("a plain agent wrote lane.json")
	}
	a := &Agent{cfg: Config{StateDir: d}, machine: &machineLink{}}
	a.laneRefused(&control.Error{Code: control.CodeRefused, Message: "busy"})
	if _, err := os.Stat(p); err == nil {
		t.Fatal("a non-WRONG_LOGIN refusal wrote lane.json")
	}
	why := "unrecognised enrollment token for login verky: this login re-registered"
	a.laneRefused(&control.Error{Code: control.CodeWrongLogin, Message: why})
	var first LaneState
	b, err := os.ReadFile(p)
	if err != nil || json.Unmarshal(b, &first) != nil || first.State != "refused" || first.Why != why || first.Since == "" {
		t.Fatalf("lane.json = %s %v", b, err)
	}
	if err := os.WriteFile(p, []byte(`{"state":"refused","code":"WRONG_LOGIN","why":"`+why+`","since":"2026-10-08T17:41:12Z"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	a.laneRefused(&control.Error{Code: control.CodeWrongLogin, Message: why})
	var again LaneState
	b, _ = os.ReadFile(p)
	if json.Unmarshal(b, &again) != nil || again.Since != "2026-10-08T17:41:12Z" {
		t.Fatalf("a repeat refusal moved since: %s", b)
	}
	a.laneWelcomed()
	if _, err := os.Stat(p); err == nil {
		t.Fatal("a welcome left lane.json behind")
	}
}
