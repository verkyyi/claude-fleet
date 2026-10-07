package api

import (
	"crypto/subtle"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sort"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// An SSH relay with two hub replicas (claude-fleet#2151, EPIC #2119 C8).
//
// A relay is not a call: it is a byte stream spliced onto the machine's link,
// and the pieces it needs — sshRelayTable, the node's conn — live in the one
// process holding that link. So it cannot be handed across per call the way
// #2124 hands a write (node_route.go). Instead the replica a client lands on,
// when it holds no link able to relay to the machine and another replica does
// (fleet_node_conns, caps), reverse-proxies the client's whole websocket to
// that replica, which serves it exactly as a relay of its own: the same
// identity checks (the client's headers travel unchanged, a certificate is
// proven in-band through the proxy), the same caps, the same audit row.
//
// The agent's data half dials the public address too, so it may land on the
// replica that did NOT ask for it. That replica finds no such relay in its
// table, and when the agent's link is held by another replica it proxies the
// data half there the same way.
//
// A proxied request carries the replicas' shared token, and a request that
// carries it is never proxied again (a stale row would bounce it back). Off —
// Server.Replica nil, the single hub — none of this runs, and the relay is
// byte for byte what it was (TestSSHRelayReplicaSingleNeverProxies).

// relayHopped: r was already proxied here by another replica.
func (s *Server) relayHopped(r *http.Request) bool {
	got := r.Header.Get(replicaTokenHeader)
	return got != "" && subtle.ConstantTimeCompare([]byte(got), []byte(s.Replica.Token)) == 1
}

// sshRelayLocal reports whether a link THIS process holds can relay to host.
func (s *Server) sshRelayLocal(host string) bool {
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	for _, c := range s.nodes.conns {
		if c.canSSHRelay && c.hostname() == host && control.Compatible(int(c.proto.Load())) {
			return true
		}
	}
	return false
}

// peerRelayHosts is, per hostname, the other replicas' links that offered
// CapSSHRelay (nil on a single hub, and when none does).
func (s *Server) peerRelayHosts() map[string][]store.NodeConn {
	peers := s.peerConns()
	if len(peers) == 0 {
		return nil
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		log.Printf("fleet: read nodes for the relay: %v", err)
		return nil
	}
	out := map[string][]store.NodeConn{}
	for _, n := range nodes {
		pc, ok := peers[n.EndpointID]
		if !ok || !pc.HasCap(control.CapSSHRelay) || !control.Compatible(n.Proto) {
			continue
		}
		out[n.Hostname] = append(out[n.Hostname], pc)
	}
	for _, l := range out {
		sort.Slice(l, func(i, j int) bool { return l[i].EndpointID < l[j].EndpointID })
	}
	return out
}

// sshRelayPeer is the other replica to hand a client's relay to host to: only
// when this one holds no link able to carry it and another does.
func (s *Server) sshRelayPeer(r *http.Request, host string) (store.NodeConn, bool) {
	if s.Replica == nil || s.relayHopped(r) || s.sshRelayLocal(host) {
		return store.NodeConn{}, false
	}
	l := s.peerRelayHosts()[host]
	if len(l) == 0 {
		return store.NodeConn{}, false
	}
	return l[0], true
}

// proxyRelay hands the whole request — a websocket upgrade — to peer and
// copies bytes both ways until either side ends.
func (s *Server) proxyRelay(w http.ResponseWriter, r *http.Request, peer store.NodeConn, what string) {
	target, err := url.Parse(peer.URL)
	if err != nil {
		httpError(w, http.StatusBadGateway, "replica "+peer.Replica+": bad address: "+err.Error())
		return
	}
	s.forwarded.Add(1)
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.SetXForwarded()
			pr.Out.Header.Set(replicaTokenHeader, s.Replica.Token)
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("relay: hand %s to replica %s: %v", what, peer.Replica, err)
			httpError(w, http.StatusBadGateway, "the replica holding the machine's link could not be reached")
		},
	}
	if s.Replica.Client != nil && s.Replica.Client.Transport != nil {
		rp.Transport = s.Replica.Client.Transport
	}
	rp.ServeHTTP(w, r)
}

// sshRelayReadiness answers, for a whole machine list, whether a relay to host
// could be carried right now by this replica or another one. The other
// replicas' links are read once.
func (s *Server) sshRelayReadiness() func(host string) bool {
	peers := s.peerRelayHosts()
	return func(host string) bool {
		return s.sshRelayLocal(host) || len(peers[host]) > 0
	}
}
