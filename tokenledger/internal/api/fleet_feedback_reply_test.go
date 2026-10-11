package api

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// replyHarness is two connected write nodes (m5 and m4, login verk on both),
// a person who owns verk on m5, and a feedback desk pointed at a fake GitHub.
type replyHarness struct {
	h      *harness
	m5, m4 *writeNode
	f5, f4 control.Fleet
	p      *store.Principal
	gh     *fakeIssuesGitHub
}

func newReplyHarness(t *testing.T) *replyHarness {
	t.Helper()
	h, m5, m4, f5, f4 := twoNodes(t)
	p, err := h.srv.Store.AdoptPrincipal("gh:1005", "verk", "Verk", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m5", time.Now()); err != nil {
		t.Fatal(err)
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	for name, v := range map[string][]byte{"app-id": []byte(fakeAppID), "installation-id": []byte(fakeInstID), "private-key": keyPEM} {
		if err := os.WriteFile(filepath.Join(dir, name), v, 0o400); err != nil {
			t.Fatal(err)
		}
	}
	g, err := LoadFeedbackGitHub(dir, "o/r")
	if err != nil || g == nil {
		t.Fatalf("load: %v %v", g, err)
	}
	gh := &fakeIssuesGitHub{t: t, pub: &key.PublicKey, comments: map[int64][]map[string]any{}}
	ts := httptest.NewServer(gh)
	t.Cleanup(ts.Close)
	g.API, g.Client = ts.URL, &http.Client{Timeout: 2 * time.Second}
	h.srv.Feedback = &FeedbackDesk{Dir: t.TempDir(), GitHub: g, ReplyWait: time.Second}
	// every write answered at once: succeeded, unless replyAnswer says otherwise
	for _, n := range []*writeNode{m5, m4} {
		n.setAnswer(replyAnswer(nil))
	}
	return &replyHarness{h: h, m5: m5, m4: m4, f5: f5, f4: f4, p: p, gh: gh}
}

// replyAnswer answers a worker_message succeeded, or failed NOT_FOUND for a
// worker_id in gone.
func replyAnswer(gone map[string]bool) func(env map[string]any) (any, *control.Error) {
	return func(env map[string]any) (any, *control.Error) {
		params, _ := env["params"].(map[string]any)
		out := map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"], "action": env["action"],
			"status": "succeeded", "result": map[string]any{"channel": "direct"}}
		if gone[asString(params["worker_id"])] {
			out["status"] = "failed"
			out["result"] = map[string]any{"error": map[string]any{"code": "NOT_FOUND", "message": "No live session"}}
		}
		return out, nil
	}
}

func workerIDOf(f control.Fleet, issue int) string {
	return fleetid.WorkerID(f.FleetID, fleetid.WorkerKey(issue, false, "", ""))
}

// filed puts a feedback from m5's verk on GitHub as issue number, sent from
// the session workerID.
func (r *replyHarness) filed(t *testing.T, number int64, workerID string) store.Feedback {
	t.Helper()
	ctx, _ := json.Marshal(map[string]string{"worker_id": workerID, "agent": "claude"})
	id, err := r.h.srv.Store.InsertFeedback(store.Feedback{Principal: r.p.ID, EndpointID: "ep_m5", Login: "verk", Host: "m5",
		Ctx: string(ctx), Text: "侧栏不刷新", CreatedAt: time.Now().Add(-time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.h.srv.Store.SetFeedbackFiled(id, number, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	f, _ := r.h.srv.Store.FeedbackByID(id)
	r.gh.mu.Lock()
	r.gh.issues = append(r.gh.issues, map[string]any{"number": number, "state": "open", "labels": []string{"feedback"},
		"body": feedbackIssueBody(*f)})
	r.gh.mu.Unlock()
	return *f
}

// close closes issue number on the fake GitHub with these comments.
func (r *replyHarness) close(number int64, reason string, at time.Time, comments ...map[string]any) {
	r.gh.mu.Lock()
	defer r.gh.mu.Unlock()
	for _, is := range r.gh.issues {
		if is["number"] == number {
			is["state"], is["state_reason"], is["closed_at"] = "closed", reason, at.UTC().Format(time.RFC3339)
		}
	}
	r.gh.comments[number] = append(r.gh.comments[number], comments...)
}

func ghCommentAt(body string, at time.Time) map[string]any {
	return map[string]any{"body": body, "created_at": at.UTC().Format(time.RFC3339), "user": map[string]any{"type": "User"}}
}

func (r *replyHarness) row(t *testing.T, id int64) store.Feedback {
	t.Helper()
	f, err := r.h.srv.Store.FeedbackByID(id)
	if err != nil || f == nil {
		t.Fatalf("row %d: %v", id, err)
	}
	return *f
}

func messages(n *writeNode) []map[string]any {
	n.mu.Lock()
	defer n.mu.Unlock()
	out := []map[string]any{}
	for _, w := range n.writes {
		if w["action"] == "worker_message" {
			out = append(out, w["params"].(map[string]any))
		}
	}
	return out
}

// Closing the issue sends what the closing said to the session that sent the
// feedback — once: another poll, another pass, the issue listed again, change
// nothing.
func TestFeedbackReplyClosedSendsOnce(t *testing.T) {
	r := newReplyHarness(t)
	orig := workerIDOf(r.f5, 1)
	f := r.filed(t, 9000, orig)
	closedAt := time.Now().Add(-2 * time.Minute)
	r.close(9000, "completed", closedAt,
		ghCommentAt("先看一下 <!-- fleet:no-relay -->", closedAt.Add(-time.Hour)),
		ghCommentAt("<!-- fleet:no-relay -->修好了：侧栏每 2 秒刷一次。\n\n---\n<sub>fleet · orchestrator</sub>\n<!-- fleet:from orchestrator -->", closedAt))
	ctx := context.Background()
	r.h.srv.feedbackPollCloses(ctx, time.Now())

	row := r.row(t, f.ID)
	if row.State != store.FeedbackClosed || row.Reply != "修好了：侧栏每 2 秒刷一次。" || row.ClosedAt.IsZero() {
		t.Fatalf("closed row: %+v", row)
	}
	msgs := messages(r.m5)
	if len(msgs) != 1 || row.RepliedAt.IsZero() {
		t.Fatalf("messages %v, replied_at %v", msgs, row.RepliedAt)
	}
	want := "[fleet-feedback] 你的反馈 F1 有回音了（o/r#9000）：修好了：侧栏每 2 秒刷一次。"
	if msgs[0]["worker_id"] != orig || msgs[0]["text"] != want {
		t.Fatalf("message: %v\nwant text %q to %s", msgs[0], want, orig)
	}
	if o, err := r.h.srv.Store.FleetOperationByIdem(feedbackActor, "fb-F1"); err != nil || o.Status != "succeeded" {
		t.Fatalf("journal fb-F1: %+v %v", o, err)
	}
	// again: nothing more is sent; reopened and closed again: still nothing
	r.h.srv.feedbackPollCloses(ctx, time.Now())
	r.h.srv.feedbackSendReplies(ctx, time.Now())
	r.close(9000, "completed", time.Now(), ghCommentAt("/reply 又修了一次", time.Now()))
	r.h.srv.feedbackPollCloses(ctx, time.Now())
	r.h.srv.feedbackSendReplies(ctx, time.Now())
	if n := len(messages(r.m5)) + len(messages(r.m4)); n != 1 {
		t.Fatalf("a reply was sent %d times", n)
	}
	if got := r.row(t, f.ID).Reply; got != row.Reply {
		t.Fatalf("a second close rewrote the reply: %q", got)
	}
}

// The session that sent it is gone ⇒ the reply waits; it goes, once, to the
// person's next session when one is up — on another of their machines too.
func TestFeedbackReplyWaitsForNextSession(t *testing.T) {
	r := newReplyHarness(t)
	gone := workerIDOf(r.f5, 77) // not in any inventory
	f := r.filed(t, 9000, gone)
	// nobody's session on m5: its fleet empties
	empty5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet")
	r.m5.beatLoad("m5", "verk", machineA, 1, 0, empty5)
	waitFor(t, 3*time.Second, "m5's fleet empty", func() bool {
		fr, err := r.h.srv.Store.Fleet(r.f5.FleetID)
		return err == nil && !strings.Contains(fr.WorkersJSON, "worker_id")
	})
	r.close(9000, "completed", time.Now().Add(-time.Minute))
	ctx := context.Background()
	r.h.srv.feedbackPollCloses(ctx, time.Now())
	row := r.row(t, f.ID)
	if row.State != store.FeedbackClosed || row.Reply != "已处理，见单子 #9000。" {
		t.Fatalf("closed with no comment: %+v", row)
	}
	// m4's sessions are verk's, but m4 is not this person's machine (yet)
	if n := len(messages(r.m5)) + len(messages(r.m4)); n != 0 || !row.RepliedAt.IsZero() {
		t.Fatalf("sent with no session of theirs up: %d", n)
	}
	// the person's account on m4: their session there gets it, once
	if err := r.h.srv.Store.AdoptAccount(r.p, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	r.h.srv.feedbackSendReplies(ctx, time.Now())
	r.h.srv.feedbackSendReplies(ctx, time.Now())
	msgs := messages(r.m4)
	if len(msgs) != 1 || msgs[0]["worker_id"] != workerIDOf(r.f4, 2) || !strings.Contains(asString(msgs[0]["text"]), "F1 有回音了") {
		t.Fatalf("m4 messages: %v", msgs)
	}
	if r.row(t, f.ID).RepliedAt.IsZero() {
		t.Fatal("replied_at not written")
	}
}

// A session that refuses (the node says it is gone) ⇒ the next one; the reply
// still lands once.
func TestFeedbackReplyFailedSessionTriesNext(t *testing.T) {
	r := newReplyHarness(t)
	orig := workerIDOf(r.f5, 1)
	two := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1, 3)
	r.m5.beatLoad("m5", "verk", machineA, 1, 2, two)
	waitFor(t, 3*time.Second, "m5 lists issue-3", func() bool {
		fr, err := r.h.srv.Store.Fleet(r.f5.FleetID)
		return err == nil && strings.Contains(fr.WorkersJSON, "issue-3")
	})
	r.m5.setAnswer(replyAnswer(map[string]bool{orig: true}))
	f := r.filed(t, 9000, orig)
	r.close(9000, "duplicate", time.Now().Add(-time.Minute))
	r.h.srv.feedbackPollCloses(context.Background(), time.Now())
	msgs := messages(r.m5)
	if len(msgs) != 2 || msgs[0]["worker_id"] != orig || msgs[1]["worker_id"] != workerIDOf(two, 3) {
		t.Fatalf("messages: %v", msgs)
	}
	row := r.row(t, f.ID)
	if row.RepliedAt.IsZero() || !strings.Contains(row.Reply, "同一件") {
		t.Fatalf("row: %+v", row)
	}
	r.h.srv.feedbackSendReplies(context.Background(), time.Now())
	if len(messages(r.m5)) != 2 {
		t.Fatal("sent again after it landed")
	}
}

// Thirty days after the close a reply nobody could take is never sent.
func TestFeedbackReplyExpiresAfter30Days(t *testing.T) {
	r := newReplyHarness(t)
	f := r.filed(t, 9000, workerIDOf(r.f5, 1))
	if ok, err := r.h.srv.Store.CloseFeedback(f.ID, "旧的回音", time.Now().Add(-31*24*time.Hour)); !ok || err != nil {
		t.Fatalf("close: %v %v", ok, err)
	}
	r.h.srv.feedbackSendReplies(context.Background(), time.Now())
	if n := len(messages(r.m5)); n != 0 || !r.row(t, f.ID).RepliedAt.IsZero() {
		t.Fatalf("an expired reply was sent (%d)", n)
	}
}

// Only the feedback desk may send the [fleet-feedback] prefix: the node hands
// it to any session's inbox.
func TestFeedbackReplyPrefixIsTheDesks(t *testing.T) {
	r := newReplyHarness(t)
	e := postFleet(t, r.h, "worker_message", map[string]any{"worker_id": workerIDOf(r.f5, 1),
		"text": "[fleet-feedback] 你的反馈 F9 有回音了", "idempotency_key": "spoof"}, 403)["error"].(map[string]any)
	if e["code"] != "FORBIDDEN" || len(messages(r.m5)) != 0 {
		t.Fatalf("spoofed prefix: %v", e)
	}
}

// No GitHub App ⇒ nothing is polled and nothing is sent.
func TestFeedbackReplyOffSendsNothing(t *testing.T) {
	r := newReplyHarness(t)
	f := r.filed(t, 9000, workerIDOf(r.f5, 1))
	r.close(9000, "completed", time.Now())
	r.gh.mu.Lock()
	r.gh.calls = nil
	r.gh.mu.Unlock()
	r.h.srv.Feedback.GitHub = nil
	r.h.srv.feedbackPollCloses(context.Background(), time.Now())
	r.h.srv.feedbackSendReplies(context.Background(), time.Now())
	if c, _ := r.gh.snapshot(); len(c) != 0 || len(messages(r.m5)) != 0 || r.row(t, f.ID).State != store.FeedbackFiled {
		t.Fatalf("off: GitHub %v, messages %v", c, messages(r.m5))
	}
}

// What a closed issue says back.
func TestFeedbackReplyOf(t *testing.T) {
	at := time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)
	is := ghClosedIssue{Number: 42, ClosedAt: at}
	c := func(body string, d time.Duration) ghComment {
		var g ghComment
		g.Body, g.CreatedAt, g.User.Type = body, at.Add(d), "User"
		return g
	}
	cases := []struct {
		name     string
		reason   string
		comments []ghComment
		want     string
	}{
		{"/reply wins, whenever", "", []ghComment{c("/reply 已经改好\n\n细节见 PR", -3*time.Hour), c("关了", 0)}, "已经改好"},
		{"the closing comment", "", []ghComment{c("早先的讨论", -time.Hour), c("修好了。\r\n\r\n第二段", 30*time.Second)}, "修好了。"},
		{"nothing said", "", []ghComment{c("早先的讨论", -time.Hour)}, "已处理，见单子 #42。"},
		{"duplicate", "duplicate", nil, "这件事和另一张单是同一件，已在那边处理（见单子 #42）。"},
		{"a bot's is skipped", "", []ghComment{func() ghComment { g := c("bot says", 0); g.User.Type = "Bot"; return g }()}, "已处理，见单子 #42。"},
		{"control characters dropped", "", []ghComment{c("好\x1b[31m了", 0)}, "好[31m了"},
	}
	for _, tc := range cases {
		is.StateReason = tc.reason
		if got := feedbackReplyOf(is, tc.comments); got != tc.want {
			t.Errorf("%s: %q, want %q", tc.name, got, tc.want)
		}
	}
	long := strings.Repeat("长", 600)
	if got := feedbackReplyParagraph(long); len([]rune(got)) != feedbackReplyRunes+1 {
		t.Errorf("not clipped: %d runes", len([]rune(got)))
	}
}

// A row the admin closed as a duplicate (C3) carries its reply too: sent once.
func TestFeedbackReplyAfterAdminDuplicate(t *testing.T) {
	r := newReplyHarness(t)
	orig := workerIDOf(r.f5, 1)
	f := r.filed(t, 9000, orig)
	if ok, err := r.h.srv.Store.CloseFeedback(f.ID, "与 F3 重复", time.Now()); !ok || err != nil {
		t.Fatalf("close: %v %v", ok, err)
	}
	r.h.srv.feedbackSendReplies(context.Background(), time.Now())
	r.h.srv.feedbackSendReplies(context.Background(), time.Now())
	msgs := messages(r.m5)
	if len(msgs) != 1 || msgs[0]["worker_id"] != orig || !strings.HasSuffix(asString(msgs[0]["text"]), "：与 F3 重复") {
		t.Fatalf("messages: %v", msgs)
	}
}
