package api

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Debug tickets (claude-fleet#2891, EPIC #2889 C2). A computer whose sign-in
// failed is a stranger to the hub — no certificate, no session — and that is
// exactly when it most needs to send its diagnostics up. So the installer asks
// for a 24-hour ticket before any sign-in, with nothing in hand:
//
//	POST /v1/fleet/debug/ticket {fp, version, invite?}       anonymous / invited
//	POST /v1/fleet/debug/ticket {fp, version, cert, sig, ts} a signed-in computer:
//	                                                          the ticket is the person's
//	GET  /v1/fleet/debug/ticket  (with the ticket)            what it still may do today
//	GET  /v1/fleet/debug/tickets                              the admin's list
//	POST /v1/fleet/debug/tickets {github_login, hours?}       the admin's re-issue
//
// A ticket is `fdt1.<payload>.<hmac>` (base64url; the HMAC keyed with
// CCQUOTA_FLEET_DEBUG_KEY) whose payload is {id, fp, exp, quota, by}: only the
// computer whose install fingerprint it names (X-Fleet-FP), only until exp, only
// so many uses a day. An admin's re-issue names no fingerprint — it binds to the
// first computer that uses it. Every /v1/fleet/debug/* door that takes one goes
// through debugTicketAuth: `Authorization: FleetDebug <ticket>` + `X-Fleet-FP`;
// a refusal is 401 with one Chinese line saying how to get a new one.
//
// Issue is rate limited (≤ 5 an hour from one address, ≤ 60 an hour hub-wide);
// use is limited per ticket per day (uploads, diagnosis sessions) and hub-wide
// for sessions (the over-flow is C4's to queue for the person). Off — no
// CCQUOTA_FLEET_DEBUG_DIR — none of these routes exists (TestDebugOffAddsNothing).
const (
	DebugTicketPath  = "/v1/fleet/debug/ticket"
	DebugTicketsPath = "/v1/fleet/debug/tickets"

	// DebugSigNamespace is the ssh-keygen -Y namespace a signed-in computer
	// signs its ticket request under (the message is DebugTicketSigMessage).
	DebugSigNamespace = "fleet-debug@claude-fleet"

	debugTicketPrefix = "fdt1."
	debugTicketTTL    = 24 * time.Hour
	debugAdminMaxTTL  = 72 * time.Hour

	debugIssuePerIPHour = 5
	debugIssueAllHour   = 60

	debugUploadsPerDay  = 5
	debugSessionsPerDay = 3
	debugSessionsAllDay = 20
	debugMaxBundleBytes = 20 << 20

	// DebugUseUpload and DebugUseSession are the two kinds of use a ticket
	// is counted for (C3's upload, C4's diagnosis session).
	DebugUseUpload  = "upload"
	DebugUseSession = "session"
)

// DebugTicketSigMessage is what a signed-in computer signs to exchange its
// certificate for a ticket on its own name.
func DebugTicketSigMessage(ts int64, fp string) string {
	return fmt.Sprintf("fleet-debug %d ticket %s", ts, fp)
}

// DebugTickets is the feature's configuration: off when the Server holds nil.
type DebugTickets struct {
	// Dir is CCQUOTA_FLEET_DEBUG_DIR — where C4 keeps the bundles; its
	// presence is the switch.
	Dir string
	// Key is CCQUOTA_FLEET_DEBUG_KEY, the HMAC key tickets are signed with.
	Key []byte
	// Now replaces the clock in tests.
	Now func() time.Time

	// C4 (claude-fleet#2893) — the debug reports:
	// Login is CCQUOTA_FLEET_DEBUG_LOGIN, <machine>/<login>: where a
	// debugger session opens ("" = none opens; a report goes unfinished).
	Login string
	// Notify is CCQUOTA_FLEET_DEBUG_NOTIFY, <machine>/<login>: the one login
	// whose node may read the feed (the orchestrator's).
	Notify string
	// ShapesFile is conf/secret-shapes.list's path when the hub carries no
	// client pack (tests); "" = the pack's copy.
	ShapesFile string
	// Start replaces the debugger's start in tests: it returns the endpoint
	// the session opened on.
	Start func(ctx context.Context, rep store.DebugReport, seed string) (string, error)
}

func (d *DebugTickets) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

// DebugQuota is a ticket's daily allowance, carried in it.
type DebugQuota struct {
	Uploads  int   `json:"uploads"`
	Sessions int   `json:"sessions"`
	MaxBytes int64 `json:"max_bytes"`
}

func defaultDebugQuota() DebugQuota {
	return DebugQuota{Uploads: debugUploadsPerDay, Sessions: debugSessionsPerDay, MaxBytes: debugMaxBundleBytes}
}

// debugTicketPayload is what a ticket says.
type debugTicketPayload struct {
	ID    string     `json:"id"`
	FP    string     `json:"fp"`
	Exp   int64      `json:"exp"`
	Quota DebugQuota `json:"quota"`
	By    string     `json:"by"`
}

// DebugTicket is a ticket a request proved: its payload and its row.
type DebugTicket struct {
	debugTicketPayload
	Row *store.DebugTicket
	FP  string // the fingerprint it was used from (= the payload's, or the bound one)
	// Queued: a session use the ticket had room for, but the hub's day did
	// not — C4 queues it for the person instead of opening it.
	Queued bool
}

var debugFPRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (d *DebugTickets) sign(p debugTicketPayload) string {
	b, _ := json.Marshal(p)
	body := debugTicketPrefix + base64.RawURLEncoding.EncodeToString(b)
	m := hmac.New(sha256.New, d.Key)
	m.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// parse checks a ticket's signature and reads it; ok false = not one of ours
// (malformed, or a byte changed).
func (d *DebugTickets) parse(tok string) (debugTicketPayload, bool) {
	var p debugTicketPayload
	if !strings.HasPrefix(tok, debugTicketPrefix) {
		return p, false
	}
	i := strings.LastIndexByte(tok, '.')
	if i <= len(debugTicketPrefix) {
		return p, false
	}
	sig, err := base64.RawURLEncoding.DecodeString(tok[i+1:])
	if err != nil {
		return p, false
	}
	m := hmac.New(sha256.New, d.Key)
	m.Write([]byte(tok[:i]))
	if !hmac.Equal(sig, m.Sum(nil)) {
		return p, false
	}
	b, err := base64.RawURLEncoding.DecodeString(tok[len(debugTicketPrefix):i])
	if err != nil || json.Unmarshal(b, &p) != nil || p.ID == "" {
		return p, false
	}
	return p, true
}

// The one line every refusal ends with: how to get a new ticket.
const debugHowTo = "重装一次（同一条安装命令）会自动领一张新票；或请管理员运行 `fleet hub debug-ticket <你的 GitHub 名>`，把它打出的那一行粘贴运行。"

// debugRefuse answers a refusal as one plain line — `curl` in a POSIX sh
// script prints it as it is.
func debugRefuse(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, msg+"\n")
}

func (s *Server) debugAudit(actor, id, outcome string, at time.Time) {
	if id == "" {
		id = "-"
	}
	s.leaseAudit(actor, "debug_ticket", "ticket:"+id, outcome, at)
}

// debugClientIP is the address a request came from: the right-most public
// X-Forwarded-For entry (the one our ingress appended — anything left of it
// is the client's own say, and a private one is a replica forwarding), else
// the socket's peer.
func debugClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			ip := net.ParseIP(strings.TrimSpace(parts[i]))
			if ip != nil && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
				return ip.String()
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func debugDay(t time.Time) string { return t.UTC().Format("2006-01-02") }

// handleDebugTicket serves /v1/fleet/debug/ticket.
func (s *Server) handleDebugTicket(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodPost:
		s.issueDebugTicket(w, r)
	case http.MethodGet, http.MethodHead:
		s.debugTicketAuth("", func(w http.ResponseWriter, r *http.Request, t *DebugTicket) {
			uses, err := s.Store.DebugUses(t.ID, debugDay(s.Debug.now()))
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"id": t.ID, "by": t.By, "expires_at": time.Unix(t.Exp, 0).UTC(), "quota": t.Quota,
				"left": map[string]int{
					DebugUseUpload:  max(0, t.Quota.Uploads-uses[DebugUseUpload]),
					DebugUseSession: max(0, t.Quota.Sessions-uses[DebugUseSession]),
				},
			})
		})(w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "POST {fp, version, invite?} or GET with the ticket")
	}
}

// debugIssueRequest is the body of POST /v1/fleet/debug/ticket.
type debugIssueRequest struct {
	FP      string `json:"fp"`
	Version string `json:"version"`
	Invite  string `json:"invite,omitempty"`
	// A signed-in computer's certificate exchange.
	Cert string `json:"cert,omitempty"`
	Sig  string `json:"sig,omitempty"`
	TS   int64  `json:"ts,omitempty"`
}

func (s *Server) issueDebugTicket(w http.ResponseWriter, r *http.Request) {
	d := s.Debug
	now := d.now()
	var req debugIssueRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		debugRefuse(w, http.StatusBadRequest, "请求体要是 {fp, version, invite?}："+err.Error())
		return
	}
	req.FP = strings.ToLower(strings.TrimSpace(req.FP))
	if !debugFPRe.MatchString(req.FP) {
		debugRefuse(w, http.StatusBadRequest, "fp 要是这台电脑安装指纹的 SHA-256（64 位十六进制）")
		return
	}
	if len(req.Version) > 64 {
		req.Version = req.Version[:64]
	}
	ip := debugClientIP(r)
	by, owner := "anon", ""
	if req.Cert != "" {
		if dt := now.Sub(time.Unix(req.TS, 0)); dt > routesClockSkew || dt < -routesClockSkew {
			debugRefuse(w, http.StatusUnauthorized, "签名时间和入口的时钟差太多 — 检查这台电脑的时间")
			return
		}
		id, err := s.verifySSHRelayCert(req.Cert, req.Sig, DebugTicketSigMessage(req.TS, req.FP), DebugSigNamespace, now)
		if err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				debugRefuse(w, http.StatusUnauthorized, "登录证书没被认下（"+re.msg+"）— 不带证书再领一次即可")
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		by, owner = "cert:"+id.Principal, id.Principal
	} else if code := strings.TrimSpace(req.Invite); code != "" && validInviteCode(code) {
		if inv, err := s.Store.InviteByHash(inviteHash(code)); err == nil && inv != nil && inv.State(now) != store.InviteRevoked {
			by = "invite:" + inv.ID
		}
	}
	// the issue limits: one address, then the whole hub
	hourAgo := now.Add(-time.Hour)
	nIP, err1 := s.Store.CountDebugTickets(ip, hourAgo)
	nAll, err2 := s.Store.CountDebugTickets("", hourAgo)
	if err := errors.Join(err1, err2); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if nIP >= debugIssuePerIPHour || nAll >= debugIssueAllHour {
		scope := "这个网络出口"
		if nAll >= debugIssueAllHour {
			scope = "入口"
		}
		s.debugAudit(by, "", fmt.Sprintf("REFUSE 429 issue %s ip=%s", map[bool]string{true: "all", false: "ip"}[nAll >= debugIssueAllHour], ip), now)
		w.Header().Set("Retry-After", "3600")
		debugRefuse(w, http.StatusTooManyRequests, scope+"这一小时领的调试票太多了 — 一小时后再试，或请管理员补发一张。")
		return
	}
	tok, row, err := s.mintDebugTicket(req.FP, owner, by, ip, req.Version, debugTicketTTL, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ticket": tok, "id": row.ID, "by": row.IssuedBy, "expires_at": row.ExpiresAt})
}

// mintDebugTicket writes the row (retiring what it replaces) and signs the
// ticket. fp "" = an admin's re-issue, bound on its first use.
func (s *Server) mintDebugTicket(fp, owner, by, ip, version string, ttl time.Duration, now time.Time) (string, store.DebugTicket, error) {
	rid, err := randomToken(9)
	if err != nil {
		return "", store.DebugTicket{}, err
	}
	row := store.DebugTicket{ID: "dt_" + rid, Owner: owner, FP: fp, IssuedBy: by, IP: ip, Version: version,
		CreatedAt: now, ExpiresAt: now.Add(ttl).Truncate(time.Second)}
	retired, err := s.Store.IssueDebugTicket(row)
	if err != nil {
		return "", store.DebugTicket{}, err
	}
	tok := s.Debug.sign(debugTicketPayload{ID: row.ID, FP: fp, Exp: row.ExpiresAt.Unix(), Quota: defaultDebugQuota(), By: by})
	outcome := "ISSUE " + by
	if retired > 0 {
		outcome += fmt.Sprintf(" (retired %d)", retired)
	}
	s.debugAudit(by, row.ID, outcome, now)
	return tok, row, nil
}

// errDebugGlobalFull: the hub's diagnosis sessions for the day are spent —
// C4 queues the request for the person rather than refusing the ticket.
var errDebugGlobalFull = errors.New("the hub's diagnosis sessions for today are spent")

// debugRefusal is why a ticket was not admitted: the status and the one
// line the caller is answered with.
type debugRefusal struct {
	status int
	msg    string
}

// debugTicketAuth guards a /v1/fleet/debug/* door: the request must carry a
// good ticket for this computer, and — for kind "upload" / "session" — the
// ticket must still have a use of that kind today, which this takes. kind ""
// takes nothing. A refusal is answered here; next runs only when admitted.
func (s *Server) debugTicketAuth(kind string, next func(http.ResponseWriter, *http.Request, *DebugTicket)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		t, no, err := s.debugTicketCheck(r, kind)
		switch {
		case err != nil:
			httpError(w, http.StatusInternalServerError, err.Error())
		case no != nil:
			if no.status == http.StatusTooManyRequests {
				w.Header().Set("Retry-After", "3600")
			}
			debugRefuse(w, no.status, no.msg)
		default:
			next(w, r, t)
		}
	}
}

// debugTicketCheck is debugTicketAuth's judgement without the answer: the
// ticket the request proved, or why not (an error is the hub's own failure).
// C4's page door (/s/<id>) asks it too, and answers a refusal with a 404.
func (s *Server) debugTicketCheck(r *http.Request, kind string) (*DebugTicket, *debugRefusal, error) {
	d := s.Debug
	now := d.now()
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "FleetDebug ")
	tok = strings.TrimSpace(tok)
	if !ok || tok == "" {
		return nil, &debugRefusal{http.StatusUnauthorized, "没带调试票。" + debugHowTo}, nil
	}
	fp := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Fleet-FP")))
	if !debugFPRe.MatchString(fp) {
		return nil, &debugRefusal{http.StatusUnauthorized, "没带这台电脑的安装指纹（X-Fleet-FP）。" + debugHowTo}, nil
	}
	p, ok := d.parse(tok)
	if !ok {
		// not ours: logged, never audited — a stranger's garbage must not
		// be able to fill the audit table
		log.Printf("debug ticket: unreadable or forged ticket from %s", debugClientIP(r))
		return nil, &debugRefusal{http.StatusUnauthorized, "调试票无效（被改过，或不是这个入口发的）。" + debugHowTo}, nil
	}
	refuse := func(why, msg string) (*DebugTicket, *debugRefusal, error) {
		s.debugAudit(p.By, p.ID, "REFUSE 401 "+why, now)
		return nil, &debugRefusal{http.StatusUnauthorized, msg + debugHowTo}, nil
	}
	if now.Unix() >= p.Exp {
		return refuse("expired", "调试票已过期（"+time.Unix(p.Exp, 0).UTC().Format("2006-01-02 15:04 UTC")+" 到期）。")
	}
	row, err := s.Store.DebugTicketByID(p.ID)
	if err != nil {
		return nil, nil, err
	}
	if row == nil {
		return refuse("unknown", "入口查不到这张调试票。")
	}
	if !row.RevokedAt.IsZero() {
		return refuse("revoked", "这张调试票已被新票替换或作废 — 用最新的那张；没有的话，")
	}
	switch {
	case p.FP != "" && p.FP != fp, p.FP == "" && row.FP != "" && row.FP != fp:
		return refuse("fp", "这张调试票属于另一台电脑，不能在这台用。")
	case p.FP == "" && row.FP == "":
		bound, err := s.Store.BindDebugTicket(p.ID, fp, now)
		if err != nil {
			return nil, nil, err
		}
		if !bound { // another computer bound it a moment ago
			return refuse("fp", "这张调试票属于另一台电脑，不能在这台用。")
		}
		s.debugAudit(p.By, p.ID, "BIND "+fp[:12], now)
	}
	t := &DebugTicket{debugTicketPayload: p, Row: row, FP: fp}
	if kind != "" {
		if err := s.useDebugTicket(t, kind, now); err != nil {
			if errors.Is(err, store.ErrDebugQuota) {
				s.debugAudit(p.By, p.ID, "REFUSE 429 "+kind, now)
				return nil, &debugRefusal{http.StatusTooManyRequests, fmt.Sprintf("这张调试票今天的%s次数用完了（每天 %d 次）— 明天再试，或请管理员补发一张。", debugKindWord(kind), debugKindLimit(t.Quota, kind))}, nil
			}
			if errors.Is(err, errDebugGlobalFull) {
				t.Queued = true
				return t, nil, nil
			}
			return nil, nil, err
		}
	}
	return t, nil, nil
}

func debugKindWord(kind string) string {
	if kind == DebugUseSession {
		return "远端诊断"
	}
	return "上传"
}

func debugKindLimit(q DebugQuota, kind string) int {
	if kind == DebugUseSession {
		return q.Sessions
	}
	return q.Uploads
}

// useDebugTicket takes one use of kind from the ticket's day — and, for a
// session, from the hub's day too; a spent hub-wide count is
// errDebugGlobalFull, with the ticket's own use given back.
func (s *Server) useDebugTicket(t *DebugTicket, kind string, now time.Time) error {
	day := debugDay(now)
	if err := s.Store.UseDebug(t.ID, kind, day, debugKindLimit(t.Quota, kind)); err != nil {
		return err
	}
	if kind != DebugUseSession {
		return nil
	}
	if err := s.Store.UseDebug(store.DebugUseAll, kind, day, debugSessionsAllDay); err != nil {
		_ = s.Store.UnuseDebug(t.ID, kind, day)
		if errors.Is(err, store.ErrDebugQuota) {
			return errDebugGlobalFull
		}
		return err
	}
	return nil
}

// ── the admin's endpoint ─────────────────────────────────────────────────

// debugTicketView is one row of GET /v1/fleet/debug/tickets.
type debugTicketView struct {
	store.DebugTicket
	State string         `json:"state"`
	Uses  map[string]int `json:"uses_today"`
}

func debugTicketState(t store.DebugTicket, now time.Time) string {
	switch {
	case !t.RevokedAt.IsZero():
		return "revoked"
	case !now.Before(t.ExpiresAt):
		return "expired"
	case t.FP == "":
		return "unbound"
	}
	return "active"
}

func (s *Server) handleDebugTickets(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	now := s.Debug.now()
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		rows, err := s.Store.DebugTickets(now.Add(-7*24*time.Hour), 200)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		day := debugDay(now)
		out := make([]debugTicketView, 0, len(rows))
		for _, t := range rows {
			uses, _ := s.Store.DebugUses(t.ID, day)
			if len(t.FP) > 12 {
				t.FP = t.FP[:12]
			}
			out = append(out, debugTicketView{DebugTicket: t, State: debugTicketState(t, now), Uses: uses})
		}
		writeJSON(w, http.StatusOK, map[string]any{"tickets": out})
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		var req struct {
			GitHubLogin string  `json:"github_login"`
			Hours       float64 `json:"hours"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, `the body must be {"github_login": "<GitHub username>", "hours": 24}`)
			return
		}
		gl := strings.TrimPrefix(strings.TrimSpace(req.GitHubLogin), "@")
		if !githubLoginRE.MatchString(gl) {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not a GitHub username", gl))
			return
		}
		ttl := debugTicketTTL
		if req.Hours != 0 {
			ttl = time.Duration(req.Hours * float64(time.Hour))
		}
		if ttl < time.Hour || ttl > debugAdminMaxTTL {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("hours must be 1–%d", int(debugAdminMaxTTL.Hours())))
			return
		}
		tok, row, err := s.mintDebugTicket("", strings.ToLower(gl), "admin:"+actorOf(r), debugClientIP(r), "", ttl, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusCreated, map[string]any{
			"id": row.ID, "owner": row.Owner, "by": row.IssuedBy, "expires_at": row.ExpiresAt,
			"ticket": tok, "command": "fleet-debug ticket " + tok,
		})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}
