package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/dns"
)

// The keys page (claude-fleet#3069, EPIC #3067 C2).

// keysPage GETs (form == nil) or POSTs the page as principal's browser: no
// redirect followed, the page's own origin on a POST.
func keysPage(t *testing.T, h *harness, principal, query string, form url.Values) (int, string, string) {
	t.Helper()
	method, body := http.MethodGet, io.Reader(nil)
	if form != nil {
		method, body = http.MethodPost, strings.NewReader(form.Encode())
	}
	path := EntryPagePath
	if strings.HasPrefix(query, "/") { // another page of the book: /fleet/connection?…
		path, query = query, ""
		if i := strings.IndexByte(path, '?'); i >= 0 {
			path, query = path[:i], path[i:]
		}
	}
	req, _ := http.NewRequest(method, h.http.URL+path+query, body)
	req.Header.Set("Accept", "text/html")
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", h.http.URL)
	}
	switch principal {
	case "":
	case "operator":
		req.Header.Set("Authorization", "Bearer "+viewerToken)
	default:
		req.AddCookie(personCookie(principal, ""))
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp.Header.Get("Location")
}

func keysPost(t *testing.T, h *harness, principal string, kv ...string) (int, string, string) {
	t.Helper()
	f := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		f.Set(kv[i], kv[i+1])
	}
	return keysPage(t, h, principal, "", f)
}

// drawnFP is a fingerprint as the page draws it: shortened, its "+"
// escaped by html/template.
func drawnFP(fp string) string {
	return strings.ReplaceAll(entryShortFP(fp), "+", "&#43;")
}

// wantRedirect wants a POST answered 303 → ?ok=<ok>.
func wantRedirect(t *testing.T, what string, code int, body, loc, ok string) {
	t.Helper()
	if code != http.StatusSeeOther || loc != EntryPagePath+"?ok="+ok {
		t.Fatalf("%s: HTTP %d → %q, want 303 → ?ok=%s\n%s", what, code, loc, ok, body)
	}
}

// Completion criteria: another person's keys are not to be seen (nor
// revoked); the four things show the address, 22022, the home login and the
// key; a revoke goes through the bottom confirmation.
func TestEntryPageOwnBookOnly(t *testing.T) {
	h := entryHarness(t)
	_ = h.srv.Store.SetFleetSetting(EntryDomainKey, "cf.example.com", time.Now())

	// First visit: the wizard at step 1; the name is asked at step 4 (the
	// Hostname), suggested from the sign-in name.
	code, body, _ := keysPage(t, h, pAlice, "", nil)
	if code != 200 || !strings.Contains(body, "去 App Store 装 Termius") || strings.Contains(body, "Hostname") {
		t.Fatalf("Alice's first visit: HTTP %d\n%s", code, body)
	}
	if _, body, _ = keysPage(t, h, pAlice, "?step=4", nil); !strings.Contains(body, "先给你的地址起个名字") || strings.Contains(body, ">Hostname<") {
		t.Fatalf("step 4 before a name:\n%s", body)
	}
	code, body, loc := keysPost(t, h, pAlice, "do", "name", "name", "Alice-1")
	wantRedirect(t, "Alice names her address", code, body, loc, "name")

	line := entryKeyLine(t, "termius")
	code, body, loc = keysPost(t, h, pAlice, "do", "add", "key", line, "label", "iPhone")
	wantRedirect(t, "Alice adds a key", code, body, loc, "added")
	keys, _ := h.srv.Store.EntryKeys(pAlice, false)
	if len(keys) != 1 || keys[0].Name != "iPhone" {
		t.Fatalf("Alice's keys after the page: %+v", keys)
	}
	k := keys[0]
	b64 := strings.Fields(line)[1]

	code, body, _ = keysPage(t, h, pAlice, "?ok=added", nil)
	_, conn, _ := keysPage(t, h, pAlice, EntryConnPath, nil) // the keys themselves are 我的连接's
	body += conn
	short := drawnFP(k.FP)
	for _, want := range []string{"已加上", "alice-1.cf.example.com", ">22022<", ">alice<", "iPhone", short, "ed25519", "还没用过", `href="?revoke=` + k.ID} {
		if !strings.Contains(body, want) {
			t.Fatalf("Alice's page lacks %q: HTTP %d\n%s", want, code, body)
		}
	}
	if strings.Contains(body, b64) || strings.Contains(body, k.FP) {
		t.Fatalf("the page shows the key's body or its whole fingerprint:\n%s", body)
	}

	// Bob sees none of it — not even naming Alice — and cannot revoke it.
	for _, q := range []string{"", "?principal=" + url.QueryEscape(pAlice), "?revoke=" + k.ID, EntryConnPath, EntryConnPath + "?revoke=" + k.ID} {
		_, body, _ = keysPage(t, h, pBob, q, nil)
		if strings.Contains(body, `class="n">iPhone<`) || strings.Contains(body, short) || strings.Contains(body, k.ID) || strings.Contains(body, "alice-1") {
			t.Fatalf("Bob's page %q shows Alice's book:\n%s", q, body)
		}
	}
	code, body, _ = keysPost(t, h, pBob, "do", "revoke", "id", k.ID)
	if code != http.StatusNotFound || !strings.Contains(body, "没有这把钥匙") {
		t.Fatalf("Bob revokes Alice's key: HTTP %d\n%s", code, body)
	}
	if keys, _ := h.srv.Store.EntryKeys(pAlice, false); len(keys) != 1 {
		t.Fatalf("Bob's revoke took Alice's key")
	}

	// Alice: the bottom sheet, then the revoke.
	_, body, _ = keysPage(t, h, pAlice, "?revoke="+k.ID, nil)
	if !strings.Contains(body, `class="sheet"`) || !strings.Contains(body, "撤掉「iPhone」？") || !strings.Contains(body, "断开") {
		t.Fatalf("no confirmation sheet:\n%s", body)
	}
	code, body, loc = keysPost(t, h, pAlice, "do", "revoke", "id", k.ID)
	wantRedirect(t, "Alice revokes", code, body, loc, "revoked")
	if keys, _ := h.srv.Store.EntryKeys(pAlice, false); len(keys) != 0 {
		t.Fatalf("the key is still live after the revoke: %+v", keys)
	}

	// A form from another site is refused.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+EntryPagePath, strings.NewReader("do=name&name=evil"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "https://evil.example")
	req.AddCookie(personCookie(pAlice, ""))
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-site form: HTTP %d, want 403", resp.StatusCode)
	}
}

// A private key pasted by mistake: one sentence a person reads, nothing kept,
// nothing of it drawn back. Nonsense is said so; the same key twice is fine.
func TestEntryPagePrivateKeyRefused(t *testing.T) {
	h := entryHarness(t)
	if code, body, loc := keysPost(t, h, pAlice, "do", "name", "name", "alice"); code != http.StatusSeeOther {
		t.Fatalf("name: HTTP %d %s %s", code, loc, body)
	}
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	blk, _ := ssh.MarshalPrivateKey(priv, "phone")
	pemText := string(pem.EncodeToMemory(blk))
	secret := strings.Split(pemText, "\n")[2]

	code, body, _ := keysPost(t, h, pAlice, "do", "add", "key", pemText, "label", "iPhone")
	if code != http.StatusUnprocessableEntity || !strings.Contains(body, "这是一把私钥") || !strings.Contains(body, "没有保存") {
		t.Fatalf("private key: HTTP %d\n%s", code, body)
	}
	if strings.Contains(body, secret) || strings.Contains(body, "PRIVATE KEY") {
		t.Fatalf("the page draws the private key back:\n%s", body)
	}
	if keys, _ := h.srv.Store.EntryKeys(pAlice, true); len(keys) != 0 {
		t.Fatalf("a private key left %d rows", len(keys))
	}

	code, body, _ = keysPost(t, h, pAlice, "do", "add", "key", "hello there")
	if code != http.StatusUnprocessableEntity || !strings.Contains(body, "看不懂这一行") || !strings.Contains(body, ">hello there</textarea>") {
		t.Fatalf("nonsense: HTTP %d\n%s", code, body)
	}

	line := entryKeyLine(t, "x")
	code, body, loc := keysPost(t, h, pAlice, "do", "add", "key", line)
	wantRedirect(t, "a key", code, body, loc, "added")
	code, body, loc = keysPost(t, h, pAlice, "do", "add", "key", line)
	wantRedirect(t, "the same key again", code, body, loc, "same")
	_, body, _ = keysPage(t, h, pAlice, "?ok=same", nil)
	if !strings.Contains(body, "已经在你的列表里了") {
		t.Fatalf("?ok=same says nothing:\n%s", body)
	}
	keysPost(t, h, pBob, "do", "name", "name", "bob")
	_, body, _ = keysPost(t, h, pBob, "do", "add", "key", line)
	if !strings.Contains(body, "别人名下") {
		t.Fatalf("Bob adds Alice's key:\n%s", body)
	}
	code, body, _ = keysPost(t, h, pAlice, "do", "name", "name", "admin")
	if code != http.StatusUnprocessableEntity || !strings.Contains(body, "留作他用") {
		t.Fatalf("a reserved name: HTTP %d\n%s", code, body)
	}
}

// With no address zone configured the card says so, and still lists port,
// user and key.
func TestEntryPageNoDomain(t *testing.T) {
	h := entryHarness(t)
	keysPost(t, h, pAlice, "do", "name", "name", "alice")
	_, body, _ := keysPage(t, h, pAlice, "?step=4", nil)
	if !strings.Contains(body, "地址还没配好") || !strings.Contains(body, ">22022<") || strings.Contains(body, "alice.cf") {
		t.Fatalf("no zone:\n%s", body)
	}
	// The deploy's DNS zone is the default (claude-fleet#3199) …
	h.srv.EntryDNS = NewEntryDNS(dns.NewFake(), "cf")
	h.srv.EntryDNS.Zone = "cf.24haowan.com"
	_, body, _ = keysPage(t, h, pAlice, "?step=4", nil)
	if strings.Contains(body, "地址还没配好") || !strings.Contains(body, "alice.cf.24haowan.com") {
		t.Fatalf("the deploy's zone:\n%s", body)
	}
	// … and a stored one wins.
	_ = h.srv.Store.SetFleetSetting(EntryDomainKey, "cf.example.com", time.Now())
	_, body, _ = keysPage(t, h, pAlice, "?step=4", nil)
	if strings.Contains(body, "地址还没配好") || !strings.Contains(body, "alice.cf.example.com") {
		t.Fatalf("with a zone:\n%s", body)
	}
}

// 换一台当家 lists only logins of theirs with a live fleet: a login on a
// machine with no fleet of theirs is not offered, and cannot be posted.
func TestEntryPageMoveOnlyLiveFleets(t *testing.T) {
	h := entryHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "spare", Login: "alice"}); code != 200 {
		t.Fatalf("adopt alice on spare: HTTP %d", code)
	}
	connectNode(t, h, "spare-alice", "spare", "alice", false) // online, no fleet
	keysPost(t, h, pAlice, "do", "name", "name", "alice")
	_, body, _ := keysPage(t, h, pAlice, EntryConnPath, nil)
	home, ok, _ := h.srv.Store.EntryHomeOf(pAlice)
	if !ok {
		t.Fatalf("Alice has no home after her first visit")
	}
	other := "m4"
	if home.Machine == "macmini-m4" {
		other = "m5"
	}
	i := strings.Index(body, `id="home"`)
	if i < 0 {
		t.Fatalf("no 换一台当家:\n%s", body)
	}
	moves := body[i:]
	if !strings.Contains(moves, "<b>"+other+"</b>") || strings.Contains(moves, "spare") {
		t.Fatalf("the move list (want %s, never spare):\n%s", other, moves)
	}
	if _, body, _ := keysPage(t, h, pAlice, "?move=spare&login=alice", nil); strings.Contains(body, `class="sheet"`) {
		t.Fatalf("a confirmation for a machine with no fleet:\n%s", body)
	}
	code, body, _ := keysPost(t, h, pAlice, "do", "home", "machine", "spare", "login", "alice")
	if code != http.StatusUnprocessableEntity || !strings.Contains(body, "只能换到") {
		t.Fatalf("move to spare: HTTP %d\n%s", code, body)
	}
	target := "macmini"
	if other == "m4" {
		target = "macmini-m4"
	}
	_, body, _ = keysPage(t, h, pAlice, "?move="+target+"&login=alice", nil)
	if !strings.Contains(body, "主机钥匙变了") || !strings.Contains(body, `value="`+target+`"`) {
		t.Fatalf("the move sheet:\n%s", body)
	}
	code, body, loc := keysPost(t, h, pAlice, "do", "home", "machine", target, "login", "alice")
	wantRedirect(t, "move", code, body, loc, "home")
	if h2, _, _ := h.srv.Store.EntryHomeOf(pAlice); h2.Machine != target {
		t.Fatalf("home after the move: %+v", h2)
	}
}

// Off, the page is not there; the operator's token reads no one's book; a
// browser not signed in goes to sign in and comes back.
func TestEntryPageDoors(t *testing.T) {
	h := entryHarness(t)
	_, body, _ := keysPage(t, h, "operator", "", nil)
	if !strings.Contains(body, "用你自己的 GitHub 登录") {
		t.Fatalf("the operator's token:\n%s", body)
	}
	code, body, loc := keysPage(t, h, "", "", nil)
	if code != http.StatusFound || loc != "/signin" {
		t.Fatalf("not signed in: HTTP %d → %q", code, loc)
	}
	r := httptest.NewRequest(http.MethodGet, "/auth/github/callback", nil)
	r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: EntryPagePath})
	if got := loginReturn(httptest.NewRecorder(), r); got != EntryPagePath {
		t.Fatalf("after sign-in: %q, want %s", got, EntryPagePath)
	}
	r = httptest.NewRequest(http.MethodGet, "/auth/github/callback", nil)
	r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: "https://evil.example/"})
	if got := loginReturn(httptest.NewRecorder(), r); got != "/" {
		t.Fatalf("a forged return: %q, want /", got)
	}
	// Off, the page says so — never a bare 404 (claude-fleet#3199); a user
	// asks an admin, an admin opens it with one press.
	_ = h.srv.Store.SetFleetSetting(EntryKey, "off", time.Now())
	code, body, _ = keysPage(t, h, pAlice, "", nil)
	if code != http.StatusOK || !strings.Contains(body, "直连入口还没开") || !strings.Contains(body, "请管理员打开") || strings.Contains(body, `value="enable"`) {
		t.Fatalf("off, a user: HTTP %d\n%s", code, body)
	}
	if code, _, _ := keysPost(t, h, pAlice, "do", "enable"); code != http.StatusForbidden || h.srv.entryOn() {
		t.Fatalf("a user switches it on: HTTP %d", code)
	}
	id, _ := githubIDOf(pCarol)
	h.srv.GitHub.Admins = append(h.srv.GitHub.Admins, "carol")
	if _, err := h.srv.Store.PinLogin("carol", id, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, body, _ := keysPage(t, h, pCarol, "", nil); !strings.Contains(body, `value="enable"`) {
		t.Fatalf("off, an admin:\n%s", body)
	}
	code, body, loc = keysPost(t, h, pCarol, "do", "enable")
	wantRedirect(t, "an admin opens the door", code, body, loc, "enabled")
	if !h.srv.entryOn() {
		t.Fatal("still off")
	}
	// The paths a person types land on the page.
	for _, p := range []string{"/fleet/key", "/fleet/keys/", "/keys", "/fleet/keys/nope"} {
		resp := h.raw(t, p, nil)
		resp.Body.Close()
		if resp.StatusCode != http.StatusMovedPermanently || resp.Header.Get("Location") != EntryPagePath {
			t.Fatalf("%s: HTTP %d → %q", p, resp.StatusCode, resp.Header.Get("Location"))
		}
	}
	if resp := h.raw(t, EntryPagePath+"/img/../../etc/passwd", nil); resp.StatusCode == http.StatusOK {
		t.Fatal("a picture path walked out")
	}
}

// The page at a phone's width (375 px): the snapshot of what is drawn, and no
// rule wider than the phone.
func TestEntryPageSnapshot375(t *testing.T) {
	h := entryHarness(t)
	_ = h.srv.Store.SetFleetSetting(EntryDomainKey, "cf.example.com", time.Now())
	keysPost(t, h, pAlice, "do", "name", "name", "alice")
	keysPost(t, h, pAlice, "do", "add", "key", entryKeyLine(t, "x"), "label", "iPhone · Termius")
	_, body, _ := keysPage(t, h, pAlice, "", nil)

	if !strings.Contains(body, `name="viewport" content="width=device-width`) {
		t.Fatal("no viewport meta: a phone draws it at 980 px")
	}
	for _, m := range regexp.MustCompile(`(?:^|[;{])\s*(?:min-)?width:(\d+)px`).FindAllStringSubmatch(body, -1) {
		if n, _ := strconv.Atoi(m[1]); n > 375 {
			t.Fatalf("a rule %q is wider than a 375 px phone", m[0])
		}
	}
	keys, _ := h.srv.Store.EntryKeys(pAlice, false)
	snap := strings.NewReplacer(keys[0].ID, "k_ID", drawnFP(keys[0].FP), "SHA256:FP").Replace(body)
	const golden = "testdata/entry_keys_375.html"
	if os.Getenv("UPDATE_GOLDEN") != "" {
		_ = os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(golden, []byte(snap), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("%v (UPDATE_GOLDEN=1 writes it)", err)
	}
	if string(want) != snap {
		t.Fatalf("the 375 px page changed; UPDATE_GOLDEN=1 go test -run TestEntryPageSnapshot375 rewrites %s\n%s", golden, snap)
	}
}

func TestEntryPageHelpers(t *testing.T) {
	if got := entryShortFP("SHA256:q3VtAbCdEfGhIjKlMnOp9xKc"); got != "SHA256:q3Vt…9xKc" {
		t.Fatalf("short fp %q", got)
	}
	now := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	for d, want := range map[time.Duration]string{10 * time.Second: "刚才", 5 * time.Minute: "5 分钟前", 3 * time.Hour: "3 小时前", 50 * time.Hour: "2 天前", 30 * 24 * time.Hour: "2026-09-10"} {
		if got := entryWhen(now.Add(-d), now); got != want {
			t.Fatalf("entryWhen(-%v) = %q, want %q", d, got, want)
		}
	}
	if entryKeyType("ecdsa-sha2-nistp256") != "ecdsa" || entryKeyType(ssh.KeyAlgoED25519) != "ed25519" {
		t.Fatal("key types")
	}
}
