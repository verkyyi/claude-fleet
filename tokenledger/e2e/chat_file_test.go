package e2e

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

// An image in the conversation (task T773): the page fetches it by its ref
// through /v1/chat/file — the person's own home only, the ref the one thing that
// travels (never a path, never another query), anything else refused before the
// home; the answer may be kept by the browser.
func TestChatFile(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setChatHome(t, h, pAlice, host, login)
	alice := personCookie(pAlice, "alice")
	ref := strings.Repeat("ab", 16) + ".png"
	get := func(c *http.Cookie, q string) (*http.Response, string) {
		req, _ := http.NewRequest("GET", h.HTTP.URL+"/v1/chat/file"+q, nil)
		if c != nil {
			req.AddCookie(c)
		}
		resp, err := h.HTTP.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}
	resp, body := get(alice, "?ref="+ref+"&path=/etc/passwd")
	if resp.StatusCode != http.StatusOK || body != fakePNG || resp.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("alice's image: %d %q %q", resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
	if cc := resp.Header.Get("Cache-Control"); strings.Contains(cc, "no-store") || !strings.Contains(cc, "immutable") {
		t.Errorf("an image's Cache-Control %q; want the service's (kept by the browser)", cc)
	}
	svc.mu.Lock()
	q := append([]string(nil), svc.queries...)
	svc.mu.Unlock()
	if len(q) != 1 || q[0] != "ref="+ref {
		t.Errorf("the service saw queries %q; want only ref=%s", q, ref)
	}
	n := len(svc.seen())
	for _, bad := range []string{"", "?ref=../../etc/passwd", "?ref=" + strings.Repeat("ab", 16) + ".html", "?ref=" + strings.Repeat("AB", 16) + ".png", "?ref=x.png"} {
		if resp, _ := get(alice, bad); resp.StatusCode != http.StatusNotFound {
			t.Errorf("ref %q: %d; want 404", bad, resp.StatusCode)
		}
	}
	if resp, _ := get(nil, "?ref="+ref); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("no sign-in: %d; want 401", resp.StatusCode)
	}
	if len(svc.seen()) != n {
		t.Errorf("a refused file request reached the home: %v", svc.seen()[n:])
	}
	// More than a turn's four slots at once: images wait in their own line.
	done := make(chan int, 10)
	for i := 0; i < 10; i++ {
		go func() { r, _ := get(alice, "?ref="+ref); done <- r.StatusCode }()
	}
	for i := 0; i < 10; i++ {
		if st := <-done; st != http.StatusOK && st != http.StatusTooManyRequests {
			t.Errorf("a parallel image: %d", st)
		}
	}
}

// The copy beside the entry keeps an image as its preview only (task T773):
// no ref, no bytes; the newest previews first, within its budget. A page's card
// keeps its title, link and state, never its preview's ref.
func TestChatMirrorImages(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.Srv.Vault = &credvault.Vault{Store: h.Srv.Store, Sealer: sealer}
	setChatHome(t, h, pAlice, host, login)
	alice := personCookie(pAlice, "alice")
	ref := strings.Repeat("cd", 16) + ".jpg"
	thumb := "data:image/jpeg;base64,/9j/THUMB"
	huge := "data:image/jpeg;base64," + strings.Repeat("A", 40<<10)
	svc.mu.Lock()
	svc.conversation = func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"session":"s1","items":[{"t":"user","text":"看图","images":[{"ref":"`+ref+`","w":10,"h":20,"thumb":"`+thumb+`"}]},`+
			`{"t":"tool","id":"tu1","name":"Read","summary":"Read · a.png"},{"t":"tool_result","id":"tu1","text":""},`+
			`{"t":"image","id":"tu1","ref":"`+ref+`","w":10,"h":20,"thumb":"`+thumb+`"},`+
			`{"t":"image","ref":"`+ref+`","w":1,"h":1,"thumb":"`+huge+`"},{"t":"image_more","n":3,"x":"y"},{"t":"text","d":"好"},`+
			`{"t":"page","id":"tu9","title":"周报","url":"https://w.example/s/x","status":"ready","proposal":"P1","version":2,"preview":"`+ref+`"}]}`)
	}
	svc.mu.Unlock()
	read := func(q string) string {
		req, _ := http.NewRequest("GET", h.HTTP.URL+"/v1/chat/conversation"+q, nil)
		req.AddCookie(alice)
		resp, err := h.HTTP.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			return ""
		}
		return string(b)
	}
	read("")
	var b string
	waitFor(t, 5e9, "copy kept", func() bool { b = read("?cached=1"); return b != "" })
	if strings.Contains(b, ref) || strings.Contains(b, "AAAAAAAA") || strings.Contains(b, `"x"`) {
		t.Errorf("the copy holds a ref, an oversized preview or a stray field: %s", b)
	}
	if strings.Count(b, thumb) != 2 || !strings.Contains(b, `{"n":3,"t":"image_more"}`) || !strings.Contains(b, `"id":"tu1"`) {
		t.Errorf("the copy: %s; want both previews, the image_more count and the step's id", b)
	}
	if !strings.Contains(b, `"title":"周报"`) || !strings.Contains(b, `"url":"https://w.example/s/x"`) || !strings.Contains(b, `"version":2`) {
		t.Errorf("the copy lost the page card (task T773 ④): %s", b)
	}
}
