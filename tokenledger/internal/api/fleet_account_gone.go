package api

import (
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 机器回不来时收掉一条落不了地的删除 (claude-fleet#3957).
//
// A remove is queued (remove_pending) and sent only to a connected admin of
// its machine. When the machine goes for good before that — scaled to zero,
// its node identity retired, the disk kept but nothing to boot it with — the
// row can never move: `forget` refuses an op that has not landed, and the
// remove waits for an admin that will not come. `forget --machine-gone` is
// the operator's explicit end for exactly that row: refused while ANY link of
// that machine is open (on this replica or another — then the remove lands
// by itself) and for a pod the hub made (its remove is the pod's destroy);
// otherwise the row becomes removed, its detail and the audit both saying the
// login's home was NOT archived on the source machine. Never automatic, never
// silent.

// accountGoneDetail is what a closed-by-hand row says, by the state it left.
func accountGoneDetail(from, actor string) string {
	what := "家目录未在源机归档 (home not archived on the source machine)"
	if from == store.AccountUnknown {
		what = "家目录是否在源机归档不明 (whether the home was archived on the source machine is unknown)"
	}
	return "closed on the hub only — the machine is gone, the remove never landed; " + what + "; by " + actor
}

// liveLinksOn is every endpoint with an open link whose machine is hostname:
// this replica's links by their hello's hostname, the other replicas' by the
// roster's.
func (s *Server) liveLinksOn(hostname string) []string {
	seen := map[string]bool{}
	s.nodes.each(func(id string, c *nodeConn) {
		if strings.EqualFold(c.hostname(), hostname) {
			seen[id] = true
		}
	})
	if peers := s.peerConns(); len(peers) > 0 {
		if roster, err := s.Store.Nodes(); err == nil {
			for _, n := range roster {
				if _, ok := peers[n.EndpointID]; ok && strings.EqualFold(n.Hostname, hostname) {
					seen[n.EndpointID] = true
				}
			}
		}
	}
	out := make([]string, 0, len(seen))
	for id := range seen {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// closeAccountMachineGone is `forget` with machine_gone: see the top of the file.
func (s *Server) closeAccountMachineGone(req FleetAccountRequest, actor string, now time.Time) error {
	target := req.PrincipalID + "@" + req.Hostname
	refuse := func(err error) error {
		_ = s.Store.HubAudit(actor, "account.machine_gone", target, "refused", err.Error(), now)
		return err
	}
	if req.Hostname == "" {
		return errors.New("machine_gone needs a hostname: it closes one login on one machine")
	}
	if live := s.liveLinksOn(req.Hostname); len(live) > 0 {
		return refuse(fmt.Errorf("%w: %s is connected (%s): the remove is sent to it and lands there — not closed by hand",
			store.ErrAccountState, req.Hostname, strings.Join(live, ", ")))
	}
	if s.clusterPodOf(req.Hostname) != nil {
		return refuse(fmt.Errorf("%w: %s is a pod the hub made: its remove is the pod's destroy, through its cluster",
			store.ErrAccountState, req.Hostname))
	}
	var detail string
	from, err := s.Store.CloseAccountMachineGone(req.PrincipalID, req.Hostname, func(from string) string {
		detail = accountGoneDetail(from, actor)
		return detail
	}, now)
	if err != nil {
		return refuse(err)
	}
	_ = s.Store.HubAudit(actor, "account.machine_gone", target, "ok", from+" → removed: "+detail, now)
	log.Printf("fleet: %s on %s closed by hand (%s → removed): machine gone, home not archived there", req.PrincipalID, req.Hostname, from)
	return nil
}
