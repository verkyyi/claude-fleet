package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The hub half of the OAuth refresh relay (claude-fleet#1490).
//
// The vault's one writer per account is unchanged: Vault.Lease still holds
// the row lock, still saves the rotated refresh token before anyone receives
// the result. What moves is the one outbound POST — to an admin node whose
// network the provider accepts — because the production hub's own egress is
// a mainland IP that auth.openai.com answers with 403
// unsupported_country_region_territory. The node sees the form for exactly
// one request and the provider's answer, in memory, and the audit row of the
// refresh names it: refresh_via=<login>@<host>.
//
// One node is asked ONCE per refresh and never a second. A refresh token is
// single-use: if the first node delivered the POST and only its answer was
// lost, the provider has already rotated the token, and re-sending the same
// form from another node would get invalid_grant and strand the account —
// the same reason the direct path never retries a lost HTTP answer.

// oauthRefreshTimeout bounds one relayed refresh end to end: the node's own
// POST is bounded tighter (agent.oauthRefreshTimeout), so a node that cannot
// reach the provider answers inside this, and only a dead link runs it out.
const oauthRefreshTimeout = 20 * time.Second

// OAuthRefreshNode names the node a relayed refresh would go to right now, or
// why none can take it — the roster's /nodes answer and fleet-doctor read it,
// and NodeOAuthRefresh picks the same way.
func (s *Server) OAuthRefreshNode(now time.Time) (endpointID, name string, err error) {
	c, id, name, err := s.pickOAuthRefreshNode(now)
	if err != nil {
		return "", "", err
	}
	_ = c
	return id, name, nil
}

// pickOAuthRefreshNode chooses the connected admin node that offered the relay
// and is online (fresh heartbeat), is not a SPOT pod (whose egress is the
// cluster's own, the one being avoided), and carries the least load per
// core; ties break on endpoint id, so the pick is deterministic.
func (s *Server) pickOAuthRefreshNode(now time.Time) (*nodeConn, string, string, error) {
	rows, err := s.Store.Nodes()
	if err != nil {
		return nil, "", "", fmt.Errorf("%w: read the node roster: %v", credvault.ErrRefreshUnavailable, err)
	}
	byID := make(map[string]store.Node, len(rows))
	for _, n := range rows {
		byID[n.EndpointID] = n
	}
	kinds, _ := s.Store.EphemeralEndpoints()
	type cand struct {
		id, name string
		c        *nodeConn
		load     float64
	}
	var cands []cand
	s.nodes.each(func(id string, c *nodeConn) {
		if !c.admin || !c.canOAuthRefresh || !control.Compatible(int(c.proto.Load())) {
			return
		}
		if kinds[id] == store.NodeKindEphemeral {
			return
		}
		n, ok := byID[id]
		if !ok || NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now) != "online" {
			return
		}
		v := nodeView(n, now)
		load := v.Load1
		if v.NCPU > 0 {
			load /= float64(v.NCPU)
		}
		cands = append(cands, cand{id: id, name: c.user() + "@" + c.hostname(), c: c, load: load})
	})
	if len(cands) == 0 {
		return nil, "", "", fmt.Errorf("%w: no admin node is online to relay the refresh", credvault.ErrRefreshUnavailable)
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].load != cands[j].load {
			return cands[i].load < cands[j].load
		}
		return cands[i].id < cands[j].id
	})
	return cands[0].c, cands[0].id, cands[0].name, nil
}

// NodeOAuthRefresh is credvault.ProxyRefresher.Via: it carries one token
// request to the chosen admin node and returns the provider's answer. Every
// failure before an answer is ErrRefreshUnavailable (the leasing node sees
// that word, not a 403 page); the node's name is set on the answer whenever
// one was asked, so the audit says which.
func (s *Server) NodeOAuthRefresh(ctx context.Context, provider string, form map[string]string) (credvault.ProxyAnswer, error) {
	c, _, name, err := s.pickOAuthRefreshNode(time.Now())
	if err != nil {
		return credvault.ProxyAnswer{}, err
	}
	ans := credvault.ProxyAnswer{Via: name}
	unavailable := func(format string, a ...any) (credvault.ProxyAnswer, error) {
		return ans, fmt.Errorf("%w: %s", credvault.ErrRefreshUnavailable, fmt.Sprintf(format, a...))
	}
	msg, err := control.New(control.TypeOAuthRefresh, control.OAuthRefresh{Provider: provider, Form: form})
	if err != nil {
		return unavailable("encode the request: %v", err)
	}
	ch := c.pending.add(msg.OpID)
	defer c.pending.remove(msg.OpID)
	ctx, cancel := context.WithTimeout(ctx, oauthRefreshTimeout)
	defer cancel()
	if err := wsjson.Write(ctx, c.conn, msg); err != nil {
		return unavailable("control channel write to %s failed: %v", name, err)
	}
	select {
	case <-ctx.Done():
		return unavailable("%s did not answer the %s refresh within %s", name, provider, oauthRefreshTimeout)
	case reply := <-ch:
		if reply.Type == control.TypeError {
			code, text := "REMOTE_ERROR", "the node refused the refresh"
			if reply.Error != nil {
				code, text = reply.Error.Code, reply.Error.Message
			}
			return unavailable("%s refused the %s refresh: %s: %s", name, provider, code, text)
		}
		var r control.OAuthRefreshResult
		if err := json.Unmarshal(reply.Payload, &r); err != nil {
			return unavailable("%s answered the %s refresh with a malformed result", name, provider)
		}
		if r.Error != "" {
			return unavailable("%s could not reach the %s token endpoint: %s", name, provider, r.Error)
		}
		if r.Status == 0 {
			return unavailable("%s answered the %s refresh without a status", name, provider)
		}
		log.Printf("credentials: %s refresh relayed via %s: HTTP %d", provider, name, r.Status)
		ans.Status, ans.Body = r.Status, []byte(r.Body)
		return ans, nil
	}
}
