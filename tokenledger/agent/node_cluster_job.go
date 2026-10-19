package agent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A throwaway Job, read back (claude-fleet#3552, EPIC #3500 C7).
//
// fleet-ops reads; it never writes. Its own account's Role is pods, their logs,
// Jobs and pod metrics — get / list / watch, in fleet-workers. The hub names a
// Job and the user pod it must be for; the agent answers only for a Job
// labelled fleet/role job and fleet/owner that pod, with its state and the next
// chunk of its log. The Job's runner (bin/fleet-job-runner.sh) writes
// everything — the command's output, then its outputs as one marked block — to
// that log, so this is the one channel back.

// The in-cluster defaults (the pod's own account, mounted by Kubernetes).
const (
	kubeAPIDefault   = "https://kubernetes.default.svc"
	kubeSADirDefault = "/var/run/secrets/kubernetes.io/serviceaccount"
)

var (
	jobNameRE  = regexp.MustCompile(`^job-[0-9a-f]{12}$`)
	jobOwnerRE = regexp.MustCompile(`^u-[a-z0-9]{4,20}$`)
)

// kube is one read of the API server as this pod's account.
type kube struct {
	api, ns, token string
	http           *http.Client
}

// kubeReader is the API server as fleet-ops' own account: the token, the CA
// and the namespace from its service-account directory, read per call (the
// token rotates).
func (a *Agent) kubeReader() (*kube, error) {
	dir := a.cfg.FleetKubeSADir
	if dir == "" {
		dir = kubeSADirDefault
	}
	api := strings.TrimRight(a.cfg.FleetKubeAPI, "/")
	if api == "" {
		api = kubeAPIDefault
	}
	tok, err := os.ReadFile(filepath.Join(dir, "token"))
	if err != nil {
		return nil, fmt.Errorf("no service-account token: %w", err)
	}
	ns, err := os.ReadFile(filepath.Join(dir, "namespace"))
	if err != nil {
		return nil, fmt.Errorf("no service-account namespace: %w", err)
	}
	k := &kube{api: api, ns: strings.TrimSpace(string(ns)), token: strings.TrimSpace(string(tok)), http: a.http}
	if ca, err := os.ReadFile(filepath.Join(dir, "ca.crt")); err == nil {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(ca) {
			return nil, fmt.Errorf("the service-account CA does not parse")
		}
		k.http = &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}}
	}
	return k, nil
}

// get reads path; the status and at most limit bytes of the body.
func (k *kube) get(ctx context.Context, path string, limit int64) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, k.api+path, nil)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+k.token)
	resp, err := k.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	return resp.StatusCode, b, err
}

// jobState is a Job object's state and, when it failed, why.
func jobState(raw []byte) (owner, state, reason string, err error) {
	var j struct {
		Metadata struct {
			Labels map[string]string `json:"labels"`
		} `json:"metadata"`
		Status struct {
			Active     int `json:"active"`
			Succeeded  int `json:"succeeded"`
			Failed     int `json:"failed"`
			Conditions []struct {
				Type   string `json:"type"`
				Status string `json:"status"`
				Reason string `json:"reason"`
			} `json:"conditions"`
		} `json:"status"`
	}
	if err := json.Unmarshal(raw, &j); err != nil {
		return "", "", "", err
	}
	if j.Metadata.Labels["fleet/role"] != "job" {
		return "", "", "", fmt.Errorf("not a fleet Job")
	}
	owner = j.Metadata.Labels["fleet/owner"]
	for _, c := range j.Status.Conditions {
		if c.Status != "True" {
			continue
		}
		switch c.Type {
		case "Complete":
			return owner, control.JobSucceeded, "", nil
		case "Failed":
			return owner, control.JobFailed, c.Reason, nil
		}
	}
	switch {
	case j.Status.Succeeded > 0:
		return owner, control.JobSucceeded, "", nil
	case j.Status.Failed > 0:
		return owner, control.JobFailed, "", nil
	case j.Status.Active > 0:
		return owner, control.JobRunning, "", nil
	}
	return owner, control.JobPending, "", nil
}

// readClusterJob is one Job's state and the log after offset.
func (a *Agent) readClusterJob(ctx context.Context, req control.ClusterJob) (control.ClusterJobResult, error) {
	res := control.ClusterJobResult{Offset: req.Offset}
	k, err := a.kubeReader()
	if err != nil {
		return res, err
	}
	ns := url.PathEscape(k.ns)
	st, raw, err := k.get(ctx, "/apis/batch/v1/namespaces/"+ns+"/jobs/"+req.Job, 1<<20)
	if err != nil {
		return res, err
	}
	switch {
	case st == http.StatusNotFound:
		res.State = control.JobGone
		return res, nil
	case st != http.StatusOK:
		return res, fmt.Errorf("the API server answered %d for job %s", st, req.Job)
	}
	owner, state, reason, err := jobState(raw)
	if err != nil {
		return res, fmt.Errorf("job %s: %w", req.Job, err)
	}
	if owner != req.Owner {
		// Never says whose it is.
		return res, errNotYourJob
	}
	res.State, res.Reason = state, reason
	st, raw, err = k.get(ctx, "/api/v1/namespaces/"+ns+"/pods?labelSelector="+url.QueryEscape("job-name="+req.Job), 1<<20)
	if err != nil || st != http.StatusOK {
		return res, nil // no pod yet: a state, no log
	}
	var pods struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		} `json:"items"`
	}
	if json.Unmarshal(raw, &pods) != nil || len(pods.Items) == 0 {
		return res, nil
	}
	// backoffLimit 0: one pod. The log from its start, up to offset+chunk;
	// the API server has no offset, so the prefix is read and dropped here.
	limit := req.Offset + control.ClusterJobChunk
	st, raw, err = k.get(ctx, "/api/v1/namespaces/"+ns+"/pods/"+url.PathEscape(pods.Items[0].Metadata.Name)+
		"/log?container=job&limitBytes="+strconv.FormatInt(limit, 10), limit)
	if err != nil || st != http.StatusOK {
		return res, nil // a pod still starting has no log
	}
	if int64(len(raw)) > req.Offset {
		res.Log = string(raw[req.Offset:])
		res.Offset = int64(len(raw))
	}
	return res, nil
}

var errNotYourJob = fmt.Errorf("no such job for that pod")

// answerClusterJob serves one TypeClusterJob.
func (a *Agent) answerClusterJob(ctx context.Context, conn nodeLink, m control.Message) {
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
	if a.cfg.FleetClusterOps == "" {
		fail(control.CodeRefused, "this node is no cluster's ops link")
		return
	}
	var req control.ClusterJob
	if err := json.Unmarshal(m.Payload, &req); err != nil || m.OpID == "" ||
		!jobNameRE.MatchString(req.Job) || !jobOwnerRE.MatchString(req.Owner) || req.Offset < 0 {
		fail(control.CodeBadArgs, "malformed cluster_job")
		return
	}
	rctx, cancel := context.WithTimeout(ctx, clusterOpTimeout)
	defer cancel()
	res, err := a.readClusterJob(rctx, req)
	if err == errNotYourJob {
		fail(control.CodeNoSuchJob, err.Error())
		return
	}
	if err != nil {
		res.Error = err.Error()
		log.Printf("cluster_job: %s: %v", req.Job, err)
	}
	out, err := control.New(control.TypeClusterJobResult, res)
	if err != nil {
		fail("INTERNAL", "cluster_job: result does not encode")
		return
	}
	reply(out)
}
