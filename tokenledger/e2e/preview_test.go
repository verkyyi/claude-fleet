package e2e

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Runs the real node control channel, outbound relay and disposable UID/peer
// helper. Only the application is a test server. No direct Hub→socket path.
func TestPreviewHTTPStreamAndWebSocket(t *testing.T)        { previewRelayTest(t, false, "") }
func TestPreviewReplicaHTTPStreamAndWebSocket(t *testing.T) { previewRelayTest(t, true, "") }
func TestPreviewExpiryClosesWebSocket(t *testing.T)         { previewRelayTest(t, false, "expiry") }
func TestPreviewRegistrationEndToEnd(t *testing.T)          { previewRelayTest(t, true, "registration") }
func previewRelayTest(t *testing.T, replicas bool, mode string) {
	if os.Geteuid() < 500 {
		t.Skip("ordinary user required; root runs the separate two-UID test")
	}
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	browserHub := h.Srv
	if replicas {
		h.Srv.Replica = &api.Replica{Name: "holder", URL: h.HTTP.URL, Token: replicaTestToken}
		if e := h.Srv.StartReplica(); e != nil {
			t.Fatal(e)
		}
		browserHub = &api.Server{Store: h.Srv.Store, Fleet: true, GitHub: h.Srv.GitHub, ViewerToken: viewerToken, LiveStore: api.NewLive(), Replica: &api.Replica{Name: "front", Token: replicaTestToken}}
		peer := httptest.NewServer(browserHub.Handler())
		t.Cleanup(peer.Close)
		browserHub.Replica.URL = peer.URL
		if e := browserHub.StartReplica(); e != nil {
			t.Fatal(e)
		}
	}
	me, e := user.Current()
	if e != nil {
		t.Fatal(e)
	}
	host, _ := os.Hostname()
	now := time.Now()
	// The node helper refuses a group- or world-writable ancestor of the socket
	// directory; say which one here rather than leave a bare 502 to read later.
	for d := me.HomeDir; d != "/" && d != "."; d = filepath.Dir(d) {
		if st, e := os.Stat(d); e == nil && st.Mode().Perm()&0022 != 0 {
			t.Fatalf("%s is mode %#o: the preview helper refuses a group/world-writable ancestor of ~/.fleet-preview (chmod 755 it — a CI runner image's home)", d, st.Mode().Perm())
		}
	}
	dir := filepath.Join(me.HomeDir, ".fleet-preview")
	made := false
	if _, e = os.Stat(dir); os.IsNotExist(e) {
		if e = os.Mkdir(dir, 0700); e != nil {
			t.Fatal(e)
		}
		made = true
	}
	if made {
		t.Cleanup(func() { os.Remove(dir) })
	}
	name := fmt.Sprintf("test-%d.sock", os.Getpid())
	external := os.Getenv("FLEET_PREVIEW_TEST_SOCKET")
	if external != "" {
		name = external
	}
	path := filepath.Join(dir, name)
	app := http.NewServeMux()
	app.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ws":
			c, e := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
			if e != nil {
				return
			}
			defer c.CloseNow()
			for {
				typ, b, e := c.Read(r.Context())
				if e != nil {
					return
				}
				if e = c.Write(r.Context(), typ, b); e != nil {
					return
				}
			}
		case "/events":
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: ready\n\n")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		case "/api":
			b, _ := io.ReadAll(r.Body)
			json.NewEncoder(w).Encode(map[string]string{"method": r.Method, "body": string(b), "cookie": r.Header.Get("Cookie"), "auth": r.Header.Get("Authorization"), "custom": r.Header.Get("X-App-Value")})
		default:
			fmt.Fprint(w, `<!doctype html><h1>Private preview</h1><p id="state">ready</p><script>let ws=new WebSocket('wss://'+location.host+'/ws');ws.onopen=()=>ws.send('HMR connected');ws.onmessage=e=>document.querySelector('#state').textContent=e.data;</script>`)
		}
	})
	if external == "" {
		ln, e := net.Listen("unix", path)
		if e != nil {
			t.Fatal(e)
		}
		os.Chmod(path, 0600)
		appServer := &http.Server{Handler: app}
		go appServer.Serve(ln)
		t.Cleanup(func() { appServer.Close(); os.Remove(path) })
	}
	p, e := h.Srv.Store.EnsurePrincipalAs(pAlice, "alice", me.Username, 64, func(string) bool { return true }, now)
	if e != nil {
		t.Fatal(e)
	}
	// enablePeople does not create a principal; the OS login comes from kernel.
	if e = h.Srv.Store.AdoptAccount(p, host, now); e != nil {
		t.Fatal(e)
	}
	token := "fixture-preview-token"
	if e = h.Srv.Store.CreateJoinCodeFor("preview-code", host+"-"+me.Username, store.NodeKindFixed, "", store.NodeRoleManaged, host, now, time.Hour); e != nil {
		t.Fatal(e)
	}
	if e = h.Srv.Store.RedeemJoinCode("preview-code", now, "preview-node", "test", api.HashToken(token), host, me.Username); e != nil {
		t.Fatal(e)
	}
	input := store.FleetTask{Owner: pAlice, Title: "Local private preview", Machine: host, Login: me.Username, WorkerID: "preview-worker"}
	if mode == "registration" {
		// Reproduce the legacy rejoin and real local Task shape, without
		// manufacturing the old Task location/worker projections.
		if _, e = h.Srv.Store.DB().Exec(`UPDATE fleet_join_codes SET machine='',role='',label='legacy-rejoin' WHERE endpoint_id='preview-node'`); e != nil {
			t.Fatal(e)
		}
		input = store.FleetTask{Owner: pAlice, Title: "Local private preview", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}
	}
	task, e := h.Srv.Store.CreateFleetTask(input, "preview-task", now)
	if e != nil {
		t.Fatal(e)
	}
	h.Srv.PreviewDomain = "preview.test"
	h.Srv.FleetPublicURL = "https://hub.test"
	browserHub.PreviewDomain = h.Srv.PreviewDomain
	browserHub.FleetPublicURL = h.Srv.FleetPublicURL
	// Existing admin/node HTTP routes: the legacy fixture is denied, then the
	// operator approves the exact account/endpoint, and the worker registers.
	request := func(server *api.Server, path, body, bearer, assertion string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", path, strings.NewReader(body))
		r.Host = "hub.test"
		r.Header.Set("Authorization", "Bearer "+bearer)
		r.Header.Set("X-Fleet-Worker", assertion)
		w := httptest.NewRecorder()
		server.Handler().ServeHTTP(w, r)
		return w
	}
	bind := func(action string) string {
		b, _ := json.Marshal(map[string]string{"action": action, "principal_id": pAlice, "hostname": host, "login": me.Username, "endpoint_id": "preview-node"})
		return string(b)
	}
	var preview store.Preview
	if mode == "registration" {
		fleet := "11111111-2222-4333-8444-555555555555"
		if _, e = h.Srv.Store.RecordFleetSnapshot("preview-node", host, me.Username, "preview-machine", []store.FleetReport{{FleetID: fleet, Name: "preview", State: "up"}}, now); e != nil {
			t.Fatal(e)
		}
		_, e = h.Srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: pAlice, EndpointID: "preview-node", Machine: host, Login: me.Username, ID: task.FID, Events: []map[string]any{{"id": task.FID, "ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "task": task.Ref, "agent": "codex", "key": "scratch-978"}}})
		if e != nil {
			t.Fatal(e)
		}
		raw, _ := json.Marshal(map[string]any{"v": 1, "worker_id": fleet + "/" + task.FID, "fleet_uuid": fleet, "fid": task.FID, "node": host, "iat": now.Unix(), "exp": now.Add(time.Minute).Unix()})
		assertion := "fwa1." + base64.RawURLEncoding.EncodeToString(raw)
		mac := hmac.New(sha256.New, []byte(api.HashToken(token)))
		mac.Write([]byte(assertion))
		assertion += "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
		body, _ := json.Marshal(map[string]string{"action": "register", "socket": name})
		path := "/v1/node/previews?task=" + task.Ref
		if w := request(h.Srv, path, string(body), token, assertion); w.Code != 403 {
			t.Fatal("unbound", w.Code, w.Body.String())
		}
		if w := request(h.Srv, "/v1/fleet/accounts", bind("preview-bind"), token, ""); w.Code != 401 && w.Code != 403 {
			t.Fatal("node self-approval", w.Code)
		}
		if w := request(h.Srv, "/v1/fleet/accounts", bind("preview-bind"), viewerToken, ""); w.Code != 200 {
			t.Fatal("operator bind", w.Code, w.Body.String())
		}
		w := request(browserHub, path, string(body), token, assertion)
		if w.Code != 201 {
			t.Fatal("registration on peer", w.Code, w.Body.String())
		}
		if e = json.Unmarshal(w.Body.Bytes(), &preview); e != nil {
			t.Fatal(e)
		}
		if len(strings.Split(strings.TrimPrefix(preview.URL, "https://"), ".")[0]) != 32 {
			t.Fatal("preview label", preview.URL)
		}
	} else {
		authority, err := h.Srv.Store.PreviewAuthority("preview-node")
		if err != nil {
			t.Fatal(err)
		}
		preview = store.Preview{ID: strings.Repeat("a", 32), Owner: pAlice, Endpoint: "preview-node", Machine: host, Login: me.Username, Generation: authority.Generation, TokenHash: authority.TokenHash, TaskID: task.ID, Worker: task.WorkerID, Socket: name, Expires: now.Add(time.Hour).Unix()}
		if e = h.Srv.Store.CreatePreview(preview, 3, now); e != nil {
			t.Fatal(e)
		}
	}
	nodeHub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Host = "hub.test"
		if replicas && r.URL.Path == "/v1/node/preview-data" {
			// Node data deliberately lands on the replica without the relay.
			browserHub.Handler().ServeHTTP(w, r)
		} else {
			h.Srv.Handler().ServeHTTP(w, r)
		}
	}))
	defer nodeHub.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	home := t.TempDir()
	cfg := agent.Config{HubURL: nodeHub.URL, Token: token, Home: home, StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"), Sources: "claude", Fleet: true, FleetChat: true, ScanInterval: time.Hour, LimitsInterval: time.Hour, LiveInterval: time.Hour}
	a, e := agent.New(cfg)
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	waitFor(t, 10*time.Second, "preview node", func() bool { return h.Srv.NodeForTest("preview-node") != nil })
	// HTTPS frontend can serve a real browser using Chromium host-resolver rules,
	// without editing DNS, hosts, certificates or production configuration.
	front := httptest.NewTLSServer(browserHub.Handler())
	defer front.Close()
	tr := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, front.Listener.Addr().String())
	}}
	client := &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer tr.CloseIdleConnections()
	base := "https://" + preview.ID + "." + h.Srv.PreviewDomain
	do := func(method, addr, body string, cookies ...*http.Cookie) *http.Response {
		t.Helper()
		r, _ := http.NewRequest(method, addr, strings.NewReader(body))
		for _, c := range cookies {
			r.AddCookie(c)
		}
		r.Header.Set("X-App-Value", "kept")
		r.Header.Set("Authorization", "platform-secret")
		resp, e := client.Do(r)
		if e != nil {
			t.Fatal(e)
		}
		return resp
	}
	cookie := func(r *http.Response, name string) *http.Cookie {
		for _, c := range r.Cookies() {
			if c.Name == name {
				return c
			}
		}
		t.Fatalf("no %s cookie: %d", name, r.StatusCode)
		return nil
	}
	first := do("GET", base+"/", "")
	first.Body.Close()
	state := cookie(first, "__Host-fleet-preview-state")
	session := personCookie(pAlice, "alice")
	auth := do("GET", first.Header.Get("Location"), "", session)
	auth.Body.Close()
	if auth.StatusCode != 302 {
		t.Fatal("authorize", auth.StatusCode)
	}
	callback := do("GET", auth.Header.Get("Location"), "", state)
	callback.Body.Close()
	c := cookie(callback, "__Host-fleet-preview")
	r := do("POST", base+"/api", "posted", c, &http.Cookie{Name: "app", Value: "own"})
	defer r.Body.Close()
	var got map[string]string
	if e = json.NewDecoder(r.Body).Decode(&got); e != nil {
		t.Fatal(r.StatusCode, e)
	}
	if got["body"] != "posted" || got["method"] != "POST" || got["auth"] != "" || got["cookie"] != "app=own" || got["custom"] != "kept" {
		t.Fatal(got)
	}
	oversized := do("POST", base+"/api", strings.Repeat("x", (10<<20)+1), c)
	oversized.Body.Close()
	if oversized.StatusCode != 413 {
		t.Fatal("body limit", oversized.StatusCode)
	}
	// A reconnect replaces the transport generation, retaining only durable
	// authority for this exact endpoint. No hostname-only fallback.
	cancel()
	<-done
	waitFor(t, 5*time.Second, "preview offline", func() bool { return h.Srv.NodeForTest("preview-node") == nil })
	offline := do("GET", base+"/api", "", c)
	offline.Body.Close()
	if offline.StatusCode != 503 {
		t.Fatal("offline request", offline.StatusCode)
	}
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	a, e = agent.New(cfg)
	if e != nil {
		t.Fatal(e)
	}
	done = make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	waitFor(t, 10*time.Second, "preview reconnected", func() bool { return h.Srv.NodeForTest("preview-node") != nil })
	resumed := do("GET", base+"/api", "", c)
	resumed.Body.Close()
	if resumed.StatusCode != 200 {
		t.Fatal("reconnected request", resumed.StatusCode)
	}
	stream := do("GET", base+"/events", "", c)
	defer stream.Body.Close()
	line, e := bufio.NewReader(stream.Body).ReadString('\n')
	if e != nil || line != "data: ready\n" {
		t.Fatal("SSE", line, e)
	}
	ws, _, e := websocket.Dial(ctx, strings.Replace(base, "https:", "wss:", 1)+"/ws", &websocket.DialOptions{HTTPClient: client, HTTPHeader: http.Header{"Cookie": {c.Name + "=" + c.Value}, "Origin": {base}}})
	if e != nil {
		t.Fatal(e)
	}
	defer ws.CloseNow()
	if e = ws.Write(ctx, websocket.MessageText, []byte("HMR")); e != nil {
		t.Fatal(e)
	}
	_, data, e := ws.Read(ctx)
	if e != nil || string(data) != "HMR" {
		t.Fatal(string(data), e)
	}
	// Browser fixture holds this exact application/relay until its file disappears.
	if path := os.Getenv("FLEET_PREVIEW_BROWSER_FIXTURE"); path != "" && !replicas {
		raw, _ := json.Marshal(map[string]string{"preview": base, "hub": h.Srv.FleetPublicURL, "listen": front.Listener.Addr().String(), "session": session.Value, "cookie": c.Value, "task": task.Ref})
		if e = os.WriteFile(path, raw, 0600); e != nil {
			t.Fatal(e)
		}
		t.Log("local browser fixture ready; remove the fixture file to stop")
		for {
			if _, e = os.Stat(path); os.IsNotExist(e) {
				break
			}
			time.Sleep(time.Second)
		}
	}
	// Closing from the store is what a different replica's user action does.
	if mode == "registration" {
		w := request(browserHub, "/v1/fleet/accounts", bind("preview-unbind"), viewerToken, "")
		if w.Code != 200 {
			t.Fatal("operator unbind", w.Code, w.Body.String())
		}
	} else if mode == "expiry" {
		_, e = browserHub.Store.DB().Exec(`UPDATE fleet_previews SET expires=? WHERE id=?`, time.Now().Unix()-1, preview.ID)
	} else {
		e = browserHub.Store.ClosePreview(preview.ID, pAlice)
	}
	if e != nil {
		t.Fatal(e)
	}
	closed, cancelRead := context.WithTimeout(ctx, 4*time.Second)
	defer cancelRead()
	if _, _, e = ws.Read(closed); e == nil || closed.Err() != nil {
		t.Fatal("revoked WebSocket remained open", e)
	}
	denied := do("GET", base+"/api", "", c)
	denied.Body.Close()
	if denied.StatusCode != 404 {
		t.Fatal("revoked request", denied.StatusCode)
	}
	t.Log("PASS real node + UID helper: HTTPS GET, POST, app cookies/headers, SSE, WS echo, revoke live WS")
}
