package e2e

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"testing"
	"time"
)

// A rolling deploy took the replica that held the home's link (task V9DJ):
// its row in fleet_node_conns still names it, but it beats no more. The chat
// is never handed to it — no 30 s wait on a pod that is gone — and the page
// is told the home is reconnecting, in words, and when to ask again.
func TestChatReplicaGone(t *testing.T) {
	ha, hb := newReplicaPair(t)
	for _, h := range []*harness{ha, hb} {
		enablePeople(t, h, pAlice)
	}
	ub, _ := url.Parse(hb.HTTP.URL)
	pb := httputil.NewSingleHostReverseProxy(ub)
	front := httptest.NewServer(pb)
	t.Cleanup(front.Close)
	conf := shortTemp(t)
	serveFakeChat(t, conf)
	host, login := startSignedChatAgent(t, hb, front.URL, "chat-gone", conf)
	setChatHome(t, ha, pAlice, host, login)
	alice := personCookie(pAlice, "alice")

	// The link's holder is gone: a replica that never beat, at an address
	// nothing answers.
	if _, err := ha.Srv.Store.DB().Exec(`UPDATE fleet_node_conns SET replica = 'gone-replica-0', url = 'http://10.255.255.1:9'
		WHERE endpoint_id = ?`, "ep_chat-gone"); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	resp := chatDo(t, ha, "GET", "/v1/chat/conversation", alice, nil, "")
	took := time.Since(start)
	b, _ := io.ReadAll(resp.Body)
	var j struct {
		Code  string `json:"code"`
		Error string `json:"error"`
	}
	json.Unmarshal(b, &j)
	if resp.StatusCode != http.StatusServiceUnavailable || j.Code != "home_reconnecting" || j.Error != "正在重连你的家，稍候" {
		t.Fatalf("conversation with the holder gone: %d %s; want 503 home_reconnecting", resp.StatusCode, b)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Error("no Retry-After for the page to ask again")
	}
	if took > 5*time.Second {
		t.Errorf("the answer took %s; want it at once, not a dial to the gone replica", took)
	}
	resp = chatDo(t, ha, "GET", "/v1/chat/home", alice, nil, "")
	b, _ = io.ReadAll(resp.Body)
	var home struct {
		State string `json:"state"`
	}
	json.Unmarshal(b, &home)
	if home.State != "reconnecting" {
		t.Errorf("home with the holder gone: %s; want state reconnecting", b)
	}
}
