package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 以他的视角看 (claude-fleet#3944).

func viewAsDo(t *testing.T, h *ghHarness, sess *http.Cookie, method, path, as string) (int, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, method, h.http.URL+pagePath(path), strings.NewReader("{}"))
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", h.http.URL)
	if as != "" {
		req.Header.Set(ViewAsHeader, as)
	}
	if sess != nil {
		req.AddCookie(sess)
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		return resp.StatusCode, nil
	}
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func viewAsMe(t *testing.T, b []byte) Me {
	t.Helper()
	var me Me
	if err := json.Unmarshal(b, &me); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	return me
}

// An admin looking through alice's eyes reads as alice — her role, her
// pages, her rows only — and the view says so; the admin alone is untouched.
func TestViewAsReadsAsThePerson(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	alice := githubPrincipal(ghAlice.ID)

	_, b := viewAsDo(t, h, admin, http.MethodGet, "/v1/me", alice)
	me := viewAsMe(t, b)
	if me.Person != alice || me.Role != roleUser || me.ViewAs == nil || me.ViewAs.Person != alice ||
		me.ViewAs.Name != ghAlice.Login || me.CanLogout {
		t.Errorf("admin as alice /v1/me = %s; want alice, a user, view_as, no sign-out", b)
	}
	for _, p := range me.Pages {
		if p == "people" || p == "subscriptions" {
			t.Errorf("admin as alice pages = %v; want a member's", me.Pages)
		}
	}
	// the query works as the header does (an EventSource cannot send one)
	_, b = viewAsDo(t, h, admin, http.MethodGet, "/v1/me?as="+alice, "")
	if me := viewAsMe(t, b); me.Person != alice || me.ViewAs == nil {
		t.Errorf("admin /v1/me?as=alice = %s; want alice", b)
	}
	_, b = viewAsDo(t, h, admin, http.MethodGet, "/v1/me", "")
	if me := viewAsMe(t, b); me.Role != roleAdmin || me.ViewAs != nil {
		t.Errorf("admin /v1/me = %s; want the admin, no view", b)
	}

	var rows []store.SessionRow
	_, b = viewAsDo(t, h, admin, http.MethodGet, "/v1/sessions?account=all&since="+rolesSince+"&until="+rolesUntil, alice)
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	if len(rows) != 1 || rows[0].OSUser != aliceLogin || rows[0].AccountUUID != "" {
		t.Errorf("admin as alice /v1/sessions = %+v; want alice's only, no subscription", rows)
	}
	// an admin route is a member's refusal under the view
	if code, _ := viewAsDo(t, h, admin, http.MethodGet, "/v1/usage?by=account", alice); code != http.StatusForbidden {
		t.Errorf("admin as alice /v1/usage by account = %d; want 403", code)
	}
	// nobody by that name
	if code, _ := viewAsDo(t, h, admin, http.MethodGet, "/v1/me", "gh:999999"); code != http.StatusNotFound {
		t.Errorf("admin as nobody = %d; want 404", code)
	}
}

// Every write route of the table answers 403 under a view, whatever its
// method; so does the person's conversation, even its read.
func TestViewAsRefusesEveryWrite(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	alice := githubPrincipal(ghAlice.ID)
	patterns := make([]string, 0, len(routeAccess))
	for p, a := range routeAccess {
		if (a == accessUser || a == accessAdmin) && !isAdminPath(p) {
			patterns = append(patterns, p)
		}
	}
	sort.Strings(patterns)
	n := 0
	for _, p := range patterns {
		for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
			n++
			if code, b := viewAsDo(t, h, admin, m, p, alice); code != http.StatusForbidden || !strings.Contains(string(b), "只读预览") {
				t.Errorf("admin as alice %s %s = %d %s; want the read-only 403", m, p, code, b)
			}
		}
	}
	if n < 40 {
		t.Fatalf("walked %d writes; the table looks empty", n)
	}
	for _, p := range []string{ChatPathPrefix + "conversation", ChatPathPrefix + "turn"} {
		if code, _ := viewAsDo(t, h, admin, http.MethodGet, p, alice); code != http.StatusForbidden {
			t.Errorf("admin as alice GET %s = %d; want 403", p, code)
		}
	}
}

// A member — or the operator's door — carrying ?as= is just themself: no
// view, no read-only refusal, nobody else's rows.
func TestViewAsMemberIgnored(t *testing.T) {
	h, _, user := rolesHarness(t)
	ivan := githubPrincipal(ghAdmin.ID)
	_, b := viewAsDo(t, h, user, http.MethodGet, "/v1/me?as="+ivan, ivan)
	if me := viewAsMe(t, b); me.Person != githubPrincipal(ghAlice.ID) || me.ViewAs != nil || me.Role != roleUser {
		t.Errorf("alice as ivan /v1/me = %s; want alice herself", b)
	}
	if _, b := viewAsDo(t, h, user, http.MethodPost, "/v1/fleet/devices", ivan); strings.Contains(string(b), "只读预览") {
		t.Errorf("alice POST with as = %s; want her own answer, not the view's", b)
	}
}

// Opening a page through someone's eyes is one view_as audit row; a read of
// the API under it is none.
func TestViewAsAudited(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	alice := githubPrincipal(ghAlice.ID)
	count := func() int {
		var n int
		if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'view_as'
			AND fleet_id = ? AND actor LIKE ?`, "person:"+alice, githubPrincipal(ghAdmin.ID)+"%").Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	viewAsDo(t, h, admin, http.MethodGet, "/v1/me", alice)
	if n := count(); n != 0 {
		t.Errorf("%d view_as rows after an API read; want 0", n)
	}
	viewAsDo(t, h, admin, http.MethodGet, AppPrefix+"/me?as="+alice, "")
	if n := count(); n != 1 {
		t.Errorf("%d view_as rows after opening /app/me; want 1", n)
	}
}
