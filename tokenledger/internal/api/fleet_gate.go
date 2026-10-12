package api

// The public gate (claude-fleet#3574, EPIC #3569 C4): 公开前必须先完成的安全项,
// each PASS or FAIL, read in one place. The items are conf/public-gate.tsv's
// rows — the ONE copy, packed into the client manifest so the hub reads the very
// bytes bin/fleet-gate-check.sh reads. A where=node row is judged on each
// machine (control.Heartbeat.Gate) and folded here; a where=hub row is judged
// by gateHubJudge below, from the hub's own settings and every login's beat.
//
//   GET /v1/fleet/gate  (admin)       every item, with each machine's verdict
//   GET /v1/node/gate   (node token)  the where=hub items only — what a
//                                     machine's `fleet doctor` cannot see; no
//                                     other machine named
//
// A #3500 member that delivers its item makes its judge here (or the script's)
// go green; it never edits the table. The design is EPIC #3500 v3, not here.

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// gateTablePath is the table's path in the repo and in the client pack.
const gateTablePath = "conf/public-gate.tsv"

// gateTableBytes reads the table; the seam the tests replace.
var gateTableBytes = func() ([]byte, error) { return fleetclient.Files.ReadFile(gateTablePath) }

// gateCredMax is the longest a credential a session can read may live.
const gateCredMax = 12 * time.Hour

// Seams for the hub's own judges.
var (
	gateGetenv        = os.Getenv
	gateReleaseDir    = "/etc/ccquota-release"
	gateSATokenPath   = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	gateCredLifetimes = func() []gateCred {
		// Every credential the hub hands a machine or a session. 0 = no
		// expiry (lives until revoked). #3500 C19 shortens these.
		return []gateCred{
			{"中转凭据 frl1", 0},
			{"会话通行证 fcp-h1", SessionCredTTL},
		}
	}
)

type gateCred struct {
	name string
	ttl  time.Duration
}

type gateRow struct {
	N                                      int
	ID, Where, Before, Source, Title, Rule string
}

// GateMachine is one machine's verdict on a where=node item.
type GateMachine struct {
	Machine string `json:"machine"`
	Pass    bool   `json:"pass"`
	Why     string `json:"why,omitempty"`
}

// GateItemView is one item's verdict.
type GateItemView struct {
	N        int           `json:"n"`
	ID       string        `json:"id"`
	Where    string        `json:"where"`
	Before   string        `json:"before"`
	Source   string        `json:"source"`
	Title    string        `json:"title"`
	Pass     bool          `json:"pass"`
	Why      string        `json:"why"`
	Machines []GateMachine `json:"machines,omitempty"`
}

// GateView is the gate: how many items pass, of how many.
type GateView struct {
	Pass  int            `json:"pass"`
	Total int            `json:"total"`
	Items []GateItemView `json:"items"`
}

func parseGateTable(b []byte) ([]gateRow, error) {
	var rows []gateRow
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		line := sc.Text()
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		c := strings.Split(line, "\t")
		n, err := strconv.Atoi(c[0])
		if len(c) < 7 || err != nil || (c[2] != "node" && c[2] != "hub") {
			return nil, fmt.Errorf("%s: bad row %q", gateTablePath, line)
		}
		rows = append(rows, gateRow{N: n, ID: c[1], Where: c[2], Before: c[3], Source: c[4], Title: c[5], Rule: c[6]})
	}
	if len(rows) == 0 {
		return nil, errors.New(gateTablePath + ": no rows")
	}
	return rows, nil
}

// gateHubJudge judges the where=hub items. detail names machines and logins
// (the admin's view); a node's answer gets counts only.
var gateHubJudge = map[string]func(s *Server, nodes []NodeView, detail bool) (bool, string){
	"release-key": func(s *Server, _ []NodeView, _ bool) (bool, string) {
		if s.Releases != nil && s.Releases.Key != nil {
			return false, "入口拿着发布签名私钥（CCQUOTA_FLEET_RELEASE_KEY）"
		}
		if gateGetenv("CCQUOTA_FLEET_RELEASE_KEY") != "" {
			return false, "入口的环境里配着发布签名私钥（CCQUOTA_FLEET_RELEASE_KEY）"
		}
		if ents, err := os.ReadDir(gateReleaseDir); err == nil && len(ents) > 0 {
			return false, "入口挂着 " + gateReleaseDir
		}
		return true, "入口的环境与挂载里没有发布签名私钥"
	},
	"cloud-perms": func(*Server, []NodeView, bool) (bool, string) {
		if gateGetenv("KUBERNETES_SERVICE_HOST") == "" {
			return false, "入口不在集群里跑，读不到它的权限"
		}
		if _, err := os.Stat(gateSATokenPath); err == nil {
			return false, "入口 pod 挂着服务账号令牌（automountServiceAccountToken 没关）"
		}
		return true, "入口 pod 没挂服务账号令牌"
	},
	"revocations": func(*Server, []NodeView, bool) (bool, string) {
		return false, "入口还不发吊销名单（/v1/relay/revocations 未上线）"
	},
	"cred-ttl": func(_ *Server, nodes []NodeView, detail bool) (bool, string) {
		var long []string
		for _, c := range gateCredLifetimes() {
			switch {
			case c.ttl <= 0:
				long = append(long, c.name+" 没有有效期（直到吊销）")
			case c.ttl > gateCredMax:
				long = append(long, c.name+" "+durWords(c.ttl))
			}
		}
		var open []string
		for _, n := range nodes {
			if n.Role != store.NodeRoleManaged || n.MachineLink || n.Status == "lost" {
				continue
			}
			if n.Credsep != control.CredsepSeparated {
				open = append(open, n.Hostname+"/"+n.OSUser)
			}
		}
		var why []string
		if len(long) > 0 {
			why = append(why, "超过 12h："+strings.Join(long, "、"))
		}
		if len(open) > 0 {
			sort.Strings(open)
			w := fmt.Sprintf("%d 个托管登录没做凭据隔离", len(open))
			if detail {
				w += "：" + strings.Join(open, "、")
			}
			why = append(why, w)
		}
		if len(why) > 0 {
			return false, strings.Join(why, "；")
		}
		return true, "每种凭据 ≤ 12h，托管登录都做了凭据隔离"
	},
}

// durWords is a duration as a person reads it: 24h, 168h, 30m.
func durWords(d time.Duration) string {
	if d%time.Hour == 0 {
		return fmt.Sprintf("%dh", int(d/time.Hour))
	}
	return fmt.Sprintf("%dm", int(d/time.Minute))
}

// gateNodeFold folds every machine's where=node verdicts into one per item: a
// machine fails an item when any of its logins said so; an online managed
// machine that said nothing is red too (its agent is older than the gate).
func gateNodeFold(rows []gateRow, nodes []NodeView) map[string][]GateMachine {
	type mv struct {
		said bool
		item map[string]control.GateItem
	}
	machines := map[string]*mv{}
	for _, n := range nodes {
		if n.Status == "lost" {
			continue
		}
		managed := n.Role == store.NodeRoleManaged || n.MachineLink
		if len(n.Gate) == 0 && !managed {
			continue
		}
		m := machines[n.Hostname]
		if m == nil {
			m = &mv{item: map[string]control.GateItem{}}
			machines[n.Hostname] = m
		}
		for _, it := range n.Gate {
			m.said = true
			if old, ok := m.item[it.ID]; !ok || (old.Pass && !it.Pass) {
				m.item[it.ID] = it
			}
		}
	}
	names := make([]string, 0, len(machines))
	for h := range machines {
		names = append(names, h)
	}
	sort.Strings(names)
	out := map[string][]GateMachine{}
	for _, r := range rows {
		if r.Where != "node" {
			continue
		}
		for _, h := range names {
			m := machines[h]
			it, ok := m.item[r.ID]
			switch {
			case !m.said:
				out[r.ID] = append(out[r.ID], GateMachine{Machine: h, Why: "没报（agent 旧于 #3574）"})
			case !ok:
				out[r.ID] = append(out[r.ID], GateMachine{Machine: h, Why: "没判这一项（fleet-gate-check.sh 旧于表）"})
			default:
				out[r.ID] = append(out[r.ID], GateMachine{Machine: h, Pass: it.Pass, Why: it.Why})
			}
		}
	}
	return out
}

// gate builds the verdicts; hubOnly keeps the where=hub items, detail names
// machines and logins.
func (s *Server) gate(now time.Time, hubOnly, detail bool) (GateView, error) {
	b, err := gateTableBytes()
	if err != nil {
		return GateView{}, fmt.Errorf("no %s in this build: %w", gateTablePath, err)
	}
	rows, err := parseGateTable(b)
	if err != nil {
		return GateView{}, err
	}
	snap, err := s.Nodes(now)
	if err != nil {
		return GateView{}, err
	}
	folded := gateNodeFold(rows, snap.Nodes)
	v := GateView{Items: []GateItemView{}}
	for _, r := range rows {
		if hubOnly && r.Where != "hub" {
			continue
		}
		it := GateItemView{N: r.N, ID: r.ID, Where: r.Where, Before: r.Before, Source: r.Source, Title: r.Title}
		if r.Where == "hub" {
			if j := gateHubJudge[r.ID]; j != nil {
				it.Pass, it.Why = j(s, snap.Nodes, detail)
			} else {
				it.Why = "入口没有这一项的判据（入口旧于表）"
			}
		} else {
			ms := folded[r.ID]
			var red []string
			for _, m := range ms {
				if !m.Pass {
					red = append(red, m.Machine+"："+m.Why)
				}
			}
			switch {
			case len(ms) == 0:
				it.Why = "没有机器报上来"
			case len(red) > 0:
				it.Why = fmt.Sprintf("%d/%d 台机器没做到 — %s", len(red), len(ms), strings.Join(red, "；"))
			default:
				it.Pass, it.Why = true, fmt.Sprintf("%d 台机器都做到了", len(ms))
			}
			it.Machines = ms
		}
		if it.Pass {
			v.Pass++
		}
		v.Items = append(v.Items, it)
	}
	v.Total = len(v.Items)
	return v, nil
}

// handleFleetGate is GET /v1/fleet/gate: the operator's whole gate.
func (s *Server) handleFleetGate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	v, err := s.gate(time.Now(), false, true)
	if err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, v)
}

// handleNodeGate is GET /v1/node/gate: the hub's own items, for a machine's
// fleet-gate-check.sh — counts only, no other machine named.
func (s *Server) handleNodeGate(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.nodeEndpoint(w, r); !ok {
		return
	}
	if r.Method != http.MethodGet {
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	v, err := s.gate(time.Now(), true, false)
	if err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, v)
}
