package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The public gate (claude-fleet#3574): the table is the repo's own
// conf/public-gate.tsv; each judge is driven both ways.

func useRepoGateTable(t *testing.T) {
	t.Helper()
	old := gateTableBytes
	gateTableBytes = func() ([]byte, error) { return os.ReadFile(filepath.Join("..", "..", "..", gateTablePath)) }
	t.Cleanup(func() { gateTableBytes = old })
}

func TestGateTableParses(t *testing.T) {
	useRepoGateTable(t)
	b, err := gateTableBytes()
	if err != nil {
		t.Fatal(err)
	}
	rows, err := parseGateTable(b)
	if err != nil || len(rows) != 7 {
		t.Fatalf("rows=%d err=%v", len(rows), err)
	}
	for _, r := range rows {
		if r.Where == "hub" && gateHubJudge[r.ID] == nil {
			t.Errorf("hub row %s has no judge", r.ID)
		}
	}
	if _, err := parseGateTable([]byte("1\tx\tsomewhere\ta\tb\tc\td\n")); err == nil {
		t.Fatal("a row with a bad where parsed")
	}
}

func TestGateHubJudgesBothWays(t *testing.T) {
	s := &Server{}
	env := map[string]string{}
	oldEnv, oldDir, oldSA, oldTTL := gateGetenv, gateReleaseDir, gateSATokenPath, gateCredLifetimes
	t.Cleanup(func() { gateGetenv, gateReleaseDir, gateSATokenPath, gateCredLifetimes = oldEnv, oldDir, oldSA, oldTTL })
	gateGetenv = func(k string) string { return env[k] }
	dir := t.TempDir()
	gateReleaseDir = filepath.Join(dir, "release")
	gateSATokenPath = filepath.Join(dir, "token")

	judge := func(id string, nodes []NodeView) (bool, string) { return gateHubJudge[id](s, nodes, true) }

	// release-key
	if ok, why := judge("release-key", nil); !ok {
		t.Fatalf("release-key, nothing held: %s", why)
	}
	env["CCQUOTA_FLEET_RELEASE_KEY"] = "/k"
	if ok, why := judge("release-key", nil); ok || !strings.Contains(why, "CCQUOTA_FLEET_RELEASE_KEY") {
		t.Fatalf("release-key, env set: %v %s", ok, why)
	}
	delete(env, "CCQUOTA_FLEET_RELEASE_KEY")
	os.MkdirAll(gateReleaseDir, 0o755)
	os.WriteFile(filepath.Join(gateReleaseDir, "key"), []byte("x"), 0o600)
	if ok, _ := judge("release-key", nil); ok {
		t.Fatal("release-key, mounted dir: passed")
	}

	// cloud-perms
	if ok, _ := judge("cloud-perms", nil); ok {
		t.Fatal("cloud-perms outside a cluster passed")
	}
	env["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
	os.WriteFile(gateSATokenPath, []byte("t"), 0o600)
	if ok, why := judge("cloud-perms", nil); ok || !strings.Contains(why, "服务账号令牌") {
		t.Fatalf("cloud-perms, token mounted: %v %s", ok, why)
	}
	os.Remove(gateSATokenPath)
	if ok, why := judge("cloud-perms", nil); !ok {
		t.Fatalf("cloud-perms, no token: %s", why)
	}

	// revocations: red until #3500 C18
	if ok, _ := judge("revocations", nil); ok {
		t.Fatal("revocations passed")
	}

	// cred-ttl: today's lifetimes are red; short ones + separated logins pass
	gateCredLifetimes = oldTTL
	if ok, why := judge("cred-ttl", nil); ok || !strings.Contains(why, "frl1") || !strings.Contains(why, "24h") {
		t.Fatalf("cred-ttl today: %v %s", ok, why)
	}
	gateCredLifetimes = func() []gateCred { return []gateCred{{"会话通行证", 4 * time.Hour}} }
	managed := []NodeView{
		{Hostname: "mac-a", OSUser: "alice", Role: store.NodeRoleManaged, Status: "online", Credsep: control.CredsepSeparated},
		{Hostname: "mac-a", OSUser: "bob", Role: store.NodeRoleManaged, Status: "online", Credsep: control.CredsepNot},
	}
	if ok, why := judge("cred-ttl", managed); ok || !strings.Contains(why, "mac-a/bob") {
		t.Fatalf("cred-ttl, bob not separated: %v %s", ok, why)
	}
	if _, why := gateHubJudge["cred-ttl"](s, managed, false); strings.Contains(why, "bob") {
		t.Fatalf("a node's answer named a login: %s", why)
	}
	managed[1].Credsep = control.CredsepSeparated
	if ok, why := judge("cred-ttl", managed); !ok {
		t.Fatalf("cred-ttl all good: %s", why)
	}
}

func TestGateNodeFold(t *testing.T) {
	useRepoGateTable(t)
	b, _ := gateTableBytes()
	rows, _ := parseGateTable(b)
	nodes := []NodeView{
		// mac-a: two logins, one says root-core is red
		{Hostname: "mac-a", OSUser: "alice", Status: "online", Gate: []control.GateItem{{ID: "root-core", Pass: true}, {ID: "node-daemon", Pass: true}, {ID: "admin-seat", Pass: true}}},
		{Hostname: "mac-a", OSUser: "bob", Status: "online", Gate: []control.GateItem{{ID: "root-core", Pass: false, Why: "root: x"}, {ID: "node-daemon", Pass: true}, {ID: "admin-seat", Pass: true}}},
		// mac-b: managed, an older agent — says nothing
		{Hostname: "mac-b", OSUser: "alice", Status: "online", Role: store.NodeRoleManaged},
		// a lost machine and a silent personal laptop count for nothing
		{Hostname: "linux-a", OSUser: "alice", Status: "lost", Gate: []control.GateItem{{ID: "root-core", Pass: false}}},
		{Hostname: "laptop", OSUser: "carol", Status: "online"},
	}
	f := gateNodeFold(rows, nodes)
	rc := f["root-core"]
	if len(rc) != 2 || rc[0].Machine != "mac-a" || rc[0].Pass || rc[0].Why != "root: x" || rc[1].Machine != "mac-b" || rc[1].Pass {
		t.Fatalf("root-core fold: %+v", rc)
	}
	if nd := f["node-daemon"]; !nd[0].Pass || nd[1].Pass || !strings.Contains(nd[1].Why, "旧于") {
		t.Fatalf("node-daemon fold: %+v", nd)
	}
}

func TestGateEndpoints(t *testing.T) {
	useRepoGateTable(t)
	h, user, _ := credsepHarness(t)
	beat := control.Heartbeat{Hostname: "m4", OSUser: "carol", ObservedAt: time.Now(),
		Gate: []control.GateItem{{ID: "root-core", Pass: true, Why: "ok"}, {ID: "node-daemon", Pass: false, Why: "root: fleet-node-supervisor.py"}, {ID: "admin-seat", Pass: true}}}
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(user))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := h.srv.Store.NodeConnected(ep.ID, "m4", "carol", "test", control.Proto, 60000, now); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(beat)
	if err := h.srv.Store.NodeHeartbeat(ep.ID, "m4", "carol", "", control.Proto, string(raw), now); err != nil {
		t.Fatal(err)
	}

	// the operator's whole gate
	res, body := h.get(t, "/v1/fleet/gate")
	var all GateView
	if res.StatusCode != http.StatusOK || json.Unmarshal(body, &all) != nil {
		t.Fatalf("/v1/fleet/gate = %d %s", res.StatusCode, body)
	}
	if all.Total != 7 || all.Pass >= all.Total {
		t.Fatalf("total=%d pass=%d", all.Total, all.Pass)
	}
	byID := map[string]GateItemView{}
	for _, it := range all.Items {
		byID[it.ID] = it
	}
	if !byID["root-core"].Pass || byID["node-daemon"].Pass || !strings.Contains(byID["node-daemon"].Why, "m4") {
		t.Fatalf("node items: %+v / %+v", byID["root-core"], byID["node-daemon"])
	}

	// a machine's: the hub's own items only
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/gate", nil)
	req.Header.Set("Authorization", "Bearer "+user)
	r2, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer r2.Body.Close()
	var hub GateView
	if r2.StatusCode != http.StatusOK || json.NewDecoder(r2.Body).Decode(&hub) != nil {
		t.Fatalf("/v1/node/gate = %d", r2.StatusCode)
	}
	if hub.Total != 4 {
		t.Fatalf("node gate total=%d", hub.Total)
	}
	for _, it := range hub.Items {
		if it.Where != "hub" || len(it.Machines) > 0 {
			t.Fatalf("node gate leaked %+v", it)
		}
	}
	// no token, no answer
	req, _ = http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/gate", nil)
	if r3, err := h.http.Client().Do(req); err != nil || r3.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous /v1/node/gate: %v %v", r3, err)
	}
}
