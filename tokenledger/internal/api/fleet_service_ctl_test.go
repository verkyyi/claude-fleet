package api

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#2527: service_control acts on one entry of a machine's register,
// down its login's own lane — 200 on your own entry, 403 on another login's,
// 404 on an entry the register does not hold, and nothing reaches the node
// for a refused call.
func TestServiceControl(t *testing.T) {
	h, n := machineRig(t)
	for _, l := range []string{"alpha", "beta"} {
		n.beat(l, control.Heartbeat{Hostname: "m4", OSUser: l, NCPU: 10, ObservedAt: time.Now()})
	}
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		Services: []control.ServiceStatus{
			{Name: "daily-report", Kind: "task", Login: "alpha", State: "scheduled"},
			{Name: "sms-watch", Kind: "service", Login: "alpha", State: "running"},
			{Name: "beta-thing", Kind: "service", Login: "beta", State: "running"},
		}})
	waitFor(t, 3*time.Second, "m4 carries its register", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && len(ms[0].Services) == 3
	})
	// The HTTP door as a caller who holds alpha on m4 only.
	h.srv.fleetScopeHook = func(*http.Request) (func(string, string) bool, error) {
		return func(host, login string) bool { return host == "m4" && login == "alpha" }, nil
	}
	ctl := func(login, name, action, key string, extra map[string]any) map[string]any {
		a := map[string]any{"machine": "m4", "login": login, "name": name, "action": action, "idempotency_key": key}
		for k, v := range extra {
			a[k] = v
		}
		return a
	}

	op := postFleet(t, h, "service_control", ctl("alpha", "daily-report", "run_now", "k1", nil), 200)
	if op["action"] != "service_control" || op["status"] != "accepted" {
		t.Fatalf("own run_now = %v", op)
	}
	waitFor(t, 3*time.Second, "alpha's lane got it", func() bool { return n.count("alpha") == 1 })
	n.mu.Lock()
	env := n.writes["alpha"][0]
	n.mu.Unlock()
	p, _ := env["params"].(map[string]any)
	if env["action"] != "service_control" || env["fleet_id"] != "" || p["login"] != "alpha" ||
		p["name"] != "daily-report" || p["action"] != "run_now" {
		t.Fatalf("the envelope alpha's lane got = %v", env)
	}
	postFleet(t, h, "service_control", ctl("alpha", "daily-report", "set_schedule", "k2",
		map[string]any{"at": "07:30", "tz": "Asia/Shanghai"}), 200)
	postFleet(t, h, "service_control", ctl("alpha", "sms-watch", "restart", "k3", nil), 200)
	// A retry of the same key is the same operation, not a second write.
	if again := postFleet(t, h, "service_control", ctl("alpha", "daily-report", "run_now", "k1", nil), 200); again["operation_id"] != op["operation_id"] {
		t.Fatalf("a retried key = %v; want %v", again["operation_id"], op["operation_id"])
	}

	// Another login's entry: 403, and nothing sent.
	postFleet(t, h, "service_control", ctl("beta", "beta-thing", "stop", "k4", nil), 403)
	// Not in the register: 404; a service has no run_now / schedule: 400.
	postFleet(t, h, "service_control", ctl("alpha", "ghost", "stop", "k5", nil), 404)
	postFleet(t, h, "service_control", ctl("alpha", "sms-watch", "run_now", "k6", nil), 400)
	// Malformed: 400 before anything is looked up.
	for i, bad := range []map[string]any{
		ctl("alpha", "daily-report", "rm", "b1", nil),
		ctl("alpha", "../x", "stop", "b2", nil),
		ctl("alpha", "daily-report", "set_schedule", "b3", nil),
		ctl("alpha", "daily-report", "set_schedule", "b4", map[string]any{"at": "7pm"}),
		ctl("alpha", "daily-report", "set_schedule", "b5", map[string]any{"at": "07:00", "cron": "0 7 * * *"}),
		ctl("alpha", "daily-report", "stop", "b6", map[string]any{"at": "07:00"}),
		ctl("alpha", "daily-report", "set_schedule", "b7", map[string]any{"cron": "0 7 * *"}),
	} {
		if out := postFleet(t, h, "service_control", bad, 400); out == nil {
			t.Fatalf("bad %d answered nothing", i)
		}
	}
	if n.count("alpha") != 3 || n.count("beta") != 0 {
		t.Fatalf("writes alpha %d beta %d; want 3 and 0", n.count("alpha"), n.count("beta"))
	}

	// A person needs service:control, which the default grant holds.
	pr, err := h.srv.Store.AdoptPrincipal("wx-alpha", "alpha", "Alpha", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(pr, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	h.srv.fleetScopeHook = nil
	as := func(person string) fleetPrincipal {
		r, _ := http.NewRequest(http.MethodGet, "/", nil)
		r = r.WithContext(context.WithValue(withViewer(r.Context(), person), principalKey{}, person))
		p, err := h.srv.FleetPrincipal(r)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-alpha"), "service_control",
		ctl("alpha", "sms-watch", "stop", "p1", nil)); err != nil {
		t.Fatalf("a person on their own entry: %v", err)
	}
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-alpha"), "service_control",
		ctl("beta", "beta-thing", "stop", "p2", nil)); errorObject(err)["code"] != "FORBIDDEN" {
		t.Fatalf("a person on another login's entry: %v; want FORBIDDEN", err)
	}
	h.srv.FleetPersonScopes = []string{"fleet:read"}
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-alpha"), "service_control",
		ctl("alpha", "sms-watch", "start", "p3", nil)); errorObject(err)["code"] != "FORBIDDEN" {
		t.Fatalf("without service:control: %v; want FORBIDDEN", err)
	}
	if n.count("beta") != 0 {
		t.Fatal("a refused call reached beta's lane")
	}
}
