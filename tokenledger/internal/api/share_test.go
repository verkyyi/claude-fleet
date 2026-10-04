package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"testing"
	"time"
)

// mintShare returns a usable share token for the harness's hub.
func mintShare(t *testing.T, h *harness, label string, costs bool) string {
	t.Helper()
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.CreateShareLink(label, HashToken(tok), costs, nil); err != nil {
		t.Fatal(err)
	}
	return tok
}

// getAs performs a GET with an explicit bearer token.
func getAs(t *testing.T, h *harness, path, tok string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, string(body)
}

// The containment property, and the reason the share view is a separate
// document rather than the dashboard with fields hidden: a share token must be
// worthless everywhere else. If it ever opens /v1/usage, one query string
// publishes every project path.
func TestShare_TokenIsRejectedOnEveryOtherRoute(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"s1"}, "/srv/clients/acme"))

	share := mintShare(t, h, "a third party", false)

	for _, path := range []string{
		"/v1/usage?account=all&by=project",
		"/v1/usage?account=all&by=session",
		"/v1/endpoints?account=all",
		"/v1/accounts",
		"/v1/limits?account=all",
		"/v1/endpoint-accounts",
		"/v1/account-switches",
		"/v1/history?account=all",
		"/v1/live",
		"/mcp",
		"/",
	} {
		code, body := getAs(t, h, path, share)
		if code == http.StatusOK {
			t.Errorf("%s accepted a share token (HTTP 200): %s", path, first(body, 120))
		}
	}
}

// ...and the control: the same token DOES open the share route. Without this,
// a share system that rejected everything would pass the test above.
func TestShare_TokenOpensTheShareRoute(t *testing.T) {
	h := newHarness(t)
	share := mintShare(t, h, "a third party", false)

	code, body := getAs(t, h, "/v1/share", share)
	if code != http.StatusOK {
		t.Fatalf("share route rejected its own token: HTTP %d %s", code, first(body, 200))
	}
}

// The redaction itself. Every one of these strings is in the seeded data and
// none may appear in the payload — the identifiers are what make the page
// unshareable.
func TestShare_PayloadCarriesNoIdentifiers(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "buildbox-alice")

	b := batchFor("acct-secret", "buildbox-alice", []string{"x1", "x2"}, "/srv/clients/acme-holdings")
	b.Identity.Email = "someone@a-real-company.example"
	b.Identity.OSUser = "alice"
	b.Events[0].GitBranch = "feature/unannounced-product"
	h.push(t, tok, b)

	share := mintShare(t, h, "conference talk", false)
	code, body := getAs(t, h, "/v1/share", share)
	if code != http.StatusOK {
		t.Fatalf("HTTP %d: %s", code, body)
	}

	for _, secret := range []string{
		"acct-secret",                 // account uuid
		"someone@a-real-company",      // account email
		"/srv/clients/acme-holdings",  // project path — a client's name
		"acme-holdings",               // ...even as a fragment
		"buildbox-alice",              // machine / endpoint label
		"alice",                       // OS login — a colleague
		"feature/unannounced-product", // branch
		"sess-buildbox-alice",         // session id
	} {
		if strings.Contains(body, secret) {
			t.Errorf("the public payload contains %q:\n%s", secret, body)
		}
	}

	// It must still say something worth showing.
	var v ShareView
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		t.Fatal(err)
	}
	if v.Tokens == 0 || v.Turns == 0 {
		t.Error("the public view has no volume figures; nothing worth sharing survived")
	}
	if v.Scale.Projects != 1 || v.Scale.Machines != 1 {
		t.Errorf("scale = %+v; counts must survive even though names do not", v.Scale)
	}
	if v.Subscriptions[0].Name != "Subscription A" {
		t.Errorf("subscription name = %q, want a pseudonym", v.Subscriptions[0].Name)
	}
}

// Costs are notional. Shown to someone who does not know that, they read as a
// bill, so they are off unless the link was minted for it.
func TestShare_CostsAreOffByDefault(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"c1"}, "/a"))

	quiet := mintShare(t, h, "no costs", false)
	_, body := getAs(t, h, "/v1/share", quiet)
	var v ShareView
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		t.Fatal(err)
	}
	if v.CostUSD != nil {
		t.Errorf("cost shown on a link minted without --with-costs: %v", *v.CostUSD)
	}

	loud := mintShare(t, h, "with costs", true)
	_, body = getAs(t, h, "/v1/share", loud)
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		t.Fatal(err)
	}
	if v.CostUSD == nil {
		t.Error("a link minted WITH costs shows none — the flag does nothing")
	}
	if !strings.Contains(v.Disclaimer, "NOTIONAL") {
		t.Errorf("disclaimer does not mark the figure notional: %q", v.Disclaimer)
	}
}

// Revocation has to actually revoke, immediately.
func TestShare_RevokedLinkStopsWorking(t *testing.T) {
	h := newHarness(t)
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	link, err := h.srv.Store.CreateShareLink("temp", HashToken(tok), false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if code, _ := getAs(t, h, "/v1/share", tok); code != http.StatusOK {
		t.Fatalf("fresh link rejected: HTTP %d", code)
	}
	if changed, err := h.srv.Store.RevokeShareLink(link.ID); err != nil || !changed {
		t.Fatalf("revoke: changed=%v err=%v", changed, err)
	}
	if code, _ := getAs(t, h, "/v1/share", tok); code != http.StatusUnauthorized {
		t.Fatalf("revoked link still works: HTTP %d", code)
	}
}

func TestShare_ExpiredLinkStopsWorking(t *testing.T) {
	h := newHarness(t)
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	past := time.Now().UTC().Add(-time.Hour)
	if _, err := h.srv.Store.CreateShareLink("stale", HashToken(tok), false, &past); err != nil {
		t.Fatal(err)
	}
	if code, _ := getAs(t, h, "/v1/share", tok); code != http.StatusUnauthorized {
		t.Fatalf("expired link still works: HTTP %d", code)
	}
}

func first(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// The browser flow, which the bearer-token tests above cannot see: a recipient
// opens /share?token=…, gets redirected with a cookie, and the PAGE then fetches
// /v1/share with no query string. A cookie scoped to the page's own path is not
// sent to the data route, so the link opens to an error — exactly what happened
// the first time this was tried against a real browser.
func TestShare_CookieFromTheRedirectReachesTheDataRoute(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"k1"}, "/a"))
	share := mintShare(t, h, "browser flow", false)

	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	client := h.http.Client()
	client.Jar = jar

	// 1. what the recipient clicks. The page itself 404s in this binary (no
	// embedded UI in a test build); what matters is the cookie the redirect
	// leaves behind, so assert that rather than the body.
	resp, err := client.Get(h.http.URL + "/share?token=" + share)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	u, _ := url.Parse(h.http.URL + "/v1/share")
	var carried bool
	for _, c := range jar.Cookies(u) {
		if c.Name == "ccquota_share" {
			carried = true
		}
	}
	if !carried {
		t.Fatal("no ccquota_share cookie is sent to /v1/share — the page will " +
			"open to an error even though the link is valid")
	}

	// 2. what the page then does — no token in the URL, cookie only.
	resp, err = client.Get(h.http.URL + "/v1/share")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("the page could not load its own data: HTTP %d %s — the share "+
			"cookie did not reach /v1/share", resp.StatusCode, first(string(body), 200))
	}
	var v ShareView
	if err := json.Unmarshal(body, &v); err != nil {
		t.Fatal(err)
	}
	if v.Tokens == 0 {
		t.Error("the page loaded but has no figures")
	}
}
