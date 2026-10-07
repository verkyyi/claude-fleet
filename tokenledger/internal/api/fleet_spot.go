package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/spot"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// SPOT nodes (claude-fleet#1428, EPIC #1419 R1): when every fixed machine is
// busy, the hub starts an execution node of its own — a pod of the node image
// on the cluster's SPOT machines — hands it a join code, lets placement use
// it at a reduced weight, and deletes it again after it has sat idle for
// CCQUOTA_FLEET_SPOT_IDLE_MINUTES. The cloud taking the machine back is the
// other way a node ends: its agent gets the kubelet's SIGTERM, tells the hub
// (/v1/node/reclaim), moves its idle sessions off through the ordinary hub
// move, and whatever is still on it when the pod is gone is handled as a
// node that went down unexpectedly — leases released at once (the hub KNOWS
// this one is not coming back), nothing re-dispatched.
//
//	CCQUOTA_FLEET_SPOT_IMAGE          the node image; set = SPOT on (needs CCQUOTA_FLEET=1)
//	CCQUOTA_FLEET_SPOT_HUB_URL        how a pod reaches the hub (default CCQUOTA_FLEET_PUBLIC_URL)
//	CCQUOTA_FLEET_SPOT_NAMESPACE      where pods go (default: the hub's own)
//	CCQUOTA_FLEET_SPOT_MAX            nodes at once (1)
//	CCQUOTA_FLEET_SPOT_IDLE_MINUTES   release after this long with no session (30)
//	CCQUOTA_FLEET_SPOT_BOOT_MINUTES   give up on a pod that has not joined (10; also the join code's life)
//	CCQUOTA_FLEET_SPOT_WEIGHT         placement score multiplier for an ephemeral node (0.5; fleet.spot_weight overrides)
//	CCQUOTA_FLEET_SPOT_GRACE_SECONDS  terminationGracePeriodSeconds: time to move sessions off on reclaim (300)
//	CCQUOTA_FLEET_SPOT_NODE_SELECTOR  k=v,k=v — the SPOT node pool
//	CCQUOTA_FLEET_SPOT_TOLERATIONS    key[=value][:effect],… or a JSON array
//	CCQUOTA_FLEET_SPOT_CPU / _MEMORY  resource requests (none)
//	CCQUOTA_FLEET_SPOT_SERVICE_ACCOUNT, CCQUOTA_FLEET_SPOT_PULL_SECRET
//	CCQUOTA_FLEET_SPOT_POD_JSON       a file merged over the generated Pod (anything else)
//	CCQUOTA_FLEET_SPOT_TICK_SECONDS   reconcile cadence (30)
//	CCQUOTA_FLEET_SPOT_KUBE_URL / _KUBE_TOKEN / _KUBE_CA / _KUBE_INSECURE=1   outside a cluster
//
// Off (no image) adds nothing: no loop, no route, no column read.

// SpotConfig is the parsed configuration.
type SpotConfig struct {
	Image          string            `json:"image"`
	HubURL         string            `json:"hub_url"`
	Namespace      string            `json:"namespace"`
	Max            int               `json:"max"`
	Idle           time.Duration     `json:"-"`
	Boot           time.Duration     `json:"-"`
	Weight         float64           `json:"weight"`
	Grace          int64             `json:"grace_seconds"`
	NodeSelector   map[string]string `json:"node_selector,omitempty"`
	Tolerations    []map[string]any  `json:"tolerations,omitempty"`
	CPU, Memory    string            `json:"-"`
	ServiceAccount string            `json:"-"`
	PullSecret     string            `json:"-"`
	Overlay        map[string]any    `json:"-"`
	Tick           time.Duration     `json:"-"`
	Kube           spot.Config       `json:"-"`
}

// SpotWeightKey is the fleet setting that overrides CCQUOTA_FLEET_SPOT_WEIGHT.
const SpotWeightKey = "fleet.spot_weight"

// DefaultSpotWeight is an ephemeral node's placement multiplier when nothing
// sets one.
const DefaultSpotWeight = 0.5

// ParseSpotConfig reads the environment (getenv; os.Getenv in the hub).
// Enabled is false, with no error, when no image is configured.
func ParseSpotConfig(getenv func(string) string, publicURL string) (cfg SpotConfig, enabled bool, err error) {
	cfg.Image = strings.TrimSpace(getenv("CCQUOTA_FLEET_SPOT_IMAGE"))
	if cfg.Image == "" {
		return cfg, false, nil
	}
	cfg.HubURL = strings.TrimRight(strings.TrimSpace(getenv("CCQUOTA_FLEET_SPOT_HUB_URL")), "/")
	if cfg.HubURL == "" {
		cfg.HubURL = strings.TrimRight(publicURL, "/")
	}
	if cfg.HubURL == "" {
		return cfg, false, errors.New("CCQUOTA_FLEET_SPOT_HUB_URL (or CCQUOTA_FLEET_PUBLIC_URL) is needed: a pod must know how to reach the hub")
	}
	cfg.Namespace = strings.TrimSpace(getenv("CCQUOTA_FLEET_SPOT_NAMESPACE"))
	cfg.Max = 1
	if v := getenv("CCQUOTA_FLEET_SPOT_MAX"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 64 {
			return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_MAX: %q is not an integer 0–64", v)
		}
		cfg.Max = n
	}
	mins := func(key string, def int) (time.Duration, error) {
		v := getenv(key)
		if v == "" {
			return time.Duration(def) * time.Minute, nil
		}
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return 0, fmt.Errorf("%s: %q is not a positive number of minutes", key, v)
		}
		return time.Duration(n) * time.Minute, nil
	}
	if cfg.Idle, err = mins("CCQUOTA_FLEET_SPOT_IDLE_MINUTES", 30); err != nil {
		return cfg, false, err
	}
	if cfg.Boot, err = mins("CCQUOTA_FLEET_SPOT_BOOT_MINUTES", 10); err != nil {
		return cfg, false, err
	}
	cfg.Weight = DefaultSpotWeight
	if v := getenv("CCQUOTA_FLEET_SPOT_WEIGHT"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 || f > 2 {
			return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_WEIGHT: %q is not a number in 0–2", v)
		}
		cfg.Weight = f
	}
	cfg.Grace = 300
	if v := getenv("CCQUOTA_FLEET_SPOT_GRACE_SECONDS"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 30 || n > 3600 {
			return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_GRACE_SECONDS: %q is not 30–3600", v)
		}
		cfg.Grace = n
	}
	cfg.Tick = 30 * time.Second
	if v := getenv("CCQUOTA_FLEET_SPOT_TICK_SECONDS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_TICK_SECONDS: %q is not a positive number of seconds", v)
		}
		cfg.Tick = time.Duration(n) * time.Second
	}
	if cfg.NodeSelector, err = spot.ParseSelector(getenv("CCQUOTA_FLEET_SPOT_NODE_SELECTOR")); err != nil {
		return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_NODE_SELECTOR: %w", err)
	}
	if cfg.Tolerations, err = spot.ParseTolerations(getenv("CCQUOTA_FLEET_SPOT_TOLERATIONS")); err != nil {
		return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_TOLERATIONS: %w", err)
	}
	cfg.CPU, cfg.Memory = getenv("CCQUOTA_FLEET_SPOT_CPU"), getenv("CCQUOTA_FLEET_SPOT_MEMORY")
	for _, q := range []struct{ k, v string }{{"CCQUOTA_FLEET_SPOT_CPU", cfg.CPU}, {"CCQUOTA_FLEET_SPOT_MEMORY", cfg.Memory}} {
		if err := spot.Quantity(q.v); err != nil {
			return cfg, false, fmt.Errorf("%s: %w", q.k, err)
		}
	}
	cfg.ServiceAccount, cfg.PullSecret = getenv("CCQUOTA_FLEET_SPOT_SERVICE_ACCOUNT"), getenv("CCQUOTA_FLEET_SPOT_PULL_SECRET")
	if p := getenv("CCQUOTA_FLEET_SPOT_POD_JSON"); p != "" {
		raw, err := os.ReadFile(p)
		if err != nil {
			return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_POD_JSON: %w", err)
		}
		if err := json.Unmarshal(raw, &cfg.Overlay); err != nil {
			return cfg, false, fmt.Errorf("CCQUOTA_FLEET_SPOT_POD_JSON: %s: %w", p, err)
		}
	}
	cfg.Kube = spot.Config{APIServer: getenv("CCQUOTA_FLEET_SPOT_KUBE_URL"), Token: getenv("CCQUOTA_FLEET_SPOT_KUBE_TOKEN"),
		CAFile: getenv("CCQUOTA_FLEET_SPOT_KUBE_CA"), Insecure: getenv("CCQUOTA_FLEET_SPOT_KUBE_INSECURE") == "1",
		Namespace: cfg.Namespace}
	return cfg, true, nil
}

// SpotController runs the SPOT nodes' life: start on demand, release when
// idle, finish the record when a pod is gone.
type SpotController struct {
	s    *Server
	cfg  SpotConfig
	kube *spot.Client
	// now is the clock; tests move it.
	now func() time.Time

	mu     sync.Mutex
	want   string // the reason a node was last asked for, "" when none pending
	wantAt time.Time
	logf   func(string, ...any)
}

// NewSpotController wires the controller to a hub. The namespace the client
// settled on (the service account's, when none was configured) is reported
// back into the config so the ledger and the page can say where pods go.
func NewSpotController(s *Server, cfg SpotConfig) (*SpotController, error) {
	k, err := spot.New(cfg.Kube)
	if err != nil {
		return nil, err
	}
	cfg.Namespace = k.Namespace()
	return &SpotController{s: s, cfg: cfg, kube: k, now: time.Now, logf: log.Printf}, nil
}

// Config is the controller's configuration, as the page shows it.
func (c *SpotController) Config() SpotConfig { return c.cfg }

// Run ticks until ctx ends.
func (c *SpotController) Run(ctx context.Context) {
	c.logf("fleet: SPOT nodes on — image %s in %s, at most %d, idle %s, weight %.2f, pods reach the hub at %s",
		c.cfg.Image, c.cfg.Namespace, c.cfg.Max, c.cfg.Idle, c.cfg.Weight, c.cfg.HubURL)
	t := time.NewTicker(c.cfg.Tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.Tick(ctx, c.now())
		}
	}
}

// Want notes that placement found no machine: the next tick starts a node
// if one may be. It answers with what will happen, for the refusal's text.
func (c *SpotController) Want(reason string) string {
	live, pending := c.counts()
	switch {
	case pending > 0:
		return "a SPOT node is already starting"
	case live >= c.cfg.Max:
		return fmt.Sprintf("the SPOT cap (%d) is reached", c.cfg.Max)
	}
	c.mu.Lock()
	c.want, c.wantAt = reason, c.now()
	c.mu.Unlock()
	return "a SPOT node has been requested; retry in a few minutes"
}

// counts is how many nodes the hub tracks that are not on their way out, and
// how many of those have not joined yet.
func (c *SpotController) counts() (live, pending int) {
	rows, err := c.s.Store.SpotNodes(false, 0)
	if err != nil {
		return 0, 0
	}
	for _, n := range rows {
		switch n.State {
		case store.SpotProvisioning:
			live++
			pending++
		case store.SpotOnline:
			live++
		}
	}
	return live, pending
}

// weight is the ephemeral multiplier: the setting, else the configuration.
func (c *SpotController) weight(settings map[string]string) float64 {
	if v, ok := settings[SpotWeightKey]; ok && v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 && f <= 2 {
			return f
		}
	}
	return c.cfg.Weight
}

// spotWeight is what placement multiplies an ephemeral node's score by:
// the setting, the controller's configuration, or the default.
func (s *Server) spotWeight(settings map[string]string) float64 {
	if s.Spot != nil {
		return s.Spot.weight(settings)
	}
	if v, ok := settings[SpotWeightKey]; ok && v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 && f <= 2 {
			return f
		}
	}
	return DefaultSpotWeight
}

// Start asks the cluster for one node now: a join code good for the boot
// window, a pod carrying it, a ledger row.
func (c *SpotController) Start(ctx context.Context, reason string, now time.Time) (store.SpotNode, error) {
	live, _ := c.counts()
	if live >= c.cfg.Max {
		return store.SpotNode{}, fault("AT_CAPACITY", fmt.Sprintf("%d SPOT node(s) already — the cap is %d", live, c.cfg.Max))
	}
	code, err := MintJoinCode()
	if err != nil {
		return store.SpotNode{}, err
	}
	id := "sp" + strconv.FormatInt(now.UnixNano(), 36)
	n := store.SpotNode{ID: id, PodName: "ccquota-spot-" + id, Namespace: c.cfg.Namespace, CodeHash: HashToken(code),
		State: store.SpotProvisioning, Reason: reason, CreatedAt: now.UTC()}
	if err := c.s.Store.CreateJoinCodeKind(n.CodeHash, n.PodName, store.NodeKindEphemeral, now, c.cfg.Boot); err != nil {
		return store.SpotNode{}, err
	}
	pod := spot.BuildPod(spot.PodInput{
		Name: n.PodName, Image: c.cfg.Image,
		Labels: map[string]string{"app": "ccquota-spot-node", "ccquota.io/spot": id},
		Env: map[string]string{"CCQUOTA_HUB_URL": c.cfg.HubURL, "FLEET_JOIN_CODE": code,
			"FLEET_NODE_KIND": store.NodeKindEphemeral, "FLEET_SPOT_ID": id},
		NodeSelector: c.cfg.NodeSelector, Tolerations: c.cfg.Tolerations, GraceSeconds: c.cfg.Grace,
		CPU: c.cfg.CPU, Memory: c.cfg.Memory, ServiceAccount: c.cfg.ServiceAccount, PullSecret: c.cfg.PullSecret,
		Overlay: c.cfg.Overlay,
	})
	if _, err := c.kube.CreatePod(ctx, pod); err != nil {
		c.audit("spot_start", id, "FAILED "+err.Error(), now)
		return store.SpotNode{}, fault("UNAVAILABLE", "the cluster refused the pod: "+err.Error())
	}
	if err := c.s.Store.CreateSpotNode(n); err != nil {
		// The pod exists and the ledger does not know it: take it back
		// rather than leak a machine nobody tracks.
		_, _ = c.kube.DeletePod(ctx, n.PodName, 0)
		return store.SpotNode{}, err
	}
	c.audit("spot_start", id, "STARTED "+n.PodName+" — "+reason, now)
	c.logf("fleet: SPOT node %s started (%s): %s", id, n.PodName, reason)
	return n, nil
}

// Release sends the pod delete: the node goes once the pod is gone.
func (c *SpotController) Release(ctx context.Context, id, reason string, now time.Time) error {
	n, err := c.s.Store.SpotNodeByID(id)
	if errors.Is(err, sql.ErrNoRows) {
		return fault("NOT_FOUND", "no SPOT node "+id)
	}
	if err != nil {
		return err
	}
	if !n.Live() {
		return fault("INVALID_STATE", id+" is already released")
	}
	if n.State == store.SpotReclaiming {
		// Already on its way out, with its own grace; a second delete would
		// only shorten the time it has to move sessions off.
		return nil
	}
	if _, err := c.kube.DeletePod(ctx, n.PodName, c.cfg.Grace); err != nil {
		c.audit("spot_release", id, "FAILED "+err.Error(), now)
		return fault("UNAVAILABLE", "the cluster refused the delete: "+err.Error())
	}
	if _, err := c.s.Store.SetSpotNodeState(id, store.SpotReleasing, reason, now); err != nil {
		return err
	}
	c.audit("spot_release", id, "RELEASING — "+reason, now)
	c.logf("fleet: SPOT node %s releasing: %s", id, reason)
	return nil
}

// Reclaim is the node's own word that the cloud is taking its machine: from
// now on placement avoids it and its idle sessions move off. The pod's end
// finishes the record, as for any other.
func (c *SpotController) Reclaim(endpointID string, now time.Time) (store.SpotNode, error) {
	n, err := c.s.Store.SpotNodeByEndpoint(endpointID)
	if errors.Is(err, sql.ErrNoRows) {
		return store.SpotNode{}, fault("NOT_FOUND", "this endpoint is not a SPOT node the hub started")
	}
	if err != nil {
		return store.SpotNode{}, err
	}
	if n.State == store.SpotReleasing {
		// The hub asked for this exit itself (idle, boot timeout, the
		// button): the SIGTERM the agent saw is that delete, not the cloud.
		// Its own reason stands; the agent's evacuation finds nothing to
		// move.
		return n, nil
	}
	if n.State != store.SpotReclaiming {
		if _, err := c.s.Store.SetSpotNodeState(n.ID, store.SpotReclaiming, "SPOT reclaim signalled by the node", now); err != nil {
			return n, err
		}
		n.State = store.SpotReclaiming
		c.audit("spot_reclaim", n.ID, "RECLAIMING — the node reported the cloud is taking it back", now)
		c.logf("fleet: SPOT node %s is being reclaimed; its idle sessions move off within %ds", n.ID, c.cfg.Grace)
	}
	return n, nil
}

// Beat applies one heartbeat from an endpoint that may be a SPOT node: the
// first one makes a provisioning node online; any that lists sessions
// restarts the idle clock.
func (c *SpotController) Beat(endpointID string, sessions *int, now time.Time) {
	n, err := c.s.Store.SpotNodeByEndpoint(endpointID)
	if err != nil {
		return
	}
	if n.State == store.SpotProvisioning {
		if err := c.s.Store.SpotNodeOnline(n.ID, now); err == nil {
			c.audit("spot_online", n.ID, "ONLINE "+n.PodName, now)
			c.logf("fleet: SPOT node %s is online (%s)", n.ID, endpointID)
		}
	}
	switch {
	case sessions == nil:
		// A fleet it could not read may be running anything
		// (claude-fleet#1465): unknown restarts the idle clock, never lets
		// it run out.
		_ = c.s.Store.SpotNodeBusy(endpointID, 0, now)
	case *sessions > 0:
		_ = c.s.Store.SpotNodeBusy(endpointID, *sessions, now)
	}
}

// Tick reconciles every tracked node with the cluster and the roster, and
// starts one when placement asked for it. It returns what it did, one line
// each, for the log and the tests.
func (c *SpotController) Tick(ctx context.Context, now time.Time) []string {
	var did []string
	rows, err := c.s.Store.SpotNodes(false, 0)
	if err != nil {
		return []string{"ledger: " + err.Error()}
	}
	roster := map[string]store.Node{}
	if nodes, err := c.s.Store.Nodes(); err == nil {
		for _, n := range nodes {
			roster[n.EndpointID] = n
		}
	}
	for _, n := range rows {
		pod, found, err := c.kube.GetPod(ctx, n.PodName)
		if err != nil {
			// The API being away says nothing about the pod: judge nothing
			// on it this tick.
			did = append(did, n.ID+": cluster unreachable: "+err.Error())
			continue
		}
		if !found || pod.Gone() {
			did = append(did, c.finish(n, pod, found, roster, now))
			continue
		}
		rn, onRoster := roster[n.EndpointID]
		online := onRoster && NodeStatus(rn.LastHeartbeat, rn.HeartbeatMS, now) == "online"
		switch n.State {
		case store.SpotProvisioning:
			if n.EndpointID != "" && online {
				// Joined and reporting: the beat path normally does this;
				// here for a hub restarted between the two.
				_ = c.s.Store.SpotNodeOnline(n.ID, now)
				did = append(did, n.ID+": online")
			} else if now.Sub(n.CreatedAt) > c.cfg.Boot {
				why := "boot timeout: no agent within " + c.cfg.Boot.String()
				if pod.Reason != "" {
					why += " (" + pod.Reason + ")"
				}
				if err := c.Release(ctx, n.ID, why, now); err != nil {
					did = append(did, n.ID+": "+err.Error())
				} else {
					did = append(did, n.ID+": "+why)
				}
			}
		case store.SpotOnline:
			switch {
			case !online && onRoster && rn.LastHeartbeat != nil && now.Sub(*rn.LastHeartbeat) > c.cfg.Boot:
				why := "lost: no heartbeat for " + now.Sub(*rn.LastHeartbeat).Round(time.Second).String()
				if err := c.Release(ctx, n.ID, why, now); err != nil {
					did = append(did, n.ID+": "+err.Error())
				} else {
					did = append(did, n.ID+": "+why)
				}
			case n.LastBusyAt != nil && now.Sub(*n.LastBusyAt) >= c.cfg.Idle && !c.busy(rn):
				why := "idle for " + roundAge(now.Sub(*n.LastBusyAt))
				if err := c.Release(ctx, n.ID, why, now); err != nil {
					did = append(did, n.ID+": "+err.Error())
				} else {
					did = append(did, n.ID+": "+why)
				}
			}
		case store.SpotReclaiming:
			// The kubelet ends the pod; if the cloud was slower than its
			// own warning and the pod is still here past the grace, help.
			if n.LastBusyAt != nil && !pod.Deleting && now.Sub(c.stateSince(n, now)) > time.Duration(c.cfg.Grace)*time.Second+time.Minute {
				if _, err := c.kube.DeletePod(ctx, n.PodName, 30); err == nil {
					did = append(did, n.ID+": reclaiming past the grace — pod delete sent")
				}
			}
		}
	}

	// Demand: placement asked and nobody is starting.
	c.mu.Lock()
	want := c.want
	c.want = ""
	c.mu.Unlock()
	if want != "" {
		if _, err := c.Start(ctx, want, now); err != nil {
			did = append(did, "start: "+err.Error())
		} else {
			did = append(did, "start: "+want)
		}
	}
	for _, d := range did {
		c.logf("fleet: SPOT %s", d)
	}
	return did
}

// roundAge prints a duration to the minute, or the second under one.
func roundAge(d time.Duration) string {
	if d < time.Minute {
		return d.Round(time.Second).String()
	}
	return d.Round(time.Minute).String()
}

// busy reads a roster row's newest heartbeat for sessions. A count it could
// not take is busy (claude-fleet#1465): an unread fleet is never idle.
func (c *SpotController) busy(n store.Node) bool {
	var hb control.Heartbeat
	if json.Unmarshal([]byte(n.StatusJSON), &hb) != nil {
		return false
	}
	return hb.SessionsCount() == nil || hb.Sessions > 0
}

// stateSince is when the node entered its current state, as far as the
// ledger knows (reclaim and release are not timestamped separately: the
// newest of the timestamps it has stands in).
func (c *SpotController) stateSince(n store.SpotNode, now time.Time) time.Time {
	t := n.CreatedAt
	for _, x := range []*time.Time{n.JoinedAt, n.LastBusyAt} {
		if x != nil && x.After(t) {
			t = *x
		}
	}
	return t
}

// finish closes a node whose pod is gone: leases released at once, the roster
// row dropped, the endpoint retired (its token stops working), the record
// completed with what was lost.
func (c *SpotController) finish(n store.SpotNode, pod spot.Pod, found bool, roster map[string]store.Node, now time.Time) string {
	why := n.Reason
	switch {
	case n.State == store.SpotReclaiming:
		why = "reclaimed by the cloud"
	case n.State == store.SpotReleasing:
		// The reason the release gave.
	case found && pod.Phase == "Failed":
		why = "pod failed"
		if pod.Reason != "" {
			why += ": " + pod.Reason
		}
	case found:
		why = "pod exited"
	default:
		why = "pod gone (deleted outside the hub, or the SPOT machine was taken back)"
	}
	lost := 0
	if rn, ok := roster[n.EndpointID]; ok && n.State != store.SpotReleasing {
		var hb control.Heartbeat
		if json.Unmarshal([]byte(rn.StatusJSON), &hb) == nil {
			lost = hb.Sessions
		}
	}
	leases := 0
	if n.EndpointID != "" {
		if held, err := c.s.Store.ReleaseLeasesOfEndpoint(n.EndpointID); err == nil {
			leases = len(held)
			for _, l := range held {
				c.audit("spot_lease_release", n.ID, fmt.Sprintf("%s#%d (%s) — node %s", l.Repo, l.Issue, l.WorkerID, why), now)
			}
		}
		if err := c.s.Store.DeleteNode(n.EndpointID); err != nil {
			c.logf("fleet: SPOT %s: drop roster row: %v", n.ID, err)
		}
		if _, err := c.s.Store.RetireEndpointAs(n.EndpointID, "spot", "SPOT node released", time.Now()); err != nil {
			c.logf("fleet: SPOT %s: retire endpoint: %v", n.ID, err)
		}
		c.s.nodes.dropAll(n.EndpointID)
	}
	if err := c.s.Store.SpotNodeReleased(n.ID, why, leases, lost, now); err != nil {
		return n.ID + ": record release: " + err.Error()
	}
	out := fmt.Sprintf("RELEASED %s — %s", n.PodName, why)
	if lost > 0 {
		out += fmt.Sprintf("; %d session(s) were still on it (意外下线)", lost)
	}
	if leases > 0 {
		out += fmt.Sprintf("; %d lease(s) released", leases)
	}
	c.audit("spot_released", n.ID, out, now)
	return n.ID + ": " + out
}

func (c *SpotController) audit(action, id, outcome string, at time.Time) {
	if err := c.s.Store.FleetAudit("hub:spot", action, "spot:"+id, outcome, "", at); err != nil {
		c.logf("fleet audit: %v", err)
	}
}

// --- views ----------------------------------------------------------------

// SpotNodeView is one ledger row as the roster shows it.
type SpotNodeView struct {
	store.SpotNode
	// Hostname is the roster's name for it once joined.
	Hostname string `json:"hostname,omitempty"`
	// IdleSec is how long it has had no session (live nodes only).
	IdleSec float64 `json:"idle_sec,omitempty"`
	// Age is how long it has existed, or lived.
	AgeSec float64 `json:"age_sec"`
}

// SpotSummary is the /v1/nodes `spot` block: the configuration that matters
// to a reader, the nodes under way, and the newest finished records.
type SpotSummary struct {
	Enabled     bool           `json:"enabled"`
	Max         int            `json:"max"`
	IdleMinutes int            `json:"idle_minutes"`
	Weight      float64        `json:"weight"`
	Image       string         `json:"image,omitempty"`
	Namespace   string         `json:"namespace,omitempty"`
	Nodes       []SpotNodeView `json:"nodes"`
	History     []SpotNodeView `json:"history"`
}

// spotSummary builds the block; nil when SPOT is off and nothing was ever
// started.
func (s *Server) spotSummary(now time.Time, roster []NodeView) *SpotSummary {
	rows, err := s.Store.SpotNodes(true, 8)
	if err != nil {
		return nil
	}
	if s.Spot == nil && len(rows) == 0 {
		return nil
	}
	settings, _ := s.Store.FleetSettings()
	sum := &SpotSummary{Nodes: []SpotNodeView{}, History: []SpotNodeView{}, Weight: s.spotWeight(settings)}
	if s.Spot != nil {
		cfg := s.Spot.Config()
		sum.Enabled, sum.Max, sum.IdleMinutes = true, cfg.Max, int(cfg.Idle/time.Minute)
		sum.Image, sum.Namespace = cfg.Image, cfg.Namespace
	}
	names := map[string]string{}
	for _, v := range roster {
		names[v.EndpointID] = v.Hostname
	}
	for _, n := range rows {
		v := SpotNodeView{SpotNode: n, Hostname: names[n.EndpointID]}
		if n.Live() {
			v.AgeSec = now.Sub(n.CreatedAt).Seconds()
			if n.LastBusyAt != nil {
				v.IdleSec = now.Sub(*n.LastBusyAt).Seconds()
			}
			sum.Nodes = append(sum.Nodes, v)
		} else {
			if n.ReleasedAt != nil {
				v.AgeSec = n.ReleasedAt.Sub(n.CreatedAt).Seconds()
			}
			sum.History = append(sum.History, v)
		}
	}
	sort.Slice(sum.History, func(i, j int) bool {
		a, b := sum.History[i].ReleasedAt, sum.History[j].ReleasedAt
		if a == nil || b == nil {
			return a != nil
		}
		return a.After(*b)
	})
	return sum
}

// --- routes ---------------------------------------------------------------

// handleFleetSpot serves /v1/fleet/spot — the operator's.
//
//	GET                       → the SpotSummary
//	POST {"action":"start"}   → start a node now (the button; the record's 起节点)
//	POST {"action":"release","id":…} → release one now
func (s *Server) handleFleetSpot(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	switch r.Method {
	case http.MethodGet:
		snap, err := s.Nodes(now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		sum := s.spotSummary(now, snap.Nodes)
		if sum == nil {
			sum = &SpotSummary{Nodes: []SpotNodeView{}, History: []SpotNodeView{}, Weight: DefaultSpotWeight}
		}
		writeJSON(w, http.StatusOK, sum)
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		if s.Spot == nil {
			httpError(w, http.StatusNotImplemented, "SPOT nodes are off on this hub (CCQUOTA_FLEET_SPOT_IMAGE)")
			return
		}
		var req struct {
			Action string `json:"action"`
			ID     string `json:"id"`
			Reason string `json:"reason"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			httpError(w, http.StatusBadRequest, "the body must be one JSON object")
			return
		}
		switch req.Action {
		case "start":
			why := "started by the operator"
			if req.Reason != "" {
				why += ": " + req.Reason
			}
			n, err := s.Spot.Start(r.Context(), why, now)
			if err != nil {
				writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err)})
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"node": n})
		case "release":
			if req.ID == "" {
				httpError(w, http.StatusBadRequest, "release needs an id")
				return
			}
			why := "released by the operator"
			if req.Reason != "" {
				why += ": " + req.Reason
			}
			if err := s.Spot.Release(r.Context(), req.ID, why, now); err != nil {
				writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err)})
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"released": req.ID})
		default:
			httpError(w, http.StatusBadRequest, "action must be start or release")
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// handleNodeReclaim is POST /v1/node/reclaim: a SPOT node's agent, on the
// kubelet's SIGTERM, saying the machine is going. Authenticated by the node's
// own token; answers how long it has.
func (s *Server) handleNodeReclaim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if s.Spot == nil {
		httpError(w, http.StatusNotImplemented, "SPOT nodes are off on this hub")
		return
	}
	n, err := s.Spot.Reclaim(ep.ID, time.Now())
	if err != nil {
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err)})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": n.ID, "state": n.State, "grace_seconds": s.Spot.cfg.Grace})
}
