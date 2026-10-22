package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestFleetPartCarriesParkCensus(t *testing.T) {
	p := control.EmptyParkMetrics()
	p.SessionsWorking, p.SessionsIdle, p.SessionsParked, p.ParkedSavedMB = 7, 2, 4, 5900
	*p.IdleRSSMB = 2000
	fp := fleetPart{snap: fleetSnapshot{park: p}}
	var hb control.Heartbeat
	fp.fill(&hb, time.Now())
	b, err := json.Marshal(hb)
	if err != nil {
		t.Fatal(err)
	}
	var got control.Heartbeat
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.ParkMetrics == nil || got.SessionsIdle != 2 || got.SessionsWorking != 7 || got.SessionsParked != 4 || got.ParkedSavedMB != 5900 || *got.IdleRSSMB != 2000 {
		t.Fatalf("beat lost census: %s", b)
	}
	var old control.Heartbeat
	if err := json.Unmarshal([]byte(`{"sessions":7}`), &old); err != nil {
		t.Fatal(err)
	}
	if old.ParkMetrics != nil {
		t.Fatalf("old heartbeat invented census: %+v", old)
	}
}

// The real fleet RPC reader carries all fleets and refuses partial readings.
func TestReadFleetsParkMetrics(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, fleetControlScript)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(""), 0600); err != nil {
		t.Fatal(err)
	}
	old := fleetControlCommand
	t.Cleanup(func() { fleetControlCommand = old })
	legacy := false
	fleetControlCommand = func(_ context.Context, _ string, stdin []byte) ([]byte, error) {
		var req struct {
			Method string `json:"method"`
		}
		if err := json.Unmarshal(stdin, &req); err != nil {
			return nil, err
		}
		var result any
		if req.Method == "discover" {
			result = map[string]any{"machine_id": "m", "fleets": []map[string]string{{"name": "a", "fleet_id": "a"}, {"name": "b", "fleet_id": "b"}}}
		} else {
			p := control.EmptyParkMetrics()
			p.SessionsIdle = 1
			result = map[string]any{"state": "running", "workers": []any{}, "park_metrics": p}
			if legacy {
				result = map[string]any{"state": "running", "workers": []any{}}
			}
		}
		return json.Marshal(map[string]any{"protocol": 1, "ok": true, "result": result})
	}
	snap, err := readFleets(context.Background(), home)
	if err != nil || snap.park == nil || snap.park.SessionsIdle != 2 {
		t.Fatalf("snapshot: %+v, %v", snap, err)
	}
	legacy = true
	snap, err = readFleets(context.Background(), home)
	if err != nil || snap.park != nil {
		t.Fatalf("legacy snapshot: %+v, %v", snap, err)
	}
}
