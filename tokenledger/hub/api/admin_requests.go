package api

import (
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
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 管理侧「申请」(claude-fleet#4052, EPIC #4048 C4): an admin reads the requests
// C3's /apply records and decides them. The console's /admin/requests page
// (extras/web-console) is the only reader; a member is answered the 404 an
// unknown address gets (claude-fleet#3925), as the signing keys' read is.
//
//	GET  /v1/admin/requests[?state=pending|approved|rejected|withdrawn]
//	                                    the list, newest first, and the KPIs
//	GET  /v1/admin/requests?state=pending&count=1
//	                                    {pending: n} — the left column's count
//	GET  /v1/admin/requests/<id>        one request, its person's sign-ins,
//	                                    trial and earlier requests
//	POST /v1/admin/requests/<id>/approve
//	                                    onto the list, the admitPerson road
//	                                    (共同约定 8): request.approve + user.add
//	POST /v1/admin/requests/<id>/reject {reason, cooldown_days}
//	                                    the reason goes to the person as written
//
// Each decision is told to the person (C5's notice desk, notify.go): once,
// however often approve is pressed.

const (
	AdminRequestsPath   = "/v1/admin/requests"
	adminRequestsPrefix = AdminRequestsPath + "/"

	// requestReasonMax bounds the words a refusal sends (runes).
	requestReasonMax = 500
	// requestCooldownMaxDays bounds a refusal's cooldown.
	requestCooldownMaxDays = 365
)

// adminRequestPageRe is the request page a notice links to
// (/admin/requests/<id>, claude-fleet#4062): the one admin address a
// signed-out browser is sent back to after signing in — WeChat's own browser
// signs in by the service account with no page in between, so the admin who
// tapped 「新申请待审核」 lands on that request's drawer, not the console's
// front page.
var adminRequestPageRe = regexp.MustCompile(`^/admin/requests(/rq-[A-Za-z0-9_-]{1,64})?$`)

// rememberAdminReturn is adminGate's signed-out step: a request page asked
// for before signing in is where loginReturn sends the browser after. Never
// answers the request itself (the sign-in redirect still follows).
func rememberAdminReturn(w http.ResponseWriter, r *http.Request) bool {
	if (r.Method == http.MethodGet || r.Method == http.MethodHead) && adminRequestPageRe.MatchString(r.URL.Path) {
		http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: r.URL.Path, Path: "/",
			HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r), MaxAge: int(loginCookieTTL.Seconds())})
	}
	return false
}

// adminRequestRow is one request as the list shows it.
type adminRequestRow struct {
	store.AccessRequest
	// Person is the principal the request's way of signing in already names
	// (a trial person has one), "" for none.
	Person string `json:"person,omitempty"`
	// Trial: that person came in through the trial.
	Trial bool `json:"trial"`
}

// adminRequestsView is the list.
type adminRequestsView struct {
	Requests []adminRequestRow `json:"requests"`
	Pending  int               `json:"pending"`
	// OldestPending is when the longest-waiting request came in.
	OldestPending *time.Time `json:"oldest_pending,omitempty"`
	// Decided7d / Approved7d count the last seven days' decisions.
	Decided7d  int `json:"decided_7d"`
	Approved7d int `json:"approved_7d"`
	// CooldownDays is a refusal's default wait (fleet.apply.cooldown_days).
	CooldownDays int `json:"cooldown_days"`
}

// requestTrialView is the person's trial as the drawer shows it.
type requestTrialView struct {
	State       string     `json:"state"`
	StartedAt   time.Time  `json:"started_at"`
	PlacedAt    *time.Time `json:"placed_at,omitempty"`
	LastSeen    *time.Time `json:"last_seen,omitempty"`
	ReclaimedAt *time.Time `json:"reclaimed_at,omitempty"`
	// Minutes is how long they had a machine (used_secs + the seat held).
	Minutes int `json:"minutes"`
	// Messages is how many lines they sent (claude-fleet#4059).
	Messages *int `json:"messages,omitempty"`
	// Ended is why it ended — time · msgs · approved (C12 adds its own) —
	// "" while it runs.
	Ended string `json:"ended,omitempty"`
}

// requestSigninsView is the person's sign-ins.
type requestSigninsView struct {
	Count int        `json:"count"`
	First *time.Time `json:"first,omitempty"`
	Last  *time.Time `json:"last,omitempty"`
}

// adminRequestDetail is one request, as its drawer shows it.
type adminRequestDetail struct {
	adminRequestRow
	Signins requestSigninsView `json:"signins"`
	TrialOf *requestTrialView  `json:"trial_of,omitempty"`
	// ConvoUntil is when the trial's kept conversation is deleted — only its
	// expiry, never its content (C12's hub_trial_convos); absent = none kept.
	ConvoUntil *time.Time `json:"convo_until,omitempty"`
	// Earlier are the same way's other requests, newest first.
	Earlier []store.AccessRequest `json:"earlier"`
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func (s *Server) handleAdminRequests(w http.ResponseWriter, r *http.Request) {
	// adminOnly's gate, answered as a missing page instead of 403 (#3925)
	if memberRole(roleOf(r.Context())) {
		s.auditRoleDenied(r)
		http.NotFound(w, r)
		return
	}
	if s.Store == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.URL.Path == AdminRequestsPath {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			httpError(w, http.StatusMethodNotAllowed, "GET only")
			return
		}
		s.adminRequestsList(w, r)
		return
	}
	id, verb, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, adminRequestsPrefix), "/")
	switch {
	case id == "":
		http.NotFound(w, r)
	case verb == "" && (r.Method == http.MethodGet || r.Method == http.MethodHead):
		req, err := s.Store.Requests().Get(id)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not read the request")
			return
		}
		if req == nil {
			httpError(w, http.StatusNotFound, "no such request")
			return
		}
		s.writeRequestDetail(w, http.StatusOK, req)
	case (verb == "approve" || verb == "reject") && r.Method == http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		if verb == "approve" {
			s.adminRequestApprove(w, r, id)
		} else {
			s.adminRequestReject(w, r, id)
		}
	case verb == "" || verb == "approve" || verb == "reject":
		w.Header().Set("Allow", map[bool]string{true: "GET, HEAD", false: "POST"}[verb == ""])
		httpError(w, http.StatusMethodNotAllowed, "not with "+r.Method)
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) adminRequestsList(w http.ResponseWriter, r *http.Request) {
	rq := s.Store.Requests()
	q := r.URL.Query()
	state := q.Get("state")
	switch state {
	case "", store.RequestPending, store.RequestApproved, store.RequestRejected, store.RequestWithdrawn:
	default:
		httpError(w, http.StatusBadRequest, fmt.Sprintf("state %q is not pending, approved, rejected or withdrawn", state))
		return
	}
	if q.Get("count") == "1" {
		n, err := rq.CountPending()
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not count the requests")
			return
		}
		writeJSON(w, http.StatusOK, map[string]int{"pending": n})
		return
	}
	all, err := rq.List("", 0)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the requests")
		return
	}
	now := time.Now()
	v := adminRequestsView{Requests: []adminRequestRow{}, CooldownDays: int(s.applyCooldown() / (24 * time.Hour))}
	for _, req := range all {
		switch {
		case req.State == store.RequestPending:
			v.Pending++
			if v.OldestPending == nil || req.CreatedAt.Before(*v.OldestPending) {
				v.OldestPending = timePtr(req.CreatedAt)
			}
		case req.State != store.RequestWithdrawn && req.DecidedAt.After(now.Add(-7*24*time.Hour)):
			v.Decided7d++
			if req.State == store.RequestApproved {
				v.Approved7d++
			}
		}
		if state == "" || req.State == state {
			v.Requests = append(v.Requests, s.requestRow(req))
		}
	}
	writeJSON(w, http.StatusOK, v)
}

// requestRow is req with the person its way already names.
func (s *Server) requestRow(req store.AccessRequest) adminRequestRow {
	row := adminRequestRow{AccessRequest: req}
	if pid, err := s.Store.IdentityPrincipal(req.Kind, req.Subject); err == nil && pid != "" {
		row.Person = pid
		if t, err := s.Store.Trial(pid); err == nil && t != nil {
			row.Trial = true
		}
	}
	return row
}

func (s *Server) writeRequestDetail(w http.ResponseWriter, code int, req *store.AccessRequest) {
	d := adminRequestDetail{adminRequestRow: s.requestRow(*req), Earlier: []store.AccessRequest{}}
	// A refused sign-in is audited under the way it came by: gh:<id> for
	// GitHub, "<name> (<kind>)" for the others (admitPerson).
	actors := []string{d.Person}
	if n, err := strconv.ParseInt(req.Subject, 10, 64); err == nil && n > 0 && req.Kind == store.IdentityGitHub {
		actors = append(actors, githubPrincipal(n))
	}
	targets := []string{req.Display + " (" + req.Kind + ")", req.Subject + " (" + req.Kind + ")"}
	if ins, err := s.Store.HubSignins(actors, targets, 500); err == nil && len(ins) > 0 {
		d.Signins = requestSigninsView{Count: len(ins), Last: timePtr(ins[0].Created), First: timePtr(ins[len(ins)-1].Created)}
	}
	if d.Trial {
		if t, err := s.Store.Trial(d.Person); err == nil && t != nil {
			tv := &requestTrialView{State: t.State, StartedAt: t.StartedAt, PlacedAt: timePtr(t.PlacedAt),
				LastSeen: timePtr(t.LastSeen), ReclaimedAt: timePtr(t.ReclaimedAt), Ended: t.EndedReason}
			// Their time on a machine and lines sent (claude-fleet#4059).
			tv.Minutes = int(t.Used(time.Now()).Round(time.Minute) / time.Minute)
			msgs := t.Msgs
			tv.Messages = &msgs
			if t.State == store.TrialReclaimed && tv.Ended == "" {
				tv.Ended = "reclaimed"
			}
			d.TrialOf = tv
		}
		d.ConvoUntil = s.trialConvoUntil(d.Person)
	}
	if rs, err := s.Store.Requests().ByIdentity(req.Kind, req.Subject); err == nil {
		for _, o := range rs {
			if o.ID != req.ID {
				d.Earlier = append(d.Earlier, o)
			}
		}
	}
	writeJSON(w, code, d)
}

// trialConvoUntil is when pid's kept trial conversation is deleted: C12
// keeps it (hub_trial_convos.expires_at); until it lands there is none.
func (s *Server) trialConvoUntil(pid string) *time.Time { return nil }

// adminRequestApprove puts the request's person on the list — the road
// admitPerson takes for an invite (共同约定 8): the person its way already
// names, else gh:<id> for GitHub, else a new p:<uuid>; hub_users role user
// with a new member's defaults; the way hung on them. Approving one that is
// approved already runs the admission again (a retry after a failure half
// way) and decides nothing twice.
//
// The body may carry {"limits": "days=7,usd=20,sessions=1"} — or "off" for a
// full member — in place of fleet.apply.trial (claude-fleet T789); an empty
// body takes the setting.
func (s *Server) adminRequestApprove(w http.ResponseWriter, r *http.Request, id string) {
	var body struct {
		Limits string `json:"limits"`
	}
	if r.Body != nil {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			httpError(w, http.StatusBadRequest, `the body is empty or {"limits": "days=7,usd=20,sessions=1" | "off"}`)
			return
		}
	}
	if body.Limits != "" {
		if _, err := parseTrialTerms(body.Limits); err != nil {
			httpError(w, http.StatusBadRequest, "limits: "+err.Error())
			return
		}
	}
	now := time.Now()
	by := principalOf(r.Context())
	rq := s.Store.Requests()
	req, err := rq.Get(id)
	switch {
	case err != nil:
		httpError(w, http.StatusInternalServerError, "could not read the request")
		return
	case req == nil:
		httpError(w, http.StatusNotFound, "no such request")
		return
	case req.State != store.RequestPending && req.State != store.RequestApproved:
		httpError(w, http.StatusConflict, "the request is "+req.State+" already")
		return
	}
	target := req.Display + " (" + req.Kind + ")"
	if req.State == store.RequestPending {
		got, err := rq.Decide(id, store.RequestApproved, "", time.Time{}, by, now)
		if errors.Is(err, store.ErrRequestNotPending) {
			httpError(w, http.StatusConflict, "the request was decided meanwhile: "+got.State)
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, "could not record the decision")
			return
		}
		req = got
		_ = s.Store.HubAudit(by, "request.approve", target, "ok", req.ID, now)
	}
	// Only a newcomer starts with limits: an existing member's request
	// (another way in) changes none of theirs.
	newcomer := true
	if pre, err := s.Store.IdentityPrincipal(req.Kind, req.Subject); err == nil && pre != "" {
		if role, err := s.personRole(pre); err == nil && role != "" && role != roleTrial {
			newcomer = false
		}
	}
	pid, err := s.admitRequest(req, by, now)
	if err != nil {
		log.Printf("approve %s: %v", req.ID, err)
		_ = s.Store.HubAudit(by, "user.add", target, "error", req.ID+": "+err.Error(), now)
		httpError(w, http.StatusInternalServerError, "approved, but putting them on the list failed — approve again: "+err.Error())
		return
	}
	if !newcomer {
	} else if err := s.writeMemberLimits(pid, body.Limits, by, now); err != nil {
		log.Printf("approve %s: limits: %v", req.ID, err)
		httpError(w, http.StatusInternalServerError, "approved, but recording their limits failed — approve again: "+err.Error())
		return
	}
	s.notifyResult(req)
	s.writeRequestDetail(w, http.StatusOK, req)
}

// admitRequest puts req's person on the list; their principal.
func (s *Server) admitRequest(req *store.AccessRequest, by string, now time.Time) (string, error) {
	pid, err := s.Store.IdentityPrincipal(req.Kind, req.Subject)
	if err != nil {
		return "", err
	}
	var gid int64
	if req.Kind == store.IdentityGitHub {
		n, err := strconv.ParseInt(req.Subject, 10, 64)
		if err != nil || n <= 0 {
			return "", fmt.Errorf("GitHub request %s has no numeric ID: %q", req.ID, req.Subject)
		}
		gid = n
		if pid == "" {
			pid = githubPrincipal(gid)
		}
	}
	if pid == "" {
		if pid, err = newPersonPrincipal(); err != nil {
			return "", err
		}
	}
	target := req.Display + " (" + pid + ")"
	role, err := s.personRole(pid)
	if err != nil {
		return "", err
	}
	if role == "" || role == roleTrial {
		// A trial person becomes a member here (claude-fleet#4059).
		name := strings.TrimSpace(req.Display)
		if name == "" {
			name = req.Subject
		}
		row := store.HubUser{PrincipalID: pid, Login: name, Role: roleUser,
			AddedBy: "request " + req.ID + " by " + by, AddedAt: now}
		if _, isGH := githubIDOf(pid); isGH {
			row.GitHubID = gid
		}
		if err := s.Store.AdmitHubUser(row); err != nil {
			return "", err
		}
	}
	if err := s.Store.AddHubIdentity(store.HubIdentity{Kind: req.Kind, Subject: req.Subject, PrincipalID: pid,
		VerifiedAt: now, AddedBy: "request " + req.ID}); err != nil {
		return "", err
	}
	// Their trial turns over: the conversation goes on (claude-fleet#4059).
	s.convertTrial(pid, req.Display, by, now)
	// One who never had a trial gets the same subscriptions a converted
	// trial does (claude-fleet T789): in strict mode «no list» is none, and
	// their new home answered every turn with the proxy's 403.
	s.trialCredOnConvert(pid, by, now)
	_ = s.Store.HubAudit(by, "user.add", target, "ok", "as user, request "+req.ID, now)
	return pid, nil
}

// adminRequestReject turns the request down with reason, sent to the person
// as written, and a cooldown (days; absent = fleet.apply.cooldown_days, 0 =
// they may ask again at once).
func (s *Server) adminRequestReject(w http.ResponseWriter, r *http.Request, id string) {
	var body struct {
		Reason       string `json:"reason"`
		CooldownDays *int   `json:"cooldown_days"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, `the body must be {"reason": "...", "cooldown_days": N}`)
		return
	}
	reason := strings.TrimSpace(body.Reason)
	if reason == "" {
		httpError(w, http.StatusBadRequest, "a refusal says why — the reason is sent to the person")
		return
	}
	if utf8.RuneCountInString(reason) > requestReasonMax {
		httpError(w, http.StatusBadRequest, fmt.Sprintf("the reason is at most %d characters", requestReasonMax))
		return
	}
	cool := s.applyCooldown()
	if body.CooldownDays != nil {
		if *body.CooldownDays < 0 || *body.CooldownDays > requestCooldownMaxDays {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("cooldown_days is 0..%d", requestCooldownMaxDays))
			return
		}
		cool = time.Duration(*body.CooldownDays) * 24 * time.Hour
	}
	now := time.Now()
	var until time.Time
	if cool > 0 {
		until = now.Add(cool)
	}
	by := principalOf(r.Context())
	got, err := s.Store.Requests().Decide(id, store.RequestRejected, reason, until, by, now)
	switch {
	case errors.Is(err, store.ErrRequestNotFound):
		httpError(w, http.StatusNotFound, "no such request")
		return
	case errors.Is(err, store.ErrRequestNotPending):
		httpError(w, http.StatusConflict, "the request is "+got.State+" already")
		return
	case err != nil:
		httpError(w, http.StatusInternalServerError, "could not record the decision")
		return
	}
	detail := got.ID
	if !until.IsZero() {
		detail += " · again from " + until.UTC().Format("2006-01-02")
	}
	_ = s.Store.HubAudit(by, "request.reject", got.Display+" ("+got.Kind+")", "ok", detail, now)
	s.notifyResult(got)
	s.writeRequestDetail(w, http.StatusOK, got)
}
