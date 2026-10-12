package dns

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeDNSPod is the legacy API as far as DNSPod uses it: the token checked
// in the body, records with remarks, Record.Remark failing on demand.
type fakeDNSPod struct {
	mu         sync.Mutex
	recs       []map[string]string
	next       int
	calls      []string
	failRemark bool
	urls       []string
}

// with runs fn under the fake's lock (the test's side of it).
func (f *fakeDNSPod) with(fn func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn()
}

func (f *fakeDNSPod) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.urls = append(f.urls, r.URL.String())
	_ = r.ParseForm()
	action := strings.TrimPrefix(r.URL.Path, "/")
	f.calls = append(f.calls, action)
	reply := func(code, msg string, extra map[string]any) {
		out := map[string]any{"status": map[string]string{"code": code, "message": msg}}
		for k, v := range extra {
			out[k] = v
		}
		_ = json.NewEncoder(w).Encode(out)
	}
	if r.PostForm.Get("login_token") != "123,s3cr3t" || r.PostForm.Get("format") != "json" {
		reply("-1", "Login failed", nil)
		return
	}
	if r.PostForm.Get("domain") != "24haowan.com" {
		reply("6", "bad domain", nil)
		return
	}
	find := func(id string) int {
		for i, rec := range f.recs {
			if rec["id"] == id {
				return i
			}
		}
		return -1
	}
	switch action {
	case "Record.List":
		if len(f.recs) == 0 {
			reply("10", "No records", nil)
			return
		}
		reply("1", "ok", map[string]any{"info": map[string]string{"record_total": fmt.Sprint(len(f.recs))}, "records": f.recs})
	case "Record.Create":
		f.next++
		id := fmt.Sprint(1000 + f.next)
		f.recs = append(f.recs, map[string]string{"id": id, "name": r.PostForm.Get("sub_domain"), "type": r.PostForm.Get("record_type"),
			"value": r.PostForm.Get("value"), "ttl": r.PostForm.Get("ttl"), "line": r.PostForm.Get("record_line"), "remark": ""})
		reply("1", "ok", map[string]any{"record": map[string]string{"id": id, "name": r.PostForm.Get("sub_domain")}})
	case "Record.Remark":
		if f.failRemark {
			reply("8", "remark refused", nil)
			return
		}
		f.recs[find(r.PostForm.Get("record_id"))]["remark"] = r.PostForm.Get("remark")
		reply("1", "ok", nil)
	case "Record.Modify":
		i := find(r.PostForm.Get("record_id"))
		if i < 0 {
			reply("8", "no such record", nil)
			return
		}
		f.recs[i]["value"] = r.PostForm.Get("value")
		reply("1", "ok", nil)
	case "Record.Remove":
		i := find(r.PostForm.Get("record_id"))
		if i < 0 {
			reply("8", "no such record", nil)
			return
		}
		f.recs = append(f.recs[:i], f.recs[i+1:]...)
		reply("1", "ok", nil)
	default:
		http.NotFound(w, r)
	}
}

func TestDNSPodProvider(t *testing.T) {
	f := &fakeDNSPod{}
	srv := httptest.NewServer(f)
	defer srv.Close()
	p := NewDNSPod(Config{ID: "123", Key: "s3cr3t", Domain: "24haowan.com", Subdomain: "cf"})
	p.URL = srv.URL
	ctx := context.Background()

	// An empty zone (code 10) is no records, not an error.
	if got, err := p.List(ctx); err != nil || len(got) != 0 {
		t.Fatalf("empty: %v %v", got, err)
	}
	// Someone else's records: the wildcard, an unmarked one under cf.
	f.with(func() {
		f.recs = append(f.recs,
			map[string]string{"id": "1", "name": "*", "type": "CNAME", "value": "24haowan.com.", "ttl": "600", "remark": ""},
			map[string]string{"id": "2", "name": "bob.cf", "type": "A", "value": "1.1.1.1", "ttl": "600", "remark": ""},
			map[string]string{"id": "3", "name": "www", "type": "A", "value": "1.1.1.2", "ttl": "600", "remark": Marker})
	})

	r, err := p.Upsert(ctx, Record{Name: "verky.cf", Type: "A", Value: "23.119.126.213", TTL: TTL})
	if err != nil || r.ID == "" {
		t.Fatalf("create: %+v %v", r, err)
	}
	got, err := p.List(ctx)
	if err != nil || len(got) != 1 || got[0].Name != "verky.cf" || got[0].Value != "23.119.126.213" || got[0].TTL != TTL {
		t.Fatalf("list: %+v %v — only the marked record under cf", got, err)
	}
	r.Value = "23.119.126.99"
	if _, err := p.Upsert(ctx, r); err != nil {
		t.Fatal(err)
	}
	if got, _ := p.List(ctx); len(got) != 1 || got[0].ID != r.ID || got[0].Value != "23.119.126.99" {
		t.Fatalf("modify: %+v", got)
	}
	if err := p.Delete(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	if got, _ := p.List(ctx); len(got) != 0 {
		t.Fatalf("delete: %+v", got)
	}
	// The unclaimed-name guard (claude-fleet#3337): the marked TXT on *.cf
	// is listed, quotes or none; an unmarked one, or a TXT anywhere else, not.
	f.with(func() {
		f.recs = append(f.recs,
			map[string]string{"id": "20", "name": "*.cf", "type": "TXT", "value": `"not claimed"`, "ttl": "600", "remark": Marker},
			map[string]string{"id": "21", "name": "*.cf", "type": "TXT", "value": "theirs", "ttl": "600", "remark": ""},
			map[string]string{"id": "22", "name": "alice.cf", "type": "TXT", "value": "x", "ttl": "600", "remark": Marker})
	})
	if got, _ := p.List(ctx); len(got) != 1 || got[0].Name != "*.cf" || got[0].Type != "TXT" || got[0].Value != "not claimed" {
		t.Fatalf("guard: %+v", got)
	}
	f.with(func() { f.recs = f.recs[:len(f.recs)-3] })

	// Outside the subdomain: refused before any call.
	var n, m int
	f.with(func() { n = len(f.calls) })
	_, err = p.Upsert(ctx, Record{Name: "www", Type: "A", Value: "1.2.3.4", TTL: TTL})
	f.with(func() { m = len(f.calls) })
	if err == nil || m != n {
		t.Fatalf("www: %v, %d calls", err, m-n)
	}

	// A record that cannot be marked is removed again (else every tick
	// would make one more).
	f.with(func() { f.failRemark = true })
	if _, err := p.Upsert(ctx, Record{Name: "verky.cf", Type: "A", Value: "23.119.126.213", TTL: TTL}); err == nil {
		t.Fatal("unmarked create answered ok")
	}
	f.with(func() {
		for _, rec := range f.recs {
			if rec["name"] == "verky.cf" {
				t.Errorf("unmarked record left behind: %v", rec)
			}
		}
		// The token never in a URL, never in an error.
		for _, u := range f.urls {
			if strings.Contains(u, "s3cr3t") {
				t.Errorf("token in a URL: %s", u)
			}
		}
	})
	bad := NewDNSPod(Config{ID: "123", Key: "wrong-s3cr3t", Domain: "24haowan.com", Subdomain: "cf"})
	bad.URL = srv.URL
	if _, err := bad.List(ctx); err == nil || strings.Contains(err.Error(), "s3cr3t") {
		t.Fatalf("bad token: %v", err)
	}
}

func TestNameOf(t *testing.T) {
	for host, want := range map[string]string{"verky.cf": "verky", "VERKY.cf": "verky", "cf": "", "a.b.cf": "", "www": "", ".cf": ""} {
		if got := NameOf(host, "cf"); got != want {
			t.Errorf("NameOf(%q) = %q, want %q", host, got, want)
		}
	}
}

// TestUserAgentContact: the contact DNSPod is told is the deployment's own
// (CCQUOTA_DNS_CONTACT, issue #3577) — none written in the code.
func TestUserAgentContact(t *testing.T) {
	if got := userAgent(""); got != "claude-fleet-hub/1.0" {
		t.Errorf("no contact: %q", got)
	}
	if got := userAgent("ops@example.com"); got != "claude-fleet-hub/1.0 (ops@example.com)" {
		t.Errorf("contact: %q", got)
	}
	if got := userAgent("a)\r\nX: y"); got != "claude-fleet-hub/1.0 (aX: y)" {
		t.Errorf("a contact cannot break the header: %q", got)
	}
}
