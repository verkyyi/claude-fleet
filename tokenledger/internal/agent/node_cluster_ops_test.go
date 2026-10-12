package agent

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// recLink keeps what the agent writes back.
type recLink struct{ out []control.Message }

func (l *recLink) write(_ context.Context, m control.Message) error {
	l.out = append(l.out, m)
	return nil
}
func (l *recLink) read(context.Context) (control.Message, error) { select {} }
func (l *recLink) ping(context.Context) error                    { return nil }
func (l *recLink) close(string)                                  {}
func (l *recLink) closeNow()                                     {}

// fleet-ops carries the hub's ticket to its own provisioner as it came, and
// hands back the provisioner's exit and line (claude-fleet#3553); a node that
// is no cluster's ops link refuses.
func TestClusterOpCarriesTheTicket(t *testing.T) {
	var got string
	prov := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = string(b)
		if r.URL.Path != "/v1/op" || got == "c1.refuse.me" {
			w.WriteHeader(http.StatusForbidden)
			w.Write([]byte(`{"ok": false, "result": "refused: not the hub's"}`))
			return
		}
		w.Write([]byte(`{"ok": true, "result": "create-user-pod u-abcd: done"}`))
	}))
	defer prov.Close()
	ask := func(a *Agent, ticket string) control.Message {
		t.Helper()
		l := &recLink{}
		m, _ := control.New(control.TypeClusterOp, control.ClusterOp{Ticket: ticket})
		a.answerClusterOp(context.Background(), l, m)
		if len(l.out) != 1 || l.out[0].OpID != m.OpID {
			t.Fatalf("answers = %+v; want one, by op_id", l.out)
		}
		return l.out[0]
	}
	a := &Agent{cfg: Config{FleetClusterOps: prov.URL + "/"}, http: prov.Client()}
	for ticket, want := range map[string]int{"c1.good.sig": 0, "c1.refuse.me": 3} {
		r := ask(a, ticket)
		var res control.ClusterOpResult
		_ = json.Unmarshal(r.Payload, &res)
		if r.Type != control.TypeClusterOpResult || res.RC != want || got != ticket || res.Line == "" {
			t.Fatalf("%s: %+v %+v (provisioner got %q); want rc %d", ticket, r, res, got, want)
		}
	}
	if r := ask(&Agent{cfg: Config{}, http: prov.Client()}, "c1.good.sig"); r.Type != control.TypeError {
		t.Fatalf("no provisioner configured: %+v; want a refusal", r)
	}
	gone := httptest.NewServer(http.NotFoundHandler())
	gone.Close()
	r := ask(&Agent{cfg: Config{FleetClusterOps: gone.URL}, http: prov.Client()}, "c1.good.sig")
	var res control.ClusterOpResult
	_ = json.Unmarshal(r.Payload, &res)
	if res.RC != 1 || res.Error == "" {
		t.Fatalf("provisioner down: %+v; want rc 1 with the error", res)
	}
}
