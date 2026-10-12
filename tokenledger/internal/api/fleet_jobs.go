package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Throwaway Jobs (claude-fleet#3552, EPIC #3500 C7).
//
// A session in a person's pod hands a heavy or untrusted run to a Job that is
// deleted when it is done (`fleet job run`, bin/fleet-job.sh). It asks with its
// own node credential, so the pod is the caller's own — never a pod it names:
//
//	POST /v1/node/jobs        {repo, ref, kind, cmd} → {job, cluster, kind, line}
//	GET  /v1/node/jobs/<job>  ?offset=N → {job, state, reason?, log, offset}
//
// The create is a signed create-job ticket (control.ClusterTicket), carried
// down the cluster's ops link to its provisioner like every other cluster op:
// the Job is render.py's template for that kind, no token, no home, no key,
// not root, gone ttlSecondsAfterFinished after it ends. The read is the ops
// link's TypeClusterJob: fleet-ops (read-only) answers only for a Job whose
// fleet/owner is the caller's pod, with its state and the next chunk of its
// log — the command's output, then its outputs as one marked block
// (bin/fleet-job-runner.sh). Every create is audited job.create.
//
// Off — no fleet, no account key, a caller that is no live pod of a cluster,
// or no ops link on this replica — nothing is signed or sent.
const NodeJobsPath = "/v1/node/jobs"

// jobCmdMax is the ticket grammar's longest command line (bin/fleet_cluster_ticket.py).
const jobCmdMax = 2000

// clusterJobWait bounds one read's round trip through the ops link.
var clusterJobWait = 45 * time.Second

var (
	jobKinds   = map[string]bool{"build": true, "test": true, "browser": true, "load": true, "untrusted": true}
	jobRepoRE  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$`)
	jobRefRE   = regexp.MustCompile(`^[0-9a-f]{40}$`)
	jobCmdRE   = regexp.MustCompile(`^[^\x00-\x1f\x7f]+$`) // ≤ jobCmdMax runes besides (RE2 repeats stop at 1000)
	jobIDRE    = regexp.MustCompile(`^job-[0-9a-f]{12}$`)
	errNotAPod = errors.New("a Job is asked for from a person's own pod in a cluster; this node is none")
)

// jobPod is the caller's own pod: the live pod row its machine is.
func (s *Server) jobPod(ep *store.Endpoint) (*store.ClusterPod, error) {
	if !s.Fleet || s.Store == nil || s.accountKey == nil || !isUserPodName(ep.Hostname) {
		return nil, errNotAPod
	}
	p, err := s.Store.ClusterPodOf(firstLabel(strings.ToLower(ep.Hostname)))
	if err != nil || p.State != store.PodLive {
		return nil, errNotAPod
	}
	return p, nil
}

type jobCreate struct {
	Repo string `json:"repo"`
	Ref  string `json:"ref"`
	Kind string `json:"kind"`
	Cmd  string `json:"cmd"`
}

func (in jobCreate) check() string {
	switch {
	case !jobRepoRE.MatchString(in.Repo):
		return "repo must be owner/name"
	case !jobRefRE.MatchString(in.Ref):
		return "ref must be a 40-hex commit"
	case !jobKinds[in.Kind]:
		return "kind must be build, test, browser, load or untrusted"
	case !jobCmdRE.MatchString(in.Cmd) || utf8.RuneCountInString(in.Cmd) > jobCmdMax:
		return "cmd must be one printable line of 1-2000 characters"
	}
	return ""
}

func (s *Server) handleNodeJobs(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	p, err := s.jobPod(ep)
	if err != nil {
		httpError(w, http.StatusForbidden, err.Error())
		return
	}
	id := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, NodeJobsPath), "/")
	switch {
	case id == "" && r.Method == http.MethodPost:
		s.createJob(w, r, ep, p)
	case id != "" && r.Method == http.MethodGet:
		s.readJob(w, r, p, id)
	default:
		httpError(w, http.StatusMethodNotAllowed, "POST "+NodeJobsPath+" or GET "+NodeJobsPath+"/<job>")
	}
}

func (s *Server) createJob(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, p *store.ClusterPod) {
	var in jobCreate
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object")
		return
	}
	if why := in.check(); why != "" {
		httpError(w, http.StatusBadRequest, why)
		return
	}
	var nb [16]byte
	if _, err := rand.Read(nb[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	nonce := hex.EncodeToString(nb[:])
	job := "job-" + nonce[:12]
	res, err := s.clusterOp(r.Context(), p.Cluster, control.ClusterTicket{Op: control.ClusterCreateJob,
		Pod: p.Pod, Repo: in.Repo, Ref: in.Ref, Kind: in.Kind, Cmd: in.Cmd, Nonce: nonce})
	outcome, status := "ok", http.StatusOK
	switch {
	case errors.Is(err, errNoOpsLink):
		outcome, status = "failed", http.StatusServiceUnavailable
	case err != nil || res.RC == 1:
		outcome, status = "failed", http.StatusBadGateway
	case res.RC != 0:
		outcome, status = "refused", http.StatusForbidden
	}
	_ = s.Store.HubAudit(ep.Hostname+"/"+ep.OSUser, "job.create", job, outcome,
		fmt.Sprintf("%s on %s: %s %s@%s: %s", p.Pod, p.Cluster, in.Kind, in.Repo, in.Ref[:12], clusterOpWhy(res, err)), time.Now())
	if status != http.StatusOK {
		httpError(w, status, clusterOpWhy(res, err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"job": job, "cluster": p.Cluster, "kind": in.Kind, "line": res.Line})
}

func (s *Server) readJob(w http.ResponseWriter, r *http.Request, p *store.ClusterPod, id string) {
	if !jobIDRE.MatchString(id) {
		httpError(w, http.StatusBadRequest, "a job is job-<12 hex>")
		return
	}
	var off int64
	if v := r.URL.Query().Get("offset"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			httpError(w, http.StatusBadRequest, "offset is a byte count")
			return
		}
		off = n
	}
	res, err := s.clusterJob(r.Context(), p.Cluster, control.ClusterJob{Job: id, Owner: p.Pod, Offset: off})
	switch {
	case errors.Is(err, errNoOpsLink):
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	case errors.Is(err, errJobNotYours):
		httpError(w, http.StatusNotFound, "no such job for this pod")
		return
	case err != nil:
		httpError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"job": id, "state": res.State, "reason": res.Reason,
		"log": res.Log, "offset": res.Offset})
}

// errJobNotYours: fleet-ops refused — the Job is not the asking pod's.
var errJobNotYours = errors.New("not this pod's job")

// clusterJob reads one Job back through cluster's ops link.
func (s *Server) clusterJob(ctx context.Context, cluster string, req control.ClusterJob) (control.ClusterJobResult, error) {
	var res control.ClusterJobResult
	_, c := s.nodes.opsFor(cluster)
	if c == nil {
		return res, errNoOpsLink
	}
	msg, err := control.New(control.TypeClusterJob, req)
	if err != nil {
		return res, err
	}
	ch := c.pending.add(msg.OpID)
	defer c.pending.remove(msg.OpID)
	ctx, cancel := context.WithTimeout(ctx, clusterJobWait)
	defer cancel()
	if err := c.wire.write(ctx, msg); err != nil {
		return res, fmt.Errorf("write to %s's ops link: %w", cluster, err)
	}
	select {
	case <-ctx.Done():
		return res, fmt.Errorf("%s's ops link did not answer for %s within %s", cluster, req.Job, clusterJobWait)
	case reply := <-ch:
		if reply.Type == control.TypeError {
			if reply.Error != nil && reply.Error.Code == control.CodeNoSuchJob {
				return res, errJobNotYours
			}
			why := "refused"
			if reply.Error != nil {
				why = reply.Error.Code + ": " + reply.Error.Message
			}
			return res, fmt.Errorf("%s's ops link refused the read: %s", cluster, why)
		}
		if err := json.Unmarshal(reply.Payload, &res); err != nil {
			return res, fmt.Errorf("%s's ops link answered with a malformed result", cluster)
		}
		if res.Error != "" {
			return res, fmt.Errorf("%s's API server: %s", cluster, res.Error)
		}
		return res, nil
	}
}
