package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The admin's feedback page (claude-fleet#3357, EPIC #3354 C3): every
// feedback in one table, and one opened — who sent it, from which machine and
// session, its attachments, its GitHub issue and the reply. The public issue
// never names the person (共同约定 5); this page is where an admin looks.
//
//	GET  /v1/admin/feedback                     ?state=received|filed|closed&before=<id>&limit=N
//	                                            → {feedback:[…], counts:{…}, next}
//	GET  /v1/admin/feedback/F12                 one, with its context and attachments
//	GET  /v1/admin/feedback/F12/attach/<name>   one attachment, as a download
//	POST /v1/admin/feedback/F12/duplicate       {of:"F3"}: closed, reply 「与 F3 重复」;
//	                                            its GitHub issue commented on and closed
//
// Every door is adminOnly; the page is /admin/feedback. No token is ever on
// the page, and an attachment is one the hub already held against the
// secret shapes (it refuses a feedback whose attachment carries one, C1).
// Off (no CCQUOTA_FLEET_FEEDBACK_DIR): none of it exists, and /v1/me lists
// no feedback page.
const (
	AdminFeedbackPath   = "/v1/admin/feedback"
	adminFeedbackPrefix = AdminFeedbackPath + "/"
	feedbackPageID      = "feedback"
	feedbackPagePath    = "/admin/feedback"
	feedbackPageFile    = "admin/feedback.html"
	feedbackPageSize    = 50
)

// repo is where a feedback's GitHub issue lives: the filer's (C2).
func (d *FeedbackDesk) repo() string {
	if d.GitHub != nil && d.GitHub.Repo != "" {
		return d.GitHub.Repo
	}
	return feedbackGHRepo
}

// closeIssue is 「标为重复」's GitHub half: the test seam, else the filer's
// App; nil = the hub cannot write GitHub.
func (d *FeedbackDesk) closeIssue() func(context.Context, int64, string) error {
	if d.CloseIssue != nil {
		return d.CloseIssue
	}
	if d.GitHub != nil {
		return d.GitHub.CloseIssue
	}
	return nil
}

// CloseIssue comments on one feedback issue and closes it as not planned,
// with a fresh installation token (the filer's App, claude-fleet#3356).
func (g *FeedbackGitHub) CloseIssue(ctx context.Context, number int64, comment string) error {
	tok, err := g.installationToken(ctx, time.Now())
	if err != nil {
		return err
	}
	repo := g.Repo
	if repo == "" {
		repo = feedbackGHRepo
	}
	path := "/repos/" + repo + "/issues/" + strconv.FormatInt(number, 10)
	if err := g.call(ctx, http.MethodPost, path+"/comments", "Bearer "+tok, map[string]any{"body": comment}, nil); err != nil {
		return err
	}
	return g.call(ctx, http.MethodPatch, path, "Bearer "+tok, map[string]any{"state": "closed", "state_reason": "not_planned"}, nil)
}

// feedbackRow is one row of the admin's list.
type feedbackRow struct {
	ID          string    `json:"id"`
	Text        string    `json:"text"`
	State       string    `json:"state"`
	Who         string    `json:"who"`
	Principal   string    `json:"principal,omitempty"`
	Login       string    `json:"login"`
	Host        string    `json:"host"`
	MachineKind string    `json:"machine_kind,omitempty"`
	Agent       string    `json:"agent,omitempty"`
	Attachments int       `json:"attachments"`
	GHNumber    int64     `json:"gh_number,omitempty"`
	GHURL       string    `json:"gh_url,omitempty"`
	Reply       string    `json:"reply,omitempty"`
	FiledAt     time.Time `json:"filed_at,omitzero"`
	ClosedAt    time.Time `json:"closed_at,omitzero"`
	RepliedAt   time.Time `json:"replied_at,omitzero"`
	CreatedAt   time.Time `json:"created_at"`
}

// feedbackDetail is one feedback opened: the row, the context its session
// filled in, and its attachments.
type feedbackDetail struct {
	feedbackRow
	EndpointID string            `json:"endpoint_id"`
	Ctx        map[string]string `json:"ctx"`
	Attach     []feedbackFile    `json:"attach"`
}

type feedbackFile struct {
	Name string `json:"name"`
	Size int    `json:"size"`
	URL  string `json:"url"`
}

func (s *Server) feedbackRowOf(f store.Feedback) (feedbackRow, map[string]string, []feedbackFile) {
	ctx := map[string]string{}
	_ = json.Unmarshal([]byte(f.Ctx), &ctx)
	var atts []feedbackAttach
	if f.Attach != "" {
		_ = json.Unmarshal([]byte(f.Attach), &atts)
	}
	num := store.FeedbackNumber(f.ID)
	files := make([]feedbackFile, 0, len(atts))
	for _, a := range atts {
		files = append(files, feedbackFile{Name: a.Name, Size: a.Size,
			URL: adminFeedbackPrefix + num + "/attach/" + a.Name})
	}
	who := f.Login
	if f.Principal != "" {
		who = s.personName(f.Principal)
	}
	row := feedbackRow{ID: num, Text: f.Text, State: f.State, Who: who, Principal: f.Principal,
		Login: f.Login, Host: f.Host, MachineKind: ctx["machine_kind"], Agent: ctx["agent"],
		Attachments: len(files), GHNumber: f.GHNumber, Reply: f.Reply,
		FiledAt: f.FiledAt, ClosedAt: f.ClosedAt, RepliedAt: f.RepliedAt, CreatedAt: f.CreatedAt}
	if f.GHNumber > 0 {
		row.GHURL = fmt.Sprintf("https://github.com/%s/issues/%d", s.Feedback.repo(), f.GHNumber)
	}
	return row, ctx, files
}

// parseFeedbackNumber reads F12 (or 12) as 12.
func parseFeedbackNumber(s string) (int64, bool) {
	s = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(s), "F"), "f")
	id, err := strconv.ParseInt(s, 10, 64)
	return id, err == nil && id > 0
}

// handleAdminFeedback serves the list and every door under it.
func (s *Server) handleAdminFeedback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.URL.Path == AdminFeedbackPath {
		s.adminFeedbackList(w, r)
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, adminFeedbackPrefix)
	num, tail, _ := strings.Cut(rest, "/")
	id, ok := parseFeedbackNumber(num)
	if !ok {
		httpError(w, http.StatusNotFound, "没有这条反馈")
		return
	}
	f, err := s.Store.FeedbackByID(id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if f == nil {
		httpError(w, http.StatusNotFound, "没有这条反馈："+store.FeedbackNumber(id))
		return
	}
	switch {
	case tail == "":
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			httpError(w, http.StatusMethodNotAllowed, "GET only")
			return
		}
		row, ctx, files := s.feedbackRowOf(*f)
		writeJSON(w, http.StatusOK, feedbackDetail{feedbackRow: row, EndpointID: f.EndpointID, Ctx: ctx, Attach: files})
	case strings.HasPrefix(tail, "attach/"):
		s.adminFeedbackAttach(w, r, *f, strings.TrimPrefix(tail, "attach/"))
	case tail == "duplicate":
		s.adminFeedbackDuplicate(w, r, *f)
	default:
		httpError(w, http.StatusNotFound, "no such feedback door")
	}
}

func (s *Server) adminFeedbackList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	q := r.URL.Query()
	state := q.Get("state")
	switch state {
	case "", "all":
		state = ""
	case store.FeedbackReceived, store.FeedbackFiled, store.FeedbackClosed:
	default:
		httpError(w, http.StatusBadRequest, "state is received, filed, closed or all")
		return
	}
	var before int64
	if b := q.Get("before"); b != "" {
		var ok bool
		if before, ok = parseFeedbackNumber(b); !ok {
			httpError(w, http.StatusBadRequest, "before is a feedback number")
			return
		}
	}
	limit := feedbackPageSize
	if l, err := strconv.Atoi(q.Get("limit")); err == nil && l > 0 && l <= 200 {
		limit = l
	}
	rows, err := s.Store.FeedbackPage(state, before, limit+1)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	next := ""
	if len(rows) > limit {
		rows = rows[:limit]
		next = store.FeedbackNumber(rows[limit-1].ID)
	}
	counts, err := s.Store.FeedbackCounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]feedbackRow, 0, len(rows))
	for _, f := range rows {
		row, _, _ := s.feedbackRowOf(f)
		out = append(out, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"feedback": out, "counts": counts, "next": next, "repo": s.Feedback.repo()})
}

// adminFeedbackAttach serves one attachment as a download: only a name the
// row lists, never a path, and never rendered by the browser.
func (s *Server) adminFeedbackAttach(w http.ResponseWriter, r *http.Request, f store.Feedback, name string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	_, _, files := s.feedbackRowOf(f)
	found := false
	for _, a := range files {
		found = found || a.Name == name
	}
	if !found || name != filepath.Base(name) {
		httpError(w, http.StatusNotFound, "这条反馈没有这个附件（附件 7 天后删）")
		return
	}
	fh, err := os.Open(filepath.Join(s.Feedback.Dir, store.FeedbackNumber(f.ID), name))
	if err != nil {
		httpError(w, http.StatusNotFound, "这个附件已经不在了")
		return
	}
	defer fh.Close()
	head := make([]byte, 512)
	n, _ := io.ReadFull(fh, head)
	ctype := "application/octet-stream"
	if utf8.Valid(head[:n]) && !strings.HasSuffix(name, ".gz") {
		ctype = "text/plain; charset=utf-8"
	}
	if _, err := fh.Seek(0, io.SeekStart); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "sandbox")
	if r.URL.Query().Get("inline") == "" {
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", store.FeedbackNumber(f.ID)+"-"+name))
	}
	_, _ = io.Copy(w, fh)
}

// adminFeedbackDuplicate closes f as a duplicate of another: its GitHub
// issue (when it has one and the hub can write there, C2) gets the comment
// and is closed first — a GitHub that refuses changes nothing here — then
// the row closes with the reply its person will get (C5 carries it).
func (s *Server) adminFeedbackDuplicate(w http.ResponseWriter, r *http.Request, f store.Feedback) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, `POST {"of":"F3"}`)
		return
	}
	var body struct {
		Of string `json:"of"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4<<10)).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, `body is {"of":"F3"}: `+err.Error())
		return
	}
	ofID, ok := parseFeedbackNumber(body.Of)
	if !ok || ofID == f.ID {
		httpError(w, http.StatusBadRequest, "写另一条反馈的号，例如 F3")
		return
	}
	of, err := s.Store.FeedbackByID(ofID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if of == nil {
		httpError(w, http.StatusBadRequest, "没有 "+store.FeedbackNumber(ofID)+" 这条反馈")
		return
	}
	if f.State == store.FeedbackClosed {
		httpError(w, http.StatusConflict, store.FeedbackNumber(f.ID)+" 已经关了")
		return
	}
	ofNum := store.FeedbackNumber(ofID)
	reply := "与 " + ofNum + " 重复"
	ghNote := ""
	if f.GHNumber > 0 {
		if closeIssue := s.Feedback.closeIssue(); closeIssue == nil {
			ghNote = "入口还不能写 GitHub — 单子 #" + strconv.FormatInt(f.GHNumber, 10) + " 请手动关"
		} else {
			comment := reply
			if of.GHNumber > 0 {
				comment += fmt.Sprintf("（#%d）", of.GHNumber)
			}
			ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
			err := closeIssue(ctx, f.GHNumber, comment)
			cancel()
			if err != nil {
				httpError(w, http.StatusBadGateway, "GitHub 没关成，这边什么都没改："+err.Error())
				return
			}
		}
	}
	now := s.Feedback.now()
	if _, err := s.Store.CloseFeedback(f.ID, reply, now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if s.Fleet {
		_ = s.Store.FleetAudit(actorOf(r), "feedback_duplicate", store.FeedbackNumber(f.ID), "OK", ofNum, now)
	}
	out := map[string]any{"id": store.FeedbackNumber(f.ID), "state": store.FeedbackClosed, "reply": reply}
	if ghNote != "" {
		out["note"] = ghNote
	}
	writeJSON(w, http.StatusOK, out)
}

