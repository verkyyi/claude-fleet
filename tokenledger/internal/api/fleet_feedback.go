package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Feedback (claude-fleet#3355, EPIC #3354 C1): a person on a managed machine
// types /fleet-feedback 一句话, their session's fleet-feedback.sh sends it here
// with the login's own node token, and the hub answers at once with the
// number they will know it by.
//
//	POST /v1/node/feedback        (node token)  {text, ctx{…}, login?}  or multipart:
//	                                            text=… ctx=<json> attach=@file …
//	                                            → {id:"F12", state:"received"}
//	GET  /v1/fleet/feedback/mine  (viewer)      the caller's own, newest first
//
// Who sent it is the hub's word, never the body's: the node token names the
// login (nodeEndpoint → nodeIdentity) and the login names the person
// (principalOnNode); a `login` in the body that is not the token's is refused.
// The words, the context and every attachment are held against
// conf/secret-shapes.list (the ONE table, 共同约定 4) and the team layer's
// value shapes: one hit and the whole feedback is refused with 422 — nothing
// is written. Limits (共同约定 6) ride the debug tickets' use counters
// (Store.UseDebug, kind "feedback"): 10 a person a day, 30 seconds apart, 200
// a day for the whole hub; past one, 429 with retry_after and one plain
// sentence. Attachments are kept in CCQUOTA_FLEET_FEEDBACK_DIR/F<id>/ for
// seven days; the row stays.
//
// Each feedback taken becomes one GitHub issue when the hub holds the App's
// credentials (fleet_feedback_github.go, claude-fleet#3356); what its closing
// says goes back to the sender's session (fleet_feedback_reply.go,
// claude-fleet#3359).
//
// Off (no CCQUOTA_FLEET_FEEDBACK_DIR): none of these routes exists.
const (
	NodeFeedbackPath   = "/v1/node/feedback"
	FeedbackMinePath   = "/v1/fleet/feedback/mine"
	feedbackUseKind    = "feedback"
	feedbackTextMax    = 2000
	feedbackCtxMax     = 120
	feedbackAttachMax  = 20 << 20
	feedbackAttachKeep = 7 * 24 * time.Hour
	feedbackPerDay     = 10
	feedbackAllDay     = 200
	feedbackGap        = 30 * time.Second
	feedbackTickEvery  = time.Hour
)

// FeedbackDesk is the feature's configuration; nil on the Server = off.
type FeedbackDesk struct {
	// Dir is CCQUOTA_FLEET_FEEDBACK_DIR — where attachments are kept; its
	// presence is the switch.
	Dir string
	// ShapesFile is conf/secret-shapes.list's path when the hub carries no
	// client pack (tests); "" = the pack's copy.
	ShapesFile string
	// Now replaces the clock in tests.
	Now func() time.Time
	// GitHub files each feedback as an issue (claude-fleet#3356,
	// fleet_feedback_github.go); nil = nothing is ever sent to GitHub.
	GitHub *FeedbackGitHub
	// CloseIssue comments on a feedback's GitHub issue and closes it (the
	// admin's 「标为重复」, claude-fleet#3357); nil = the desk's GitHub client
	// does it (C2), and with neither only the row is closed. A test seam.
	CloseIssue func(ctx context.Context, number int64, comment string) error
	// ReplyWait replaces how long a reply's send waits for its node's verdict
	// (fleet_feedback_reply.go) in tests.
	ReplyWait time.Duration

	kickOnce sync.Once
	kickCh   chan struct{}
}

func (d *FeedbackDesk) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

// feedbackCtxKeys are the context fields a session fills in (共同约定 3);
// anything else in ctx is dropped.
var feedbackCtxKeys = []string{"fleet_version", "agent", "machine_kind", "worker_id", "cc_session", "window"}

// feedbackNameRe is what an attachment's stored name may hold.
var feedbackNameRe = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

type feedbackAttach struct {
	Name string `json:"name"`
	Size int    `json:"size"`
	data []byte
}

// feedbackRefusal is a 4xx answer in the shape fleet-feedback.sh reads.
func feedbackRefusal(w http.ResponseWriter, status int, code, msg string, retry int) {
	body := map[string]any{"error": code, "message": msg}
	if retry > 0 {
		body["retry_after"] = retry
		w.Header().Set("Retry-After", strconv.Itoa(retry))
	}
	writeJSON(w, status, body)
}

// handleNodeFeedback serves POST /v1/node/feedback.
func (s *Server) handleNodeFeedback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST {text, ctx} or multipart text/ctx/attach")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	d := s.Feedback
	now := d.now()
	r.Body = http.MaxBytesReader(w, r.Body, feedbackAttachMax+(1<<20))
	text, rawCtx, login, atts, status, msg := readFeedbackRequest(r)
	if status != 0 {
		code := "bad_request"
		if status == http.StatusRequestEntityTooLarge {
			code = "too_large"
		}
		feedbackRefusal(w, status, code, msg, 0)
		return
	}
	host, osUser := s.nodeIdentity(ep)
	if login != "" && login != osUser {
		feedbackRefusal(w, http.StatusForbidden, "WRONG_LOGIN", fmt.Sprintf("这个令牌是 %s 的，不能替 %s 发反馈。", osUser, login), 0)
		return
	}
	text = strings.TrimSpace(strings.ToValidUTF8(text, ""))
	if text == "" {
		feedbackRefusal(w, http.StatusBadRequest, "bad_request", "反馈是空的：写一句话再发。", 0)
		return
	}
	if utf8.RuneCountInString(text) > feedbackTextMax {
		feedbackRefusal(w, http.StatusBadRequest, "bad_request", fmt.Sprintf("一条反馈最多 %d 个字。", feedbackTextMax), 0)
		return
	}
	ctx, msg := feedbackContext(rawCtx)
	if msg != "" {
		feedbackRefusal(w, http.StatusBadRequest, "bad_request", msg, 0)
		return
	}

	// the credential check, before anything is counted or kept
	shapes, err := loadSecretShapes(d.ShapesFile)
	if err != nil {
		log.Printf("feedback: %v", err)
		feedbackRefusal(w, http.StatusServiceUnavailable, "unchecked", "入口现在查不了反馈里有没有密码，先不收 — 请稍后再发。", 0)
		return
	}
	if where, hit := feedbackSecret(shapes, text, ctx, atts); hit != "" {
		feedbackRefusal(w, http.StatusUnprocessableEntity, "secret",
			fmt.Sprintf("%s里有像 %s 的东西（密码或令牌）— 这条反馈入口没收，什么都没留下；遮掉再发。", where, hit), 0)
		return
	}

	// who, then the limits
	principal, err := s.principalOnNode(ep.ID, host, osUser)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	key := "fb:" + principal
	if principal == "" {
		key = "fb:ep:" + ep.ID
	}
	if left, err := s.Store.TakeFeedbackGap(key, now, feedbackGap); err != nil {
		if errors.Is(err, store.ErrFeedbackGap) {
			feedbackRefusal(w, http.StatusTooManyRequests, "rate_limited",
				fmt.Sprintf("两条反馈要隔 %d 秒 — %d 秒后再发。", int(feedbackGap.Seconds()), left), left)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	day := debugDay(now)
	untilTomorrow := int(now.UTC().Truncate(24*time.Hour).Add(24*time.Hour).Sub(now).Seconds()) + 1
	if err := s.Store.UseDebug(key, feedbackUseKind, day, feedbackPerDay); err != nil {
		if errors.Is(err, store.ErrDebugQuota) {
			feedbackRefusal(w, http.StatusTooManyRequests, "rate_limited",
				fmt.Sprintf("谢谢 — 今天已经收到你 %d 条反馈了，明天（UTC 0 点后）再发；急事请直接找管理员。", feedbackPerDay), untilTomorrow)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.Store.UseDebug(store.DebugUseAll, feedbackUseKind, day, feedbackAllDay); err != nil {
		_ = s.Store.UnuseDebug(key, feedbackUseKind, day)
		if errors.Is(err, store.ErrDebugQuota) {
			feedbackRefusal(w, http.StatusTooManyRequests, "rate_limited",
				"入口今天收的反馈满了 — 明天（UTC 0 点后）再发；急事请直接找管理员。", untilTomorrow)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	giveBack := func() {
		_ = s.Store.UnuseDebug(key, feedbackUseKind, day)
		_ = s.Store.UnuseDebug(store.DebugUseAll, feedbackUseKind, day)
	}

	ctxJSON, _ := json.Marshal(ctx)
	id, err := s.Store.InsertFeedback(store.Feedback{Principal: principal, EndpointID: ep.ID, Login: osUser, Host: host,
		Ctx: string(ctxJSON), Text: text, CreatedAt: now})
	if err != nil {
		giveBack()
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	num := store.FeedbackNumber(id)
	if len(atts) > 0 {
		dir := filepath.Join(d.Dir, num)
		werr := os.MkdirAll(dir, 0o700)
		for _, a := range atts {
			if werr == nil {
				werr = os.WriteFile(filepath.Join(dir, a.Name), a.data, 0o600)
			}
		}
		list, _ := json.Marshal(atts)
		if werr == nil {
			werr = s.Store.SetFeedbackAttach(id, string(list))
		}
		if werr != nil {
			// the words are kept; the attachments are not — say so, never 500 a
			// feedback that has its number
			_ = os.RemoveAll(dir)
			log.Printf("feedback %s: attachments not kept: %v", num, werr)
			writeJSON(w, http.StatusOK, map[string]any{"id": num, "state": store.FeedbackReceived,
				"note": "附件没存下（入口的存储出错），原话已收到。"})
			d.kickFeedbackFiler()
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": num, "state": store.FeedbackReceived})
	d.kickFeedbackFiler()
}

// readFeedbackRequest reads the JSON or multipart body. A non-zero status is
// the refusal, msg its sentence.
func readFeedbackRequest(r *http.Request) (text string, rawCtx json.RawMessage, login string, atts []feedbackAttach, status int, msg string) {
	tooBig := func(err error) bool {
		var mbe *http.MaxBytesError
		return errors.As(err, &mbe)
	}
	bigMsg := fmt.Sprintf("附件一共超过 %d MB，入口不收。", feedbackAttachMax>>20)
	mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mt != "multipart/form-data" {
		var body struct {
			Text  string          `json:"text"`
			Ctx   json.RawMessage `json:"ctx"`
			Login string          `json:"login"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			if tooBig(err) {
				return "", nil, "", nil, http.StatusRequestEntityTooLarge, bigMsg
			}
			return "", nil, "", nil, http.StatusBadRequest, "请求体要是 {text, ctx}：" + err.Error()
		}
		return body.Text, body.Ctx, body.Login, nil, 0, ""
	}
	mr, err := r.MultipartReader()
	if err != nil {
		return "", nil, "", nil, http.StatusBadRequest, "multipart 读不了：" + err.Error()
	}
	total := 0
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			if tooBig(err) {
				return "", nil, "", nil, http.StatusRequestEntityTooLarge, bigMsg
			}
			return "", nil, "", nil, http.StatusBadRequest, "multipart 没送完：" + err.Error()
		}
		switch part.FormName() {
		case "text":
			b, _ := io.ReadAll(io.LimitReader(part, 64<<10))
			text = string(b)
		case "ctx":
			b, _ := io.ReadAll(io.LimitReader(part, 16<<10))
			rawCtx = b
		case "login":
			b, _ := io.ReadAll(io.LimitReader(part, 256))
			login = strings.TrimSpace(string(b))
		case "attach":
			b, err := io.ReadAll(io.LimitReader(part, feedbackAttachMax+1-int64(total)))
			if err != nil {
				if tooBig(err) {
					return "", nil, "", nil, http.StatusRequestEntityTooLarge, bigMsg
				}
				return "", nil, "", nil, http.StatusBadRequest, "附件没送完：" + err.Error()
			}
			total += len(b)
			if total > feedbackAttachMax {
				return "", nil, "", nil, http.StatusRequestEntityTooLarge, bigMsg
			}
			name := feedbackNameRe.ReplaceAllString(filepath.Base(part.FileName()), "_")
			name = strings.TrimLeft(name, ".")
			if name == "" || name == "_" {
				name = "attach"
			}
			name = fmt.Sprintf("%d-%s", len(atts)+1, clipRunes(name, 80))
			atts = append(atts, feedbackAttach{Name: name, Size: len(b), data: b})
		}
		_ = part.Close()
	}
	return text, rawCtx, login, atts, 0, ""
}

// feedbackContext keeps the known context fields, each one short line.
func feedbackContext(raw json.RawMessage) (map[string]string, string) {
	out := map[string]string{}
	if len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return out, ""
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, "ctx 要是一个 JSON 对象：" + err.Error()
	}
	for _, k := range feedbackCtxKeys {
		v, ok := in[k]
		if !ok || v == nil {
			continue
		}
		var sv string
		switch t := v.(type) {
		case string:
			sv = t
		case float64, bool:
			sv = fmt.Sprint(t)
		default:
			return nil, "ctx." + k + " 要是一个字符串"
		}
		sv = strings.TrimSpace(strings.ToValidUTF8(sv, ""))
		if strings.ContainsAny(sv, "\r\n\t") || utf8.RuneCountInString(sv) > feedbackCtxMax {
			return nil, fmt.Sprintf("ctx.%s 要是一行、最多 %d 个字", k, feedbackCtxMax)
		}
		if sv != "" {
			out[k] = sv
		}
	}
	return out, ""
}

// feedbackSecret names where a credential shape hit and which one; "" = clean.
func feedbackSecret(shapes []debugShape, text string, ctx map[string]string, atts []feedbackAttach) (where, hit string) {
	check := func(s string) string {
		if h := debugShapeHit(shapes, s); h != "" {
			return h
		}
		if secretIn("text", s) != "" {
			return "token"
		}
		return ""
	}
	if h := check(text); h != "" {
		return "原话", h
	}
	for _, k := range feedbackCtxKeys {
		if h := check(ctx[k]); h != "" {
			return "附带的 " + k, h
		}
	}
	for _, a := range atts {
		body := a.data
		if len(body) > 2 && body[0] == 0x1f && body[1] == 0x8b {
			if zr, err := gzip.NewReader(bytes.NewReader(body)); err == nil {
				if b, err := io.ReadAll(io.LimitReader(zr, 64<<20)); err == nil {
					body = b
				}
			}
		}
		if h := check(string(body)); h != "" {
			return "附件 " + a.Name + " ", h
		}
	}
	return "", ""
}

// feedbackMine is one row of GET /v1/fleet/feedback/mine.
type feedbackMine struct {
	ID        string    `json:"id"`
	Text      string    `json:"text"`
	State     string    `json:"state"`
	GHNumber  int64     `json:"gh_number,omitempty"`
	Reply     string    `json:"reply,omitempty"`
	RepliedAt time.Time `json:"replied_at,omitzero"`
	CreatedAt time.Time `json:"created_at"`
}

// handleFeedbackMine serves GET /v1/fleet/feedback/mine: always the viewer's
// own, whoever asks; the operator's door is nobody and reads an empty list.
func (s *Server) handleFeedbackMine(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	out := []feedbackMine{}
	if p := principalOf(r.Context()); p != "" {
		rows, err := s.Store.FeedbackFor(p, 200)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		for _, f := range rows {
			out = append(out, feedbackMine{ID: store.FeedbackNumber(f.ID), Text: f.Text, State: f.State,
				GHNumber: f.GHNumber, Reply: f.Reply, RepliedAt: f.RepliedAt, CreatedAt: f.CreatedAt})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"feedback": out})
}

// RunFeedback deletes attachments past seven days, hourly, sends each closed
// feedback's reply to its person (fleet_feedback_reply.go) and — with the
// GitHub App configured — runs the filer (fleet_feedback_github.go). Off
// (s.Feedback nil): returns at once.
func (s *Server) RunFeedback(ctx context.Context) {
	if s.Feedback == nil {
		return
	}
	if s.Feedback.GitHub != nil {
		go s.runFeedbackFiler(ctx)
	}
	go s.runFeedbackReplies(ctx)
	t := time.NewTicker(feedbackTickEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if s.Elector != nil && !s.Elector.Leader(ctx, "feedback") {
				continue
			}
			s.feedbackPrune(s.Feedback.now())
		}
	}
}

func (s *Server) feedbackPrune(now time.Time) {
	rows, err := s.Store.FeedbackAttachedBefore(now.Add(-feedbackAttachKeep))
	if err != nil {
		log.Printf("feedback prune: %v", err)
		return
	}
	for _, f := range rows {
		if err := os.RemoveAll(filepath.Join(s.Feedback.Dir, store.FeedbackNumber(f.ID))); err != nil {
			log.Printf("feedback prune %s: %v", store.FeedbackNumber(f.ID), err)
			continue
		}
		_ = s.Store.SetFeedbackAttach(f.ID, "")
	}
}
