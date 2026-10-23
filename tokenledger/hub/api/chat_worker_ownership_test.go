package api

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"
)

// Two ordinary member cookies traverse the actual HTTP auth middleware and
// worker routes. The node fixture intentionally has no chat capability: an
// owner's request must reach old_agent, while another member must be refused
// before relay selection, even if they submit the owner's native FID in JSON.
// This is an isolated authorization regression, not a production-user drill.
func TestChatWorkerOrdinaryMemberOwnership(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	setChatHome(t, h, pAlice, "ownership-node", "alice")
	setChatHome(t, h, pBob, "ownership-node", "bob")
	n := connectFakeNode(t, h, "ownership-node", false)
	f := fakeFleet(t, machineA, "ownership", "o/r", "/repo")
	const fid = "9caa99de-2736-4711-b61b-ab363f65279e"
	wid := f.FleetID + "/" + fid
	f.Workers, _ = json.Marshal([]map[string]any{{"worker_id": wid, "fleet_id": fid, "identity": fid, "state": "working"}})
	f.Count = 1
	n.beat("ownership-node", "alice", machineA, f)
	waitFor(t, 3*time.Second, "owned worker heartbeat", func() bool {
		got, err := h.srv.Store.Fleet(f.FleetID)
		return err == nil && got.Present
	})
	header := map[string]string{"X-Fleet-Webchat": "1", "Content-Type": "application/json"}
	for _, route := range []string{"say", "answer", "stop", "ack"} {
		t.Run(route, func(t *testing.T) {
			path := "/v1/chat/" + route + "?worker=" + url.QueryEscape(wid)
			body := `{"text":"ownership fixture","fid":"` + fid + `","delivery":"fixture"}`
			owner := chatDo(t, h, http.MethodPost, path, personCookie(pAlice, "alice"), header, body)
			if code := chatCode(t, owner); owner.StatusCode != http.StatusConflict || code != "old_agent" {
				t.Fatalf("owner must pass ownership and reach relay capability: HTTP %d %s", owner.StatusCode, code)
			}
			other := chatDo(t, h, http.MethodPost, path, personCookie(pBob, "bob"), header, body)
			if code := chatCode(t, other); other.StatusCode != http.StatusNotFound || code != "not_yours" {
				t.Fatalf("another ordinary member: HTTP %d %s, want 404 not_yours", other.StatusCode, code)
			}
			missing := chatDo(t, h, http.MethodPost, path+"-missing", personCookie(pBob, "bob"), header, body)
			if code := chatCode(t, missing); missing.StatusCode != http.StatusNotFound || code != "not_yours" {
				t.Fatalf("nonexistent worker must be indistinguishable: HTTP %d %s", missing.StatusCode, code)
			}
			anonymous := chatDo(t, h, http.MethodPost, path, nil, header, body)
			if anonymous.StatusCode != http.StatusUnauthorized {
				t.Fatalf("anonymous: HTTP %d, want 401", anonymous.StatusCode)
			}
		})
	}
}
