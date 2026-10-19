package e2e

import (
	"bytes"
	"encoding/json"
	"net/http"

	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"

	"testing"
	"time"
)

// The relay flag follows a connected agent that can carry one.
func TestFleetRoutesRelayFlag(t *testing.T) {
	h := newFleetHarness(t)
	host, stop := startSSHRelayAgent(t, h, "mac-c", testSSHD(t))
	h.Srv.FleetRoutes = []FleetMachine{{Hostname: host, Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.2"}}}}
	_, out, _ := postRoutes(t, h, asOperator, nil)
	if len(out.Machines) != 1 || !out.Machines[0].Relay {
		t.Fatalf("connected relay agent: %+v, want relay=true", out.Machines)
	}
	stop()
	waitFor(t, 5*time.Second, "relay flag cleared", func() bool {
		_, out, _ := postRoutes(t, h, asOperator, nil)
		return len(out.Machines) == 1 && !out.Machines[0].Relay
	})
}

func postRoutes(t *testing.T, h *harness, auth func(http.Header), body any) (int, RoutesResponse, string) {
	t.Helper()
	var rd *bytes.Reader
	method := http.MethodGet
	if body != nil {
		b, _ := json.Marshal(body)
		rd, method = bytes.NewReader(b), http.MethodPost
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.HTTP.URL+control.RoutesPath, rd)
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out RoutesResponse
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.String()
}
