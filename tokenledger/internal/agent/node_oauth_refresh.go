package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent half of the OAuth refresh relay (claude-fleet#1490).
//
// The hub holds the refresh token and decides when to refresh; this machine
// only has a network the provider accepts. So the hub sends the token
// request's form, the agent posts it ONCE to the endpoint it picks itself for
// that provider, and hands the status + body back on the control channel. The
// form and the answer live in this goroutine's memory and nowhere else: not
// in a file, not in agent.log — the one log line carries the provider, the
// HTTP status and the time it took, never a byte of either body.

// oauthRefreshTimeout bounds the one POST. The hub waits 20s for the whole
// round trip (api.oauthRefreshTimeout); answering inside that is what turns a
// provider that will not answer into a definite refresh_unavailable there,
// instead of a hub timeout that cannot tell "slow node" from "dead link".
const oauthRefreshTimeout = 15 * time.Second

// relaysOAuthRefresh reports whether this agent offers the relay: an admin
// agent that was not told not to. Never a non-admin one — the hub would
// refuse to send it anything anyway, and the hello should not promise it.
func (a *Agent) relaysOAuthRefresh() bool {
	return a.cfg.FleetAdmin && a.cfg.FleetOAuthRefresh
}

// oauthTokenURL is the endpoint a relayed refresh for provider goes to: the
// provider's public one, or the operator's override for a fake provider. The
// hub never names it — a relay refreshes a Claude or Codex token, nothing else.
func (a *Agent) oauthTokenURL(provider string) string {
	if u := a.cfg.OAuthTokenURLs[provider]; u != "" {
		return u
	}
	return control.OAuthTokenURL(provider)
}

// answerOAuthRefresh serves one TypeOAuthRefresh.
func (a *Agent) answerOAuthRefresh(ctx context.Context, conn nodeLink, m control.Message) {
	reply := func(msg control.Message) {
		msg.OpID = m.OpID
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = conn.write(wctx, msg)
	}
	fail := func(code, text string) {
		reply(control.Message{Type: control.TypeError, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: text}})
	}
	if !a.relaysOAuthRefresh() {
		log.Printf("control channel: refused an oauth_refresh: this agent is not an admin agent, or CCQUOTA_FLEET_OAUTH_REFRESH=0")
		fail(control.CodeNotAdmin, "this agent does not relay token refreshes")
		return
	}
	var req control.OAuthRefresh
	if err := json.Unmarshal(m.Payload, &req); err != nil || m.OpID == "" {
		fail(control.CodeBadArgs, "malformed oauth_refresh")
		return
	}
	url := a.oauthTokenURL(req.Provider)
	if url == "" || len(req.Form) == 0 {
		fail(control.CodeBadArgs, "oauth_refresh: unknown provider or empty form")
		return
	}
	// The form is the secret. It is encoded straight into the request body;
	// nothing below formats it, and the error paths carry only the error.
	body, err := json.Marshal(req.Form)
	if err != nil {
		fail(control.CodeBadArgs, "oauth_refresh: form does not encode")
		return
	}
	rctx, cancel := context.WithTimeout(ctx, oauthRefreshTimeout)
	defer cancel()
	hreq, err := http.NewRequestWithContext(rctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		fail(control.CodeBadArgs, "oauth_refresh: bad token endpoint")
		return
	}
	hreq.Header.Set("Content-Type", "application/json")
	hreq.Header.Set("Accept", "application/json")
	started := time.Now()
	var res control.OAuthRefreshResult
	resp, err := a.http.Do(hreq)
	if err != nil {
		// A transport error names the URL at most, never the body.
		res.Error = err.Error()
		log.Printf("oauth_refresh: %s token endpoint unreachable from this machine after %s: %v", req.Provider, time.Since(started).Round(time.Millisecond), err)
	} else {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, control.MaxOAuthRefreshBody))
		resp.Body.Close()
		res.Status, res.Body = resp.StatusCode, string(raw)
		log.Printf("oauth_refresh: relayed a %s refresh for the hub: HTTP %d in %s", req.Provider, resp.StatusCode, time.Since(started).Round(time.Millisecond))
	}
	out, err := control.New(control.TypeOAuthRefreshResult, res)
	if err != nil {
		fail("INTERNAL", "oauth_refresh: result does not encode")
		return
	}
	reply(out)
}
