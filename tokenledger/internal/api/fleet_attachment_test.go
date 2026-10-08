package api

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A writing area's attachments (claude-fleet#2393, EPIC #2482 C1).

// attachNodes is twoNodes with m4 (the idle one) saying CapAttach when
// m4Attach; it returns both enrollment tokens.
func attachNodes(t *testing.T, m4Attach bool) (*harness, *writeNode, *writeNode, control.Fleet, string, string) {
	t.Helper()
	h := newFleetHarness(t)
	tok5, tok4 := h.enroll(t, "m5"), h.enroll(t, "m4")
	m5 := connectWriteNodeCaps(t, h, tok5, control.CapRead, control.CapWrite)
	caps := []string{control.CapRead, control.CapWrite}
	if m4Attach {
		caps = append(caps, control.CapAttach)
	}
	m4 := connectWriteNodeCaps(t, h, tok4, caps...)
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet", 2)
	m5.beatLoad("m5", "verk", machineA, 10, 3, f5)
	m4.beatLoad("m4", "verk", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	return h, m5, m4, f4, tok5, tok4
}

func attachmentOf(name, from string, data []byte) map[string]any {
	sum := sha256.Sum256(data)
	return map[string]any{"name": name, "from": from, "sha256": hex.EncodeToString(sum[:]),
		"data": base64.StdEncoding.EncodeToString(data)}
}

func getAttachment(t *testing.T, h *harness, token, id string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/attachment/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b
}

// The completion criterion: a place carrying a file → the chosen node is sent
// its id · name · sha256 · size · from (never the bytes), downloads exactly
// those bytes with its own token, and no other node can.
func TestClientPlaceCarriesAttachments(t *testing.T) {
	h, m5, m4, f4, tok5, tok4 := attachNodes(t, true)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@4",
		"workers": []map[string]any{{"window_id": "@4", "worker_id": f4.FleetID + "/issue-77"}}}))
	shot := []byte("\x89PNG\r\n\x1a\nthe error in the screenshot")
	from := "/var/folders/mw/T/pasted-image-20261007-230449.png"
	body := "报错截图 " + from + "\n\n附件:\n- " + from
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "node": "auto",
		"title": "报错截图", "body": body, "idempotency_key": "c-attach",
		"attachments": []any{attachmentOf("pasted-image-20261007-230449.png", from, shot)}})
	if st != 200 || out.State != "done" || out.Attached != 1 || out.AttachNote != "" {
		t.Fatalf("place = %d %+v; want done on m4 with 1 attached", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	params := m4.writes[0]["params"].(map[string]any)
	list, _ := params["attachments"].([]any)
	if len(list) != 1 || params["body"] != body {
		t.Fatalf("m4 was sent %v; want the body as written and one attachment", params)
	}
	a := list[0].(map[string]any)
	sum := sha256.Sum256(shot)
	if a["name"] != "pasted-image-20261007-230449.png" || a["from"] != from || a["sha256"] != hex.EncodeToString(sum[:]) ||
		a["size"] != float64(len(shot)) || len(a) != 5 {
		t.Fatalf("attachment = %v; want id · name · sha256 · size · from", a)
	}
	if _, ok := a["data"]; ok {
		t.Fatal("the bytes rode the control channel")
	}
	id := a["id"].(string)
	if st, b := getAttachment(t, h, tok4, id); st != 200 || string(b) != string(shot) {
		t.Fatalf("m4 GET = %d %q; want the file's bytes", st, b)
	}
	if st, _ := getAttachment(t, h, tok5, id); st != 404 {
		t.Fatalf("m5 GET = %d; want 404 (not the start's node)", st)
	}
	o, err := h.srv.Store.FleetOperation(asString(m4.writes[0]["operation_id"]))
	if err != nil || strings.Contains(o.Request, base64.StdEncoding.EncodeToString(shot)) {
		t.Fatalf("journal = %v %v; the bytes must not be journalled", o.Request, err)
	}
}

// A machine whose agent cannot take them is sent none — and the client is told.
func TestClientPlaceAttachmentsToAnOlderNode(t *testing.T) {
	h, _, m4, f4, _, _ := attachNodes(t, false)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@4",
		"workers": []map[string]any{{"window_id": "@4", "worker_id": f4.FleetID + "/scratch-3"}}}))
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch", "node": "auto",
		"title": "看图", "body": "看图 /tmp/a.png", "attachments": []any{attachmentOf("a.png", "/tmp/a.png", []byte("x"))}})
	if st != 200 || out.State != "done" || out.Attached != 0 || !strings.Contains(out.AttachNote, "takes no attachments") {
		t.Fatalf("place = %d %+v; want done, 0 attached and a note", st, out)
	}
	if _, ok := m4.writes[0]["params"].(map[string]any)["attachments"]; ok {
		t.Fatal("an older node was sent attachments")
	}
}

// What the hub refuses before anything is stored or sent.
func TestClientPlaceAttachmentRefusals(t *testing.T) {
	h, m5, m4, _, _, _ := attachNodes(t, true)
	lease, key := clientLeaseFor(t, h)
	good := attachmentOf("a.png", "/tmp/a.png", []byte("x"))
	badSum := attachmentOf("a.png", "/tmp/a.png", []byte("x"))
	badSum["sha256"] = strings.Repeat("0", 64)
	big := attachmentOf("big.bin", "/tmp/big.bin", make([]byte, attachFileMax+1))
	five := []any{}
	for range attachCountMax + 1 {
		five = append(five, good)
	}
	for what, bad := range map[string]map[string]any{
		"issue kind": {"repo": writeRepo, "kind": "issue", "issue": 7, "attachments": []any{good}},
		"slash name": {"repo": writeRepo, "kind": "new", "title": "x", "attachments": []any{attachmentOf("../a", "/tmp/a", []byte("x"))}},
		"dot name":   {"repo": writeRepo, "kind": "new", "title": "x", "attachments": []any{attachmentOf("..", "/tmp/a", []byte("x"))}},
		"sha":        {"repo": writeRepo, "kind": "new", "title": "x", "attachments": []any{badSum}},
		"too big":    {"repo": writeRepo, "kind": "new", "title": "x", "attachments": []any{big}},
		"too many":   {"repo": writeRepo, "kind": "new", "title": "x", "attachments": five},
		"no from":    {"repo": writeRepo, "kind": "new", "title": "x", "attachments": []any{attachmentOf("a", "", []byte("x"))}},
		"big body":   {"repo": writeRepo, "kind": "new", "title": "x", "body": strings.Repeat("x", 40<<10)},
	} {
		if st, _ := clientPlace(t, h, lease, key, bad); st != 400 && st != 413 {
			t.Fatalf("%s = %d; want 400/413", what, st)
		}
	}
	if m5.count()+m4.count() != 0 {
		t.Fatalf("a refused call sent a write (m5 %d, m4 %d)", m5.count(), m4.count())
	}
}

// worker_start's own check (the MCP / API road): attachments only as the hub
// writes them, only on a new or scratch start.
func TestCheckAttachList(t *testing.T) {
	ok := map[string]any{"id": strings.Repeat("a", 32), "name": "a.png", "sha256": strings.Repeat("b", 64),
		"size": float64(3), "from": "/tmp/a.png"}
	if _, err := checkAttachList([]any{ok}); err != nil {
		t.Fatalf("a good list: %v", err)
	}
	for _, bad := range []any{"x", []any{}, []any{map[string]any{"id": "x"}},
		[]any{map[string]any{"id": strings.Repeat("a", 32), "name": "a/b", "sha256": strings.Repeat("b", 64), "size": float64(3), "from": "/x"}},
		[]any{map[string]any{"id": strings.Repeat("a", 32), "name": "a", "sha256": strings.Repeat("b", 64), "size": float64(3), "from": "/x", "data": "eA=="}},
	} {
		if _, err := checkAttachList(bad); err == nil {
			t.Fatalf("%v passed", bad)
		}
	}
	if _, _, err := parseWrite("worker_start", map[string]any{"issue": float64(7), "repo": writeRepo,
		"idempotency_key": "k", "attachments": []any{ok}}); err == nil {
		t.Fatal("an issue start took attachments")
	}
}
