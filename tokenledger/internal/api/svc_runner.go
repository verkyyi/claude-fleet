package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A service run's throwaway environment (claude-fleet#4005, the SPACE EPIC C3).
//
// ClusterSvcRunner is the SvcRunner of a hub with a cluster: each run attempt
// is ONE Kubernetes Job in fleet-workers, made by the cluster's provisioner
// from a signed create-svc-run ticket (render.py svc_run_resources — no token,
// no home, no disk, not root, a closed egress guard, deleted 300 s after it
// ends). The hub hands the Job one thing: a one-time key (fsj_…), carried in the
// ticket into the Job's own Secret and kept here only as its sha256. With it the
// Job reads, ONCE, its spec and hands in, ONCE, its result:
//
//	GET  /v1/node/svc-runs/R<n>/spec?attempt=k   the template's agent.md (by the
//	                                            run's digest), the inputs, and a
//	                                            model pass bound to this run,
//	                                            good until its deadline
//	POST /v1/node/svc-runs/R<n>/result           {attempt, exit, report, meta, usage, detail}
//
// exit is the runner contract's: 0 succeeded (the outputs checked again,
// SvcRunFinish), 20 output_invalid, 30 run_timeout, anything else infra_error —
// which a first attempt is retried for (claude-fleet#4007): a new attempt, a new
// Job, a new key, the time left of the deadline. detail (the runner's stderr
// tail) stays in the hub's log.
// The result ends the key and revokes the pass; a cancel or the sweep's
// run_timeout do the same and delete the Job. Nothing the Job holds opens
// anything of anyone else's: the key opens its own run's two routes, the pass
// its own run's model calls.
//
// Off (no CCQUOTA_FLEET_SVC_CLUSTER) the hub has no runner: runs queue and
// expire, byte for byte as before.
const NodeSvcRunsPath = "/v1/node/svc-runs"

const (
	svcKeyPrefix = "fsj_"
	// svcResultMax bounds the result body: a report ≤ 1 MB plus its meta.
	svcResultMax = 2 << 20
	// svcPassGrace is how long past the deadline the pass still holds, so the
	// last model call of a run that ends near it is not cut mid-answer.
	svcPassGrace = 2 * time.Minute
)

// The runner contract's exit codes.
const (
	SvcExitOK            = 0
	SvcExitOutputInvalid = 20
	SvcExitTimeout       = 30
)

var (
	svcLabelRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`)
	svcKeyRE   = regexp.MustCompile(`^fsj_[a-z2-7]{52}$`)
)

// ClusterSvcRunner starts each run attempt as a Job in one cluster.
type ClusterSvcRunner struct {
	s       *Server
	Cluster string
}

// NewClusterSvcRunner is the runner for cluster (its ops link's name).
func NewClusterSvcRunner(s *Server, cluster string) *ClusterSvcRunner {
	return &ClusterSvcRunner{s: s, Cluster: cluster}
}

// svcLabel is principal's name as a Kubernetes label (svc:livepage → livepage).
func svcLabel(principal string) (string, error) {
	n := strings.TrimPrefix(principal, "svc:")
	if n == principal || !svcLabelRE.MatchString(n) {
		return "", fmt.Errorf("principal %q is not svc:<dns label>", principal)
	}
	return n, nil
}

func svcMintKey() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return svcKeyPrefix + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b[:])), nil
}

func svcKeySHA(key string) string {
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// Start asks the cluster for the attempt's Job. A digest the principal never
// registered ends the run template_invalid, and no Job is asked for.
func (c *ClusterSvcRunner) Start(ctx context.Context, run store.SvcRun) error {
	s := c.s
	if _, err := s.Store.SvcTemplateOf(run.Principal, run.Digest); errors.Is(err, sql.ErrNoRows) {
		_, ferr := s.SvcRunFinish(run.ID, store.SvcRunFailed, SvcErrTemplateInvalid, nil, nil)
		return ferr
	} else if err != nil {
		return err
	}
	label, err := svcLabel(run.Principal)
	if err != nil {
		return err
	}
	if run.Attempt < 1 || run.Attempt > 9 {
		return fmt.Errorf("attempt %d is not 1-9", run.Attempt)
	}
	key, err := svcMintKey()
	if err != nil {
		return err
	}
	if err := s.Store.AddSvcRunJob(store.SvcRunJob{RunID: run.ID, Attempt: run.Attempt, KeySHA: svcKeySHA(key),
		Cluster: c.Cluster}, time.Now()); err != nil {
		return err
	}
	res, err := s.clusterOp(ctx, c.Cluster, control.ClusterTicket{Op: control.ClusterCreateSvcRun, Run: run.Ref(),
		Attempt: run.Attempt, Svc: label, Deadline: svcJobDeadline(run, time.Now()), Token: key})
	if err == nil && res.RC != 0 {
		err = fmt.Errorf("the provisioner said rc %d: %s", res.RC, res.Line)
	}
	if err != nil {
		_, _ = s.Store.EndSvcRunJob(run.ID, run.Attempt, time.Now())
		return err
	}
	s.svcAudit(run.Principal, "svc.run.job", run.Ref(), "ok", "attempt "+strconv.Itoa(run.Attempt)+" on "+c.Cluster, time.Now())
	return nil
}

// svcJobDeadline is the attempt's Job's activeDeadlineSeconds: the run's
// deadline_s, or for a retry (claude-fleet#4007) what is left of the deadline
// its first start fixed — never under the ticket's 60.
func svcJobDeadline(run store.SvcRun, now time.Time) int {
	d := run.DeadlineS
	if run.Attempt > 1 && run.DeadlineAt != nil {
		if left := int(run.DeadlineAt.Sub(now).Seconds()); left < d {
			d = left
		}
	}
	if d < 60 {
		d = 60
	}
	return d
}

// Cancel ends the attempt's key and pass and deletes its Job.
func (c *ClusterSvcRunner) Cancel(ctx context.Context, run store.SvcRun) error {
	c.s.svcEnvEnd(run.ID, run.Attempt, "run "+run.State, time.Now())
	res, err := c.s.clusterOp(ctx, c.Cluster, control.ClusterTicket{Op: control.ClusterDeleteSvcRun, Run: run.Ref(),
		Attempt: run.Attempt})
	if err == nil && res.RC != 0 {
		err = fmt.Errorf("the provisioner said rc %d: %s", res.RC, res.Line)
	}
	return err
}

// svcEnvEnd closes an attempt's environment: its key opens nothing more, its
// pass is revoked.
func (s *Server) svcEnvEnd(runID int64, attempt int, why string, now time.Time) {
	j, err := s.Store.SvcRunJobOf(runID, attempt)
	if err != nil {
		return
	}
	if _, err := s.Store.EndSvcRunJob(runID, attempt, now); err != nil {
		log.Printf("svc run %s: %v", store.SvcRunRef(runID), err)
	}
	if j.PassID == "" {
		return
	}
	ok, err := s.Store.RevokeSessionCred(j.PassID, "svc-run", why, now)
	if err != nil {
		log.Printf("svc run %s: revoke pass: %v", store.SvcRunRef(runID), err)
	}
	s.sessCred.drop(j.PassID)
	if row, err := s.Store.SessionCredByID(j.PassID); ok && err == nil {
		s.revRecord([]store.Revocation{{JTI: "fcp:" + row.ID, Machine: revMachine(row.Machine), Principal: row.PrincipalID,
			Exp: row.ExpiresAt.Unix(), Src: "session:" + row.ID, Reason: why}}, now)
	}
}

// handleNodeSvcRuns is the Job's road: its key, its run, once each.
func (s *Server) handleNodeSvcRuns(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	rest := strings.TrimPrefix(r.URL.Path, NodeSvcRunsPath+"/")
	ref, what, _ := strings.Cut(rest, "/")
	id := store.ParseSvcRunRef(ref)
	if id == 0 || (what != "spec" && what != "result") {
		httpError(w, http.StatusNotFound, "GET "+NodeSvcRunsPath+"/R<n>/spec or POST …/result")
		return
	}
	if (what == "spec") != (r.Method == http.MethodGet) || (what == "result") != (r.Method == http.MethodPost) {
		httpError(w, http.StatusMethodNotAllowed, "GET …/spec, POST …/result")
		return
	}
	key := bearer(r)
	if !svcKeyRE.MatchString(key) || s.Store == nil {
		httpError(w, http.StatusUnauthorized, "a run's own key is required")
		return
	}
	j, err := s.Store.SvcRunJobByKey(svcKeySHA(key))
	if errors.Is(err, sql.ErrNoRows) || (err == nil && j.RunID != id) {
		httpError(w, http.StatusUnauthorized, "a run's own key is required")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if j.Ended != nil {
		httpError(w, http.StatusGone, "this run's environment has ended")
		return
	}
	run, err := s.Store.SvcRun(id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if run.State != store.SvcRunRunning || run.Attempt != j.Attempt {
		s.svcEnvEnd(id, j.Attempt, "run "+run.State, time.Now())
		httpError(w, http.StatusConflict, "the run is "+run.State+" (attempt "+strconv.Itoa(run.Attempt)+")")
		return
	}
	if what == "spec" {
		s.svcRunSpec(w, r, run, j)
		return
	}
	s.svcRunResult(w, r, run, j)
}

// svcRunSpec hands the Job its template, its inputs and its model pass — once.
func (s *Server) svcRunSpec(w http.ResponseWriter, r *http.Request, run store.SvcRun, j store.SvcRunJob) {
	now := time.Now()
	if a := r.URL.Query().Get("attempt"); a != "" && a != strconv.Itoa(j.Attempt) {
		httpError(w, http.StatusConflict, "this key is attempt "+strconv.Itoa(j.Attempt)+"'s")
		return
	}
	t, err := s.Store.SvcTemplateOf(run.Principal, run.Digest)
	if err != nil {
		httpError(w, http.StatusConflict, "the run's template is not registered")
		return
	}
	if len(s.SessionCredKey) == 0 {
		sessionCredRefuse(w, http.StatusServiceUnavailable, SessionCredOff, "session passes are off on this hub")
		return
	}
	var rnd [16]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	deadline := now.Add(time.Duration(run.DeadlineS) * time.Second)
	if run.DeadlineAt != nil {
		deadline = *run.DeadlineAt
	} else if run.StartedAt != nil {
		deadline = run.StartedAt.Add(time.Duration(run.DeadlineS) * time.Second)
	}
	exp := deadline.Add(svcPassGrace)
	if exp.After(now.Add(SessionCredTTL)) {
		exp = now.Add(SessionCredTTL)
	}
	iat := now.Truncate(time.Second)
	v := 1
	if len(s.RelaySignKey) == ed25519.PrivateKeySize {
		v = 2
	}
	worker := "svc/" + run.Ref() + "/a" + strconv.Itoa(j.Attempt)
	claims := sessionCredClaims{V: v, ID: "sc_" + hex.EncodeToString(rnd[:]), Principal: run.Principal, WorkerID: worker,
		Machine: "svc-run", Providers: []string{credvault.Claude}, Iat: iat.Unix(), Exp: exp.Unix(),
		Svc: svcName(run.Principal), Tenant: run.Tenant, Run: run.Ref()}
	ok, err := s.Store.FetchSvcRunJob(run.ID, j.Attempt, claims.ID, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		httpError(w, http.StatusConflict, "this run's spec was read already")
		return
	}
	if err := s.Store.AddSessionCred(store.SessionCred{ID: claims.ID, PrincipalID: run.Principal, WorkerID: worker,
		WorkerKey: worker, Machine: "svc-run", Providers: claims.Providers, IssuedAt: iat,
		ExpiresAt: time.Unix(claims.Exp, 0)}); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	inputs := json.RawMessage(run.InputsJSON)
	if !json.Valid(inputs) {
		inputs = json.RawMessage("{}")
	}
	s.svcAudit(run.Principal, "svc.run.spec", run.Ref(), "ok", "pass "+claims.ID+" until "+
		time.Unix(claims.Exp, 0).UTC().Format(time.RFC3339), now)
	writeJSON(w, http.StatusOK, map[string]any{"run_id": run.Ref(), "attempt": j.Attempt, "deadline_s": run.DeadlineS,
		"template": t.Name, "template_digest": t.Digest, "agent_md": t.AgentMD, "inputs": inputs,
		"pass": s.signSessionPass(claims)})
}

// svcRunResult takes the Job's one result and ends the run with it.
func (s *Server) svcRunResult(w http.ResponseWriter, r *http.Request, run store.SvcRun, j store.SvcRunJob) {
	var in struct {
		Attempt int             `json:"attempt"`
		Exit    *int            `json:"exit"`
		Report  *string         `json:"report"`
		Meta    json.RawMessage `json:"meta"`
		Usage   json.RawMessage `json:"usage"`
		Detail  string          `json:"detail"`
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, svcResultMax))
	if err != nil || json.Unmarshal(body, &in) != nil || in.Exit == nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object {attempt, exit, report?, meta?, usage?} of at most 2 MB")
		return
	}
	if in.Attempt != j.Attempt {
		httpError(w, http.StatusConflict, "this key is attempt "+strconv.Itoa(j.Attempt)+"'s")
		return
	}
	now := time.Now()
	ok, err := s.Store.EndSvcRunJob(run.ID, j.Attempt, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		httpError(w, http.StatusGone, "this run's environment has ended")
		return
	}
	state, code := store.SvcRunFailed, SvcErrInfra
	var res *SvcRunResult
	switch *in.Exit {
	case SvcExitOK:
		state, code = store.SvcRunSucceeded, ""
		res = &SvcRunResult{Meta: in.Meta}
		if in.Report != nil {
			res.Report = *in.Report
		}
	case SvcExitOutputInvalid:
		code = SvcErrOutputInvalid
	case SvcExitTimeout:
		code = SvcErrRunTimeout
	}
	// the runner's own words on a failure go to the hub's log and audit only
	ended, err := s.SvcRunFinishDetail(run.ID, state, code, in.Detail, res, in.Usage)
	s.svcEnvEnd(run.ID, j.Attempt, "run ended", now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"run_id": ended.Ref(), "state": ended.State, "error_code": ended.ErrorCode})
}
