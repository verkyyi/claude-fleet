package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The cluster's ops link (claude-fleet#3553, EPIC #3500 C8).
//
// fleet-ops is the one node in a cluster that reads it; the one that writes
// is fleet-provisioner, which never talks to the hub. So the hub sends its
// signed provisioner ticket down this link and the agent posts it, as it
// came, to the provisioner it was configured with — never a URL the hub
// names. The ticket is the provisioner's to check (signature, cluster, exp,
// nonce, shape); the agent opens nothing and logs only the provisioner's
// one-line answer, never the ticket (a create's ticket carries a join code).

// clusterOpTimeout bounds the one POST; the hub waits clusterOpWait for the
// round trip.
const clusterOpTimeout = 60 * time.Second

// maxClusterTicket is the provisioner's own MAX_BODY.
const maxClusterTicket = 8192

// answerClusterOp serves one TypeClusterOp.
func (a *Agent) answerClusterOp(ctx context.Context, conn nodeLink, m control.Message) {
	reply := func(msg control.Message) {
		msg.OpID = m.OpID
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = conn.write(wctx, msg)
	}
	fail := func(code, text string) {
		reply(control.Message{Type: control.TypeError, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: text}})
	}
	base := strings.TrimRight(a.cfg.FleetClusterOps, "/")
	if base == "" {
		fail(control.CodeRefused, "this node is no cluster's ops link")
		return
	}
	var req control.ClusterOp
	if err := json.Unmarshal(m.Payload, &req); err != nil || m.OpID == "" || req.Ticket == "" || len(req.Ticket) > maxClusterTicket {
		fail(control.CodeBadArgs, "malformed cluster_op")
		return
	}
	rctx, cancel := context.WithTimeout(ctx, clusterOpTimeout)
	defer cancel()
	var res control.ClusterOpResult
	hreq, err := http.NewRequestWithContext(rctx, http.MethodPost, base+"/v1/op", strings.NewReader(req.Ticket))
	if err != nil {
		fail(control.CodeBadArgs, "cluster_op: bad provisioner address")
		return
	}
	hreq.Header.Set("Content-Type", "text/plain")
	started := time.Now()
	resp, err := a.http.Do(hreq)
	if err != nil {
		res.RC, res.Error = 1, err.Error()
	} else {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
		resp.Body.Close()
		var body struct {
			OK      bool   `json:"ok"`
			Result  string `json:"result"`
			Refused string `json:"refused"`
		}
		_ = json.NewDecoder(bytes.NewReader(raw)).Decode(&body)
		res.Line = body.Result
		if res.Line == "" {
			res.Line = body.Refused
		}
		switch {
		case resp.StatusCode == http.StatusOK && body.OK:
			res.RC = 0
		case resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusRequestEntityTooLarge:
			res.RC = 3
		default:
			res.RC = 1
			if res.Line == "" {
				res.Line = "provisioner answered HTTP " + resp.Status
			}
		}
	}
	log.Printf("cluster_op: provisioner rc=%d in %s: %s%s", res.RC, time.Since(started).Round(time.Millisecond), res.Line, res.Error)
	out, err := control.New(control.TypeClusterOpResult, res)
	if err != nil {
		fail("INTERNAL", "cluster_op: result does not encode")
		return
	}
	reply(out)
}
