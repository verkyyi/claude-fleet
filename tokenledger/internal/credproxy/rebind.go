package credproxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// A quota 429 moves the session once (claude-fleet#2115, EPIC #2133 C2).
//
// An account at its five-hour or weekly limit answers 429 to every request.
// When the upstream says so — not a request-rate 429, which passes through as
// before — the proxy tells the hub (POST RebindPath), which remembers the
// account as full and moves the session's binding to an account with room.
// The proxy then sends the same request (its body is already read) once more
// with the new account's token; the audit line carries `rebind_from`. No
// account with room, or the second answer is a 429 too: the client gets that
// answer, unchanged. One retry per request, never a loop.

// RebindPath is the hub route a quota 429 is reported to (api.CredProxyRebindPath).
const RebindPath = "/v1/fleet/credproxy/rebind"

// Rebinder is a Resolver that also moves a session off an account at its
// limit. It answers the session's resolution after the move (or as it stands).
type Rebinder interface {
	Rebind(ctx context.Context, pass, provider, owner, account string, resetAt int64) (Resolution, error)
}

// Rebind reports a quota 429 on account for pass's session.
func (h *HubResolver) Rebind(ctx context.Context, pass, provider, owner, account string, resetAt int64) (Resolution, error) {
	c := h.Client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	body, _ := json.Marshal(map[string]any{"cred": pass, "provider": provider, "owner": owner,
		"account": account, "reset_at": resetAt})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(h.URL, "/")+RebindPath, bytes.NewReader(body))
	if err != nil {
		return Resolution{}, err
	}
	req.Header.Set("Authorization", "Bearer "+h.Token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.Do(req)
	if err != nil {
		return Resolution{}, fmt.Errorf("%w: %v", ErrHubUnavailable, err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		return Resolution{}, fmt.Errorf("rebind: %d %s", res.StatusCode, firstLine(raw))
	}
	var r Resolution
	if err := json.Unmarshal(raw, &r); err != nil {
		return Resolution{}, fmt.Errorf("rebind: unreadable answer: %v", err)
	}
	return r, nil
}

// quotaLimited says whether a 429 is the account's quota (its five-hour or
// weekly window, Claude's unified limit or Codex's usage limit) rather than a
// request rate, and when it resets (epoch seconds, 0 = not said).
func quotaLimited(provider string, h http.Header, body []byte) (bool, int64) {
	num := func(k string) (float64, bool) {
		f, err := strconv.ParseFloat(strings.TrimSpace(h.Get(k)), 64)
		return f, err == nil
	}
	reset := func(keys ...string) int64 {
		for _, k := range keys {
			if f, ok := num(k); ok && f > 0 {
				return int64(f)
			}
		}
		return 0
	}
	var e struct {
		Error struct {
			Type     string  `json:"type"`
			Code     string  `json:"code"`
			Message  string  `json:"message"`
			ResetsAt float64 `json:"resets_at"`
			ResetsIn float64 `json:"resets_in_seconds"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	msg := strings.ToLower(e.Error.Message)
	if provider == Codex {
		if e.Error.Type == "usage_limit_reached" || e.Error.Code == "usage_limit_reached" {
			at := int64(e.Error.ResetsAt)
			if at == 0 && e.Error.ResetsIn > 0 {
				at = time.Now().Unix() + int64(e.Error.ResetsIn)
			}
			return true, at
		}
		for _, w := range []string{"primary", "secondary"} {
			if f, ok := num("x-codex-" + w + "-used-percent"); ok && f >= 100 {
				at := reset("x-codex-" + w + "-reset-at")
				if f, ok := num("x-codex-" + w + "-reset-after-seconds"); at == 0 && ok && f > 0 {
					at = time.Now().Unix() + int64(f)
				}
				return true, at
			}
		}
		return false, 0
	}
	for _, w := range []string{"7d", "5h"} {
		if f, ok := num("anthropic-ratelimit-unified-" + w + "-utilization"); ok && f >= 1 {
			return true, reset("anthropic-ratelimit-unified-"+w+"-reset", "anthropic-ratelimit-unified-reset")
		}
	}
	if strings.EqualFold(strings.TrimSpace(h.Get("anthropic-ratelimit-unified-status")), "rejected") ||
		strings.Contains(msg, "weekly limit") || strings.Contains(msg, "usage limit") || strings.Contains(msg, "session limit") {
		return true, reset("anthropic-ratelimit-unified-reset")
	}
	return false, 0
}

// remember replaces the cached answer for pass, so the session's next
// request goes to the account it was just moved to.
func (p *Proxy) remember(pass, provider string, res Resolution) {
	sum := sha256.Sum256([]byte(provider + "\x00" + pass))
	key := hex.EncodeToString(sum[:])
	p.mu.Lock()
	e := p.cache[key]
	p.mu.Unlock()
	if e == nil {
		return
	}
	e.mu.Lock()
	e.res, e.at, e.ok = res, p.cfg.Now(), true
	e.mu.Unlock()
}

// rebind handles a 429: a quota one is reported to the hub, and when the hub
// moves the session to another account the request is sent once more with
// it. Anything else — a request-rate 429, no Rebinder, the hub cannot or will
// not move it, the resend fails — answers the first 429, unchanged.
func (p *Proxy) rebind(ctx context.Context, resp *http.Response, pass, provider string, res *Resolution, a *audit,
	send func(Resolution) (*http.Response, error)) *http.Response {
	rb, ok := p.cfg.Resolver.(Rebinder)
	if !ok {
		return resp
	}
	orig := resp.Body
	raw, _ := io.ReadAll(io.LimitReader(orig, 1<<20))
	resp.Body = struct {
		io.Reader
		io.Closer
	}{io.MultiReader(bytes.NewReader(raw), orig), orig}
	limited, resetAt := quotaLimited(provider, resp.Header, raw)
	if !limited {
		return resp
	}
	nr, err := rb.Rebind(ctx, pass, provider, res.Owner, res.Account, resetAt)
	if err != nil || !nr.Valid || nr.AccessToken == "" || (nr.Owner == res.Owner && nr.Account == res.Account) {
		return resp
	}
	p.remember(pass, provider, nr)
	again, err := send(nr)
	if err != nil {
		return resp
	}
	_ = orig.Close()
	a.rebindFrom = a.account
	a.account = nr.Account
	if nr.Owner != "" && nr.Owner != nr.Principal {
		a.account = nr.Owner + "/" + nr.Account
	}
	*res = nr
	return again
}
