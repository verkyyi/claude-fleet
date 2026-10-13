package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A cluster's readings (claude-fleet#3734).

// syncLink is recLink for a writer on another goroutine.
type syncLink struct {
	mu  sync.Mutex
	rec recLink
}

func (l *syncLink) write(ctx context.Context, m control.Message) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.rec.write(ctx, m)
}
func (l *syncLink) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.rec.out)
}
func (l *syncLink) read(ctx context.Context) (control.Message, error) { return l.rec.read(ctx) }
func (l *syncLink) ping(context.Context) error                        { return nil }
func (l *syncLink) close(string)                                      {}
func (l *syncLink) closeNow()                                         {}

func TestQuantities(t *testing.T) {
	for q, want := range map[string]float64{"250m": 0.25, "2": 2, "1500000000n": 1.5, "500u": 0.0005} {
		if got, ok := parseCPU(q); !ok || got != want {
			t.Errorf("cpu %q = %v %v, want %v", q, got, ok, want)
		}
	}
	for q, want := range map[string]float64{"6Gi": 6 << 30, "512Mi": 512 << 20, "1024Ki": 1 << 20, "1G": 1e9, "4096": 4096} {
		if got, ok := parseMem(q); !ok || got != want {
			t.Errorf("mem %q = %v %v, want %v", q, got, ok, want)
		}
	}
	for _, q := range []string{"", "x", "-1", "1Zi"} {
		if _, ok := parseCPU(q); ok && q != "" {
			t.Errorf("cpu %q parsed", q)
		}
		if _, ok := parseMem(q); ok {
			t.Errorf("mem %q parsed", q)
		}
	}
}

// fleet-ops reads each running user pod's fleet container against its OWN
// limits — never the host's — and a pod with no limit, no metrics yet, or
// that is not a user pod gets nothing it cannot back.
func TestClusterReadingsArePerPod(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("labelSelector") != "fleet/role=user" || r.Header.Get("Authorization") != "Bearer ops-token" {
			http.Error(w, "no", 403)
			return
		}
		switch r.URL.Path {
		case "/api/v1/namespaces/fleet-workers/pods":
			w.Write([]byte(`{"items":[
 {"metadata":{"name":"u-busy1-5f-x","labels":{"fleet/role":"user","fleet/pod":"u-busy1"}},"status":{"phase":"Running"},
  "spec":{"containers":[{"name":"fleet","resources":{"limits":{"cpu":"4","memory":"8Gi"}}},
                        {"name":"sshd","resources":{"limits":{"cpu":"1","memory":"1Gi"}}}]}},
 {"metadata":{"name":"u-free1-5f-y","labels":{"fleet/role":"user","fleet/pod":"u-free1"}},"status":{"phase":"Running"},
  "spec":{"containers":[{"name":"fleet","resources":{}}]}},
 {"metadata":{"name":"u-new1-5f-z","labels":{"fleet/role":"user","fleet/pod":"u-new1"}},"status":{"phase":"Running"},
  "spec":{"containers":[{"name":"fleet","resources":{"limits":{"cpu":"2","memory":"4Gi"}}}]}},
 {"metadata":{"name":"u-gone1-5f-w","labels":{"fleet/role":"user","fleet/pod":"u-gone1"}},"status":{"phase":"Pending"},
  "spec":{"containers":[{"name":"fleet","resources":{"limits":{"cpu":"2","memory":"4Gi"}}}]}}]}`))
		case "/apis/metrics.k8s.io/v1beta1/namespaces/fleet-workers/pods":
			w.Write([]byte(`{"items":[
 {"metadata":{"name":"u-busy1-5f-x"},"containers":[{"name":"fleet","usage":{"cpu":"3200m","memory":"7782Mi"}},
                                                  {"name":"sshd","usage":{"cpu":"900m","memory":"10Mi"}}]},
 {"metadata":{"name":"u-free1-5f-y"},"containers":[{"name":"fleet","usage":{"cpu":"100000000n","memory":"300Mi"}}]},
 {"metadata":{"name":"u-gone1-5f-w"},"containers":[{"name":"fleet","usage":{"cpu":"1","memory":"1Gi"}}]}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer api.Close()
	sa := t.TempDir()
	os.WriteFile(filepath.Join(sa, "token"), []byte("ops-token\n"), 0o600)
	os.WriteFile(filepath.Join(sa, "namespace"), []byte("fleet-workers"), 0o600)
	a := &Agent{cfg: Config{FleetClusterOps: "http://prov", FleetKubeAPI: api.URL, FleetKubeSADir: sa}, http: api.Client()}
	got, err := a.readClusterReadings(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Pod != "u-busy1" || got[1].Pod != "u-free1" {
		t.Fatalf("pods = %+v; want u-busy1, u-free1 (no metrics yet / not running: none)", got)
	}
	busy, free := got[0].Reading, got[1].Reading
	// 7782 Mi of 8 Gi: 5 % free → warn (2); 3.2 of 4 cores
	if busy.MemProbe != "2 5 0 0" || busy.MemTotalMB != "8192" || busy.LoadPerCore != "0.80" || !busy.Valid() {
		t.Fatalf("busy = %+v", busy)
	}
	if free.MemProbe != "" || free.MemTotalMB != "" || free.LoadPerCore != "" || !free.Valid() {
		t.Fatalf("no limits = %+v; want every half empty", free)
	}

	// The loop sends them up the ops link; an agent that is no ops link sends nothing.
	a.clusterReadingEvery = time.Hour
	l := &syncLink{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.clusterReadingsLoop(ctx, l); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for l.count() == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	<-done
	if l.count() != 1 || l.rec.out[0].Type != control.TypeClusterReadings {
		t.Fatalf("sent %+v; want one cluster_readings", l.rec.out)
	}
	(&Agent{}).clusterReadingsLoop(context.Background(), l) // returns at once
}

// A user pod's login writes what the hub hands it as the file
// fleet_machine_reading reads, in fleet-machine-tasks.py's shape; anything
// else, or a malformed reading, writes nothing.
func TestClusterReadingWritesTheLoginsFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("a root agent never writes a login's file")
	}
	conf := t.TempDir()
	a := &Agent{cfg: Config{Fleet: true, FleetConfDir: conf}}
	file := filepath.Join(conf, "cluster", "machine.json")
	send := func(r control.MachineReading) {
		m, _ := control.New(control.TypeClusterReading, control.ClusterReading{Reading: r})
		a.handleClusterReading(m)
	}
	r := control.MachineReading{V: 1, TS: 1760000000, MemProbe: "1 60 0 0", MemTotalMB: "6144", LoadPerCore: "0.25"}

	t.Setenv("FLEET_USER_POD", "")
	send(r)
	if _, err := os.Stat(file); err == nil || a.clusterReadingCapable() {
		t.Fatal("not a user pod: wrote the file / listed the capability")
	}
	t.Setenv("FLEET_USER_POD", "1")
	if !a.clusterReadingCapable() {
		t.Fatal("a user pod's login does not list the capability")
	}
	send(r)
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	want := "{\n\"v\": 1,\n\"ts\": 1760000000,\n\"mem_probe\": \"1 60 0 0\",\n\"mem_total_mb\": \"6144\",\n\"load_per_core\": \"0.25\"\n}\n"
	if string(b) != want {
		t.Fatalf("file = %q\nwant  %q", b, want)
	}
	var back control.MachineReading
	if json.Unmarshal(b, &back) != nil || back != r {
		t.Fatalf("file reads back as %+v", back)
	}
	bad := r
	bad.TS, bad.LoadPerCore = r.TS+1, `1"; x`
	send(bad)
	if b2, _ := os.ReadFile(file); string(b2) != want {
		t.Fatalf("a malformed reading was written: %q", b2)
	}
}
