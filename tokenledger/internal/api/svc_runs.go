package api

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Service runs (claude-fleet#4004, the SPACE EPIC C2): a service principal
// dispatches ONE run, reads where it stands, cancels it, and is told how it
// ended without asking.
//
//	POST /v1/svc/runs               runs:write  queue a run (idempotent per key)
//	GET  /v1/svc/runs               runs:read   list: ?tenant= &since= &state= &limit=
//	GET  /v1/svc/runs/R<n>          runs:read   one run, its result inline once it ended
//	POST /v1/svc/runs/R<n>/cancel   runs:write  cancel a queued or running run
//
// A principal sees only its own runs: another's R<n> is 404.
//
// The queue: per principal at most fleet.svc.<name>.max_running runs at once
// (default 4) and at most ONE per tenant, oldest first; a run still queued
// after 30 minutes is expired (queue_timeout), one running past its deadline
// plus a grace is failed (run_timeout). Queued runs go to the runner
// (SvcRunner — C3's one-shot environment); it reports back through
// SvcRunFinish. With no runner nothing is dispatched and runs wait, then
// expire.
//
// A run that ends is told to its callback_url (which must sit under the
// prefix registered for the principal — POST /v1/fleet/svc op callback):
// POST of the run's own GET body, signed
// `X-Fleet-Signature: t=<unix>,v1=<hex hmac-sha256(secret, t + "." + body)>`,
// retried at 1m / 5m / 30m. Lost anyway, GET /v1/svc/runs/R<n> answers the same
// body. Audit: svc.run.submit · svc.run.start · svc.run.retry · svc.run.cancel ·
// svc.run.end · svc.run.callback.
//
// A run that fails for a back-end reason (infra_error) is tried ONCE more under
// the same R<n> (claude-fleet#4007): back in the queue, attempt 2, inside what
// is left of the deadline its first start fixed (deadline_at). Nothing else is
// retried. svc_runs_alert.go tells the person on duty when runs fail in a
// batch or wait too long.

const (
	SvcRunsPath = "/v1/svc/runs"

	svcMaxRunningDefault = 4
	svcQueueTTL          = 30 * time.Minute
	svcRunGrace          = 2 * time.Minute
	svcDeadlineDefault   = 900
	svcDeadlineMin       = 60
	svcDeadlineMax       = 3600
	svcInputsMax         = 256 << 10
	svcReportMax         = 1 << 20
	svcSummaryMaxRunes   = 60
	svcCallbackLease     = 2 * time.Minute
	svcCallbackTimeout   = 10 * time.Second
	svcCallbackBatch     = 20
	svcTickEvery         = 5 * time.Second
	svcCallbackWord      = "fcb_"
)

// SvcCallbackBackoff is when a failed callback is tried again: after the first
// try, three more — 1, 5 and 30 minutes after the try before.
var SvcCallbackBackoff = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute}

// The error codes a run ends with (the EPIC's contract 6). Only the code goes
// to the caller; any detail stays in the hub's log and audit.
const (
	SvcErrQueueTimeout    = "queue_timeout"
	SvcErrRunTimeout      = "run_timeout"
	SvcErrTemplateInvalid = "template_invalid"
	SvcErrOutputInvalid   = "output_invalid"
	SvcErrInfra           = "infra_error"
	SvcErrCancelled       = "cancelled"
)

// SvcMaxRunningKey is the fleet setting capping one principal's running runs.
func SvcMaxRunningKey(principal string) string {
	return "fleet.svc." + strings.TrimPrefix(principal, "svc:") + ".max_running"
}

// SvcRunner starts and stops the environment a run executes in (C3). Start
// returns once the run is under way; its end comes back through
// Server.SvcRunFinish. Cancel stops a running one (the run is already marked).
type SvcRunner interface {
	Start(ctx context.Context, run store.SvcRun) error
	Cancel(ctx context.Context, run store.SvcRun) error
}

// SvcRunRequest is POST /v1/svc/runs.
type SvcRunRequest struct {
	Template       string          `json:"template"`
	TemplateDigest string          `json:"template_digest"`
	Tenant         string          `json:"tenant"`
	Subject        string          `json:"subject"`
	Inputs         json.RawMessage `json:"inputs"`
	IdempotencyKey string          `json:"idempotency_key"`
	CallbackURL    string          `json:"callback_url"`
	DeadlineS      int             `json:"deadline_s"`
}

// SvcRunView is a run as the caller reads it — the GET body and the callback's.
type SvcRunView struct {
	RunID            string          `json:"run_id"`
	State            string          `json:"state"`
	ErrorCode        string          `json:"error_code,omitempty"`
	Tenant           string          `json:"tenant"`
	Subject          string          `json:"subject,omitempty"`
	Template         string          `json:"template"`
	TemplateDigest   string          `json:"template_digest"`
	IdempotencyKey   string          `json:"idempotency_key"`
	Attempt          int             `json:"attempt"`
	DeadlineS        int             `json:"deadline_s"`
	QueuedAt         time.Time       `json:"queued_at"`
	StartedAt        *time.Time      `json:"started_at,omitempty"`
	FinishedAt       *time.Time      `json:"finished_at,omitempty"`
	CallbackState    string          `json:"callback_state,omitempty"`
	CallbackAttempts int             `json:"callback_attempts,omitempty"`
	Usage            json.RawMessage `json:"usage,omitempty"`
	Result           json.RawMessage `json:"result,omitempty"`
	Replayed         bool            `json:"replayed,omitempty"`
}

func svcRunView(r store.SvcRun, withResult bool) SvcRunView {
	v := SvcRunView{RunID: r.Ref(), State: r.State, ErrorCode: r.ErrorCode, Tenant: r.Tenant, Subject: r.Subject,
		Template: r.Template, TemplateDigest: r.Digest, IdempotencyKey: r.IdempotencyKey, Attempt: r.Attempt,
		DeadlineS: r.DeadlineS, QueuedAt: r.QueuedAt, StartedAt: r.StartedAt, FinishedAt: r.FinishedAt,
		CallbackState: r.CallbackState, CallbackAttempts: r.CallbackAttempts}
	if r.UsageJSON != "" {
		v.Usage = json.RawMessage(r.UsageJSON)
	}
	if withResult && r.ResultJSON != "" {
		v.Result = json.RawMessage(r.ResultJSON)
	}
	return v
}

// svcRunError answers a refusal with its code (contract 6) beside the words.
func svcRunError(w http.ResponseWriter, status int, code, msg string) {
	body := map[string]string{"error": msg}
	if code != "" {
		body["error_code"] = code
	}
	writeJSON(w, status, body)
}

// svcRunsMux mounts the runs routes on the service door's mux.
func (s *Server) svcRunsMux(m *http.ServeMux) {
	list := s.svcOnly(store.SvcRunsRead, http.HandlerFunc(s.handleSvcRunsList))
	submit := s.svcOnly(store.SvcRunsWrite, http.HandlerFunc(s.handleSvcRunSubmit))
	m.Handle(SvcRunsPath, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			list.ServeHTTP(w, r)
		case http.MethodPost:
			submit.ServeHTTP(w, r)
		default:
			w.Header().Set("Allow", "GET, POST")
			httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		}
	}))
	get := s.svcOnly(store.SvcRunsRead, http.HandlerFunc(s.handleSvcRunGet))
	cancel := s.svcOnly(store.SvcRunsWrite, http.HandlerFunc(s.handleSvcRunCancel))
	m.Handle(SvcRunsPath+"/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rest := strings.TrimPrefix(r.URL.Path, SvcRunsPath+"/")
		switch {
		case !strings.Contains(rest, "/") && r.Method == http.MethodGet:
			get.ServeHTTP(w, r)
		case strings.HasSuffix(rest, "/cancel") && strings.Count(rest, "/") == 1 && r.Method == http.MethodPost:
			cancel.ServeHTTP(w, r)
		case !strings.Contains(rest, "/") || strings.HasSuffix(rest, "/cancel"):
			httpError(w, http.StatusMethodNotAllowed, "GET a run, POST its /cancel")
		default:
			httpError(w, http.StatusNotFound, "no such route")
		}
	}))
}

// svcOwnRun is the caller's run named in the path, or a written 404.
func (s *Server) svcOwnRun(w http.ResponseWriter, r *http.Request) (store.SvcRun, bool) {
	p, _, _ := SvcCallerOf(r.Context())
	ref := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, SvcRunsPath+"/"), "/cancel")
	id := store.ParseSvcRunRef(ref)
	if id == 0 {
		httpError(w, http.StatusNotFound, "no such run")
		return store.SvcRun{}, false
	}
	run, err := s.Store.SvcRun(id)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && run.Principal != p.ID) {
		httpError(w, http.StatusNotFound, "no such run")
		return store.SvcRun{}, false
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return store.SvcRun{}, false
	}
	return run, true
}

func svcWord(v string, max int) bool {
	if v == "" || len(v) > max {
		return false
	}
	for _, c := range v {
		if c <= ' ' || c == 0x7f {
			return false
		}
	}
	return true
}

func svcHexDigest(v string) bool {
	v = strings.TrimPrefix(v, "sha256:")
	if len(v) != 64 {
		return false
	}
	_, err := hex.DecodeString(v)
	return err == nil && strings.ToLower(v) == v
}

// svcCallbackAllowed is whether u may be called back under the registered
// prefix: same scheme, host and port, a path under the prefix's, no userinfo,
// no fragment, no dot segments that would climb out of it.
func svcCallbackAllowed(u, prefix string) bool {
	if prefix == "" || !strings.HasPrefix(u, prefix) {
		return false
	}
	pu, err := url.Parse(u)
	if err != nil || pu.User != nil || pu.Fragment != "" || pu.Host == "" {
		return false
	}
	for _, seg := range strings.Split(pu.Path, "/") {
		if seg == "." || seg == ".." {
			return false
		}
	}
	return !strings.Contains(strings.ToLower(u), "%2e")
}

// SvcCallbackPrefixCheck validates and normalises a callback prefix: an
// absolute https URL (http only for a loopback host), no userinfo, query or
// fragment, ending in "/".
func SvcCallbackPrefixCheck(p string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(p))
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("a callback prefix is an absolute URL with no userinfo, query or fragment")
	}
	switch u.Scheme {
	case "https":
	case "http":
		if ip := net.ParseIP(u.Hostname()); u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return "", errors.New("a callback prefix is https (http only for a loopback host)")
		}
	default:
		return "", errors.New("a callback prefix is https")
	}
	out := u.String()
	if !strings.HasSuffix(out, "/") {
		out += "/"
	}
	return out, nil
}

// SvcSetCallback registers principal's callback prefix. A secret is minted
// when none exists or rotate is set, and returned then only — "" otherwise.
func SvcSetCallback(st *store.Store, principal, prefix string, rotate bool, actor string, now time.Time) (string, store.SvcCallback, error) {
	p, err := st.SvcPrincipal(principal)
	if err != nil {
		return "", store.SvcCallback{}, err
	}
	norm, err := SvcCallbackPrefixCheck(prefix)
	if err != nil {
		return "", store.SvcCallback{}, err
	}
	c, err := st.SvcCallbackOf(p.ID)
	if err != nil && !errors.Is(err, store.ErrNoSvcCallback) {
		return "", store.SvcCallback{}, err
	}
	secret := ""
	if c.Secret == "" || rotate {
		b := make([]byte, tokenBytes)
		if _, err := rand.Read(b); err != nil {
			return "", store.SvcCallback{}, err
		}
		secret = svcCallbackWord + base64.RawURLEncoding.EncodeToString(b)
		c.Secret = secret
	}
	c.Principal, c.URLPrefix = p.ID, norm
	if err := st.SetSvcCallback(c, now); err != nil {
		return "", store.SvcCallback{}, err
	}
	detail := norm
	if secret != "" {
		detail += " (new secret)"
	}
	if err := SvcAudit(st, actor, "svc.callback", p.ID, "ok", detail, now); err != nil {
		log.Printf("svc audit: %v", err)
	}
	c, err = st.SvcCallbackOf(p.ID)
	return secret, c, err
}

// svcRequestSHA fingerprints what a run was asked to do, so a replayed key
// with different words is told apart from a retry.
func svcRequestSHA(req SvcRunRequest, inputs string) string {
	h := sha256.New()
	for _, f := range []string{req.Template, req.TemplateDigest, req.Tenant, req.Subject, inputs,
		req.CallbackURL, strconv.Itoa(req.DeadlineS)} {
		h.Write([]byte(f))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

func (s *Server) handleSvcRunSubmit(w http.ResponseWriter, r *http.Request) {
	p, _, _ := SvcCallerOf(r.Context())
	now := time.Now()
	var req SvcRunRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, svcInputsMax+16<<10)).Decode(&req); err != nil {
		svcRunError(w, http.StatusBadRequest, "", "malformed request: "+err.Error())
		return
	}
	if req.DeadlineS == 0 {
		req.DeadlineS = svcDeadlineDefault
	}
	switch {
	case !svcWord(req.IdempotencyKey, 200):
		svcRunError(w, http.StatusBadRequest, "", "idempotency_key is one word of at most 200 bytes")
		return
	case !svcWord(req.Tenant, 200):
		svcRunError(w, http.StatusBadRequest, "", "tenant is one word of at most 200 bytes")
		return
	case req.Subject != "" && !svcWord(req.Subject, 200):
		svcRunError(w, http.StatusBadRequest, "", "subject is one word of at most 200 bytes")
		return
	case !svcWord(req.Template, 100) || !svcHexDigest(req.TemplateDigest):
		svcRunError(w, http.StatusBadRequest, SvcErrTemplateInvalid, "template is a name and template_digest a lowercase sha256")
		return
	case req.DeadlineS < svcDeadlineMin || req.DeadlineS > svcDeadlineMax:
		svcRunError(w, http.StatusBadRequest, "", fmt.Sprintf("deadline_s is %d..%d", svcDeadlineMin, svcDeadlineMax))
		return
	}
	inputs := "{}"
	if len(req.Inputs) > 0 {
		var obj map[string]any
		if err := json.Unmarshal(req.Inputs, &obj); err != nil || obj == nil {
			svcRunError(w, http.StatusBadRequest, "", "inputs is a JSON object")
			return
		}
		var buf bytes.Buffer
		if err := json.Compact(&buf, req.Inputs); err != nil {
			svcRunError(w, http.StatusBadRequest, "", "inputs is a JSON object")
			return
		}
		if buf.Len() > svcInputsMax {
			svcRunError(w, http.StatusRequestEntityTooLarge, "", "inputs is larger than 256 KiB")
			return
		}
		inputs = buf.String()
	}
	if req.CallbackURL != "" {
		c, err := s.Store.SvcCallbackOf(p.ID)
		if err != nil || !svcCallbackAllowed(req.CallbackURL, c.URLPrefix) {
			svcRunError(w, http.StatusBadRequest, "", "callback_url is not under the callback prefix registered for this service")
			return
		}
	}
	sha := svcRequestSHA(req, inputs)
	run, created, err := s.Store.CreateSvcRun(store.SvcRun{Principal: p.ID, Tenant: req.Tenant, Subject: req.Subject,
		Template: req.Template, Digest: req.TemplateDigest, InputsJSON: inputs, IdempotencyKey: req.IdempotencyKey,
		RequestSHA: sha, DeadlineS: req.DeadlineS, CallbackURL: req.CallbackURL}, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !created && run.RequestSHA != sha {
		svcRunError(w, http.StatusConflict, "", "idempotency_key was already used for a different run ("+run.Ref()+")")
		return
	}
	if created {
		s.svcAudit(p.ID, "svc.run.submit", run.Ref(), "ok", run.Tenant, now)
		s.svcDispatch(r.Context(), now)
		if fresh, err := s.Store.SvcRun(run.ID); err == nil {
			run = fresh
		}
	}
	v := svcRunView(run, SvcRunTerminalView(run))
	v.Replayed = !created
	writeJSON(w, http.StatusAccepted, v)
}

// SvcRunTerminalView is whether a run's view carries its result: once it ended.
func SvcRunTerminalView(r store.SvcRun) bool { return store.SvcRunTerminal(r.State) }

func (s *Server) handleSvcRunsList(w http.ResponseWriter, r *http.Request) {
	p, _, _ := SvcCallerOf(r.Context())
	q := r.URL.Query()
	f := store.SvcRunFilter{Principal: p.ID, Tenant: q.Get("tenant"), State: q.Get("state")}
	if v := q.Get("since"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			httpError(w, http.StatusBadRequest, "since is an RFC 3339 time")
			return
		}
		f.Since = t
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			httpError(w, http.StatusBadRequest, "limit is a positive number")
			return
		}
		f.Limit = n
	}
	runs, err := s.Store.SvcRuns(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := []SvcRunView{}
	for _, run := range runs {
		out = append(out, svcRunView(run, false))
	}
	writeJSON(w, http.StatusOK, map[string]any{"runs": out})
}

func (s *Server) handleSvcRunGet(w http.ResponseWriter, r *http.Request) {
	run, ok := s.svcOwnRun(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, svcRunView(run, SvcRunTerminalView(run)))
}

func (s *Server) handleSvcRunCancel(w http.ResponseWriter, r *http.Request) {
	run, ok := s.svcOwnRun(w, r)
	if !ok {
		return
	}
	now := time.Now()
	was := run.State
	ended, changed, err := s.Store.FinishSvcRun(run.ID, store.SvcRunEnd{State: store.SvcRunCancelled,
		ErrorCode: SvcErrCancelled}, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !changed {
		svcRunError(w, http.StatusConflict, "", "the run already ended ("+ended.State+")")
		return
	}
	s.svcAudit(run.Principal, "svc.run.cancel", run.Ref(), "ok", was, now)
	if was == store.SvcRunRunning {
		s.svcRunnerCancel(r.Context(), ended)
	}
	s.svcAudit(run.Principal, "svc.run.end", run.Ref(), store.SvcRunCancelled, SvcErrCancelled, now)
	writeJSON(w, http.StatusOK, svcRunView(ended, true))
}

func (s *Server) svcRunnerCancel(ctx context.Context, run store.SvcRun) {
	if s.SvcRunner == nil {
		return
	}
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), svcCallbackTimeout)
	defer cancel()
	if err := s.SvcRunner.Cancel(cctx, run); err != nil {
		log.Printf("svc run %s: runner cancel: %v", run.Ref(), err)
	}
}

// SvcRunResult is what a runner hands back for a run that succeeded.
type SvcRunResult struct {
	Report string          `json:"report"`
	Meta   json.RawMessage `json:"meta"`
}

// svcResultCheck is "" when res is a result the contract accepts (contract 5:
// a Markdown report ≤ 1 MB, meta with a title and a summary ≤ 60 characters).
func svcResultCheck(res *SvcRunResult) string {
	if res == nil || strings.TrimSpace(res.Report) == "" {
		return "no report"
	}
	if len(res.Report) > svcReportMax || !utf8.ValidString(res.Report) {
		return "report over 1 MB or not UTF-8"
	}
	var meta struct {
		Title   string `json:"title"`
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal(res.Meta, &meta); err != nil {
		return "meta is not a JSON object"
	}
	if strings.TrimSpace(meta.Title) == "" {
		return "meta has no title"
	}
	if utf8.RuneCountInString(meta.Summary) > svcSummaryMaxRunes {
		return "meta.summary over 60 characters"
	}
	return ""
}

// SvcRunFinish is how a run's end reaches the hub — the runner (C3) calls it
// with state succeeded (res = the outputs) or failed (code = why). A result
// the contract refuses fails the run output_invalid. Ending a run that already
// ended changes nothing and returns it as it is. A failure for a back-end
// reason (infra_error) on the first attempt does not end the run: it goes back
// in the queue for one retry (claude-fleet#4007) and comes back running →
// queued, attempt 1.
func (s *Server) SvcRunFinish(id int64, state, code string, res *SvcRunResult, usage json.RawMessage) (store.SvcRun, error) {
	return s.SvcRunFinishDetail(id, state, code, "", res, usage)
}

// SvcRunRetryable is whether a run that failed with code is tried once more:
// only a back-end failure (a pod lost, a schedule that never came, the
// credential proxy's 5xx, a result that could not be handed back). A timeout,
// a bad template, a bad output or a spent quota would fail the same way again.
func SvcRunRetryable(code string) bool { return code == SvcErrInfra }

// svcRetryMinLeft is the least of a run's deadline a retry must still have.
const svcRetryMinLeft = time.Minute

// SvcRunFinishDetail is SvcRunFinish with the runner's own words on a failure
// (a stderr tail, the Job's events): they go to the hub's log and audit only —
// the caller is told the error code and nothing else (contract 6).
func (s *Server) SvcRunFinishDetail(id int64, state, code, detail string, res *SvcRunResult, usage json.RawMessage) (store.SvcRun, error) {
	now := time.Now()
	end := store.SvcRunEnd{State: state, ErrorCode: code}
	if len(usage) > 0 && json.Valid(usage) {
		var b bytes.Buffer
		if json.Compact(&b, usage) == nil {
			end.UsageJSON = b.String()
		}
	}
	switch state {
	case store.SvcRunSucceeded:
		if why := svcResultCheck(res); why != "" {
			end.State, end.ErrorCode, detail = store.SvcRunFailed, SvcErrOutputInvalid, SvcErrOutputInvalid+": "+why
			break
		}
		b, err := json.Marshal(res)
		if err != nil {
			return store.SvcRun{}, err
		}
		end.ResultJSON, end.ErrorCode, detail = string(b), "", ""
	case store.SvcRunFailed:
		if end.ErrorCode == "" {
			end.ErrorCode, detail = SvcErrInfra, SvcErrInfra
		}
		if d := strings.TrimSpace(detail); d != "" && d != end.ErrorCode {
			detail = end.ErrorCode + ": " + truncate(d, 300)
		} else {
			detail = end.ErrorCode
		}
		if SvcRunRetryable(end.ErrorCode) {
			run, requeued, err := s.Store.RequeueSvcRun(id, now, svcRetryMinLeft)
			if err != nil {
				return run, err
			}
			if requeued {
				log.Printf("svc run %s: attempt 1 failed (%s) — queued again for its one retry", run.Ref(), detail)
				s.svcAudit(run.Principal, "svc.run.retry", run.Ref(), "queued", detail, now)
				return run, nil
			}
		}
	default:
		return store.SvcRun{}, fmt.Errorf("a runner ends a run succeeded or failed, not %q", state)
	}
	run, changed, err := s.Store.FinishSvcRun(id, end, now)
	if err != nil {
		return run, err
	}
	if changed {
		s.svcAudit(run.Principal, "svc.run.end", run.Ref(), run.State, detail, now)
		if detail != end.ErrorCode && end.ErrorCode != "" {
			log.Printf("svc run %s: %s", run.Ref(), detail)
		}
	}
	return run, nil
}

// svcMaxRunning is principal's cap on running runs.
func (s *Server) svcMaxRunning(settings map[string]string, principal string) int {
	if n, err := strconv.Atoi(strings.TrimSpace(settings[SvcMaxRunningKey(principal)])); err == nil && n >= 0 {
		return n
	}
	return svcMaxRunningDefault
}

// svcDispatch hands what may run now to the runner. Only the replica that
// leads "svc-runs" does; with no runner, nothing is moved.
func (s *Server) svcDispatch(ctx context.Context, now time.Time) {
	if s.SvcRunner == nil || !s.Elector.Leader(ctx, "svc-runs") {
		return
	}
	principals, err := s.Store.SvcRunsPrincipals()
	if err != nil {
		log.Printf("svc runs: %v", err)
		return
	}
	if len(principals) == 0 {
		return
	}
	settings, _ := s.Store.FleetSettings()
	for _, p := range principals {
		claimed, err := s.Store.ClaimSvcRuns(p, s.svcMaxRunning(settings, p), now)
		if err != nil {
			log.Printf("svc runs: claim for %s: %v", p, err)
			continue
		}
		for _, run := range claimed {
			s.svcAudit(run.Principal, "svc.run.start", run.Ref(), "ok", "attempt "+strconv.Itoa(run.Attempt), now)
			sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), svcCallbackTimeout)
			err := s.SvcRunner.Start(sctx, run)
			cancel()
			if err != nil {
				log.Printf("svc run %s: runner start: %v", run.Ref(), err)
				if _, err := s.SvcRunFinish(run.ID, store.SvcRunFailed, SvcErrInfra, nil, nil); err != nil {
					log.Printf("svc run %s: %v", run.Ref(), err)
				}
			}
		}
	}
}

// SvcRunsTick is one sweep at now: expire what waited too long, fail what ran
// past its deadline, then dispatch.
func (s *Server) SvcRunsTick(ctx context.Context, now time.Time) {
	if !s.Elector.Leader(ctx, "svc-runs") {
		return
	}
	if queued, err := s.Store.SvcRunsIn(store.SvcRunQueued); err == nil {
		for _, run := range queued {
			if run.Attempt > 0 && run.DeadlineAt != nil {
				// A retry that never got to start before its deadline ends
				// the way its first attempt did.
				if now.Before(*run.DeadlineAt) {
					continue
				}
				if r, changed, err := s.Store.FinishSvcRun(run.ID, store.SvcRunEnd{State: store.SvcRunFailed,
					ErrorCode: SvcErrInfra}, now); err == nil && changed {
					s.svcAudit(r.Principal, "svc.run.end", r.Ref(), r.State, SvcErrInfra+": retry never started before the deadline", now)
				}
				continue
			}
			if now.Sub(run.QueuedAt) < svcQueueTTL {
				continue
			}
			if r, changed, err := s.Store.FinishSvcRun(run.ID, store.SvcRunEnd{State: store.SvcRunExpired,
				ErrorCode: SvcErrQueueTimeout}, now); err == nil && changed {
				s.svcAudit(r.Principal, "svc.run.end", r.Ref(), r.State, SvcErrQueueTimeout, now)
			}
		}
	}
	if running, err := s.Store.SvcRunsIn(store.SvcRunRunning); err == nil {
		for _, run := range running {
			if run.StartedAt == nil {
				continue
			}
			deadline := run.StartedAt.Add(time.Duration(run.DeadlineS) * time.Second)
			if run.DeadlineAt != nil {
				deadline = *run.DeadlineAt
			}
			if now.Before(deadline.Add(svcRunGrace)) {
				continue
			}
			if r, changed, err := s.Store.FinishSvcRun(run.ID, store.SvcRunEnd{State: store.SvcRunFailed,
				ErrorCode: SvcErrRunTimeout}, now); err == nil && changed {
				s.svcAudit(r.Principal, "svc.run.end", r.Ref(), r.State, SvcErrRunTimeout, now)
				s.svcRunnerCancel(ctx, r)
			}
		}
	}
	s.svcDispatch(ctx, now)
}

// SvcSign is the X-Fleet-Signature value for body at t.
func SvcSign(secret string, t time.Time, body []byte) string {
	ts := strconv.FormatInt(t.Unix(), 10)
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(ts + "." + string(body)))
	return "t=" + ts + ",v1=" + hex.EncodeToString(m.Sum(nil))
}

func (s *Server) svcHTTP() *http.Client {
	if s.SvcHTTP != nil {
		return s.SvcHTTP
	}
	return &http.Client{Timeout: svcCallbackTimeout, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse // a callback is never sent anywhere but where it was registered
	}}
}

// SvcCallbacksTick sends every callback due at now, once each.
func (s *Server) SvcCallbacksTick(ctx context.Context, now time.Time) {
	if !s.Elector.Leader(ctx, "svc-callbacks") {
		return
	}
	due, err := s.Store.SvcCallbacksDue(now, svcCallbackBatch)
	if err != nil {
		log.Printf("svc callbacks: %v", err)
		return
	}
	for _, run := range due {
		if ok, err := s.Store.LeaseSvcCallback(run, now.Add(svcCallbackLease)); err != nil || !ok {
			continue
		}
		s.svcCallbackSend(ctx, run, now)
	}
}

// svcCallbackSend makes one attempt and writes what came of it.
func (s *Server) svcCallbackSend(ctx context.Context, run store.SvcRun, now time.Time) {
	attempt := run.CallbackAttempts + 1
	why := ""
	c, err := s.Store.SvcCallbackOf(run.Principal)
	switch {
	case err != nil:
		why = "no callback registration"
	case !svcCallbackAllowed(run.CallbackURL, c.URLPrefix):
		why = "callback_url no longer under the registered prefix"
	}
	if why != "" {
		_ = s.Store.RecordSvcCallback(run.ID, store.SvcCallbackFailed, attempt, nil, why)
		s.svcAudit(run.Principal, "svc.run.callback", run.Ref(), "failed", why, now)
		return
	}
	body, _ := json.Marshal(svcRunView(run, true))
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), svcCallbackTimeout)
	defer cancel()
	req, _ := http.NewRequestWithContext(cctx, http.MethodPost, run.CallbackURL, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Fleet-Signature", SvcSign(c.Secret, now, body))
	req.Header.Set("X-Fleet-Run", run.Ref())
	res, err := s.svcHTTP().Do(req)
	if err == nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 64<<10))
		res.Body.Close()
		if res.StatusCode/100 == 2 {
			_ = s.Store.RecordSvcCallback(run.ID, store.SvcCallbackDelivered, attempt, nil, "")
			s.svcAudit(run.Principal, "svc.run.callback", run.Ref(), "ok", "attempt "+strconv.Itoa(attempt), now)
			return
		}
		why = "HTTP " + strconv.Itoa(res.StatusCode)
	} else {
		why = err.Error()
	}
	if attempt > len(SvcCallbackBackoff) {
		_ = s.Store.RecordSvcCallback(run.ID, store.SvcCallbackFailed, attempt, nil, why)
		s.svcAudit(run.Principal, "svc.run.callback", run.Ref(), "failed", why, now)
		return
	}
	next := now.Add(SvcCallbackBackoff[attempt-1])
	_ = s.Store.RecordSvcCallback(run.ID, store.SvcCallbackPending, attempt, &next, why)
	s.svcAudit(run.Principal, "svc.run.callback", run.Ref(), "retry", why, now)
}

// RunSvcRuns sweeps the queue and sends callbacks until ctx ends; each half
// runs on the replica that leads it.
func (s *Server) RunSvcRuns(ctx context.Context) {
	if s.SvcRunner == nil {
		log.Printf("svc runs: no runner on this hub — runs queue and expire after %s", svcQueueTTL)
	}
	go func() {
		t := time.NewTicker(svcTickEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-t.C:
				s.SvcCallbacksTick(ctx, now)
			}
		}
	}()
	t := time.NewTicker(svcTickEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			s.SvcRunsTick(ctx, now)
		}
	}
}
