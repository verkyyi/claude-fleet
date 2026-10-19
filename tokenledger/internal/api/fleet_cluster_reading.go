package api

import (
	"context"
	"encoding/json"
	"log"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A cluster's readings (claude-fleet#3734, EPIC #3500 C1's cloud half).
//
// The cluster's fleet-ops reads every user pod's own use against its own
// limits and sends them up its ops link (TypeClusterReadings). The hub keeps a
// pod's reading only when it came from the ops link of the cluster
// fleet_cluster_pods puts that pod in, and the pod still stands — another
// cluster, a pod the hub never made, a malformed value: dropped, one log line.
// What it keeps goes to fleet_cluster_readings (the replica a pod's link is on
// may not be the one fleet-ops is on) and at once to every link on that pod
// that listed CapClusterReading here; each such link's beat hands over a
// reading it has not had yet, so the other replica's pods are a beat late at
// most. No ops link, or no link listing the capability ⇒ nothing is stored or
// sent, byte for byte as before.

var clusterReadingPodRE = regexp.MustCompile(`^u-[a-z0-9]{4,20}$`)

// acceptClusterReadings takes one TypeClusterReadings from nc.
func (s *Server) acceptClusterReadings(ctx context.Context, wire nodeWire, ep store.Endpoint, nc *nodeConn, m control.Message) {
	if !nc.clusterOps {
		refuse(ctx, wire, m.OpID, control.CodeRefused, "cluster readings need the cluster_ops capability in the hello")
		return
	}
	var cr control.ClusterReadings
	if err := json.Unmarshal(m.Payload, &cr); err != nil || len(cr.Pods) > control.MaxClusterReadings {
		refuse(ctx, wire, m.OpID, control.CodeBadMessage, "malformed cluster_readings")
		return
	}
	cluster := strings.ToLower(nc.hostname())
	now := time.Now()
	dropped := 0
	for _, pr := range cr.Pods {
		pod := strings.ToLower(pr.Pod)
		if !clusterReadingPodRE.MatchString(pod) || !pr.Reading.Valid() {
			dropped++
			continue
		}
		p, err := s.Store.ClusterPodOf(pod)
		if err != nil || !p.Held() || !sameMachine(cluster, p.Cluster) {
			dropped++
			continue
		}
		body, err := json.Marshal(pr.Reading)
		if err != nil {
			continue
		}
		if err := s.Store.PutClusterReading(store.ClusterReading{Pod: pod, Cluster: p.Cluster, Body: string(body), TS: pr.Reading.TS}, now); err != nil {
			log.Printf("node %s: keep %s's reading: %v", ep.ID, pod, err)
			continue
		}
		r := pr.Reading
		s.nodes.each(func(id string, c *nodeConn) {
			if c.canClusterReading && sameMachine(c.hostname(), pod) {
				go s.pushClusterReading(id, c, &r)
			}
		})
	}
	if cr.Listed {
		s.clusterPodsListed(cluster, cr.Present) // claude-fleet#4887
	}
	if dropped > 0 && nc.readingDropped.Swap(int64(dropped)) != int64(dropped) {
		log.Printf("node %s (cluster %s): %d pod reading(s) dropped — not a pod this hub made in this cluster, or malformed", ep.ID, cluster, dropped)
	}
}

// pushClusterReading hands nc its pod's reading r (nil = the stored one) when
// it has not had that one or a newer yet. A failed write is not recorded: the
// next beat tries again.
func (s *Server) pushClusterReading(endpointID string, nc *nodeConn, r *control.MachineReading) {
	if !nc.canClusterReading {
		return
	}
	if r == nil {
		row, err := s.Store.ClusterReadingOf(firstLabel(strings.ToLower(nc.hostname())))
		if err != nil || row == nil {
			return
		}
		var mr control.MachineReading
		if json.Unmarshal([]byte(row.Body), &mr) != nil || !mr.Valid() {
			return
		}
		r = &mr
	}
	if nc.readingSent.Load() >= r.TS {
		return
	}
	msg, err := control.New(control.TypeClusterReading, control.ClusterReading{Reading: *r})
	if err != nil {
		return
	}
	wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if s.nodes.get(endpointID) != nc {
		return // a newer link took over; it hears the reading on its own beat
	}
	if err := s.SendNodeWrite(wctx, endpointID, msg); err != nil {
		return
	}
	for {
		old := nc.readingSent.Load()
		if old >= r.TS || nc.readingSent.CompareAndSwap(old, r.TS) {
			return
		}
	}
}
