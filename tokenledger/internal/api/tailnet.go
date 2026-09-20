package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"
)

// Tailnet identity: the dashboard without a token, for named people.
//
// The tailnet decides which DEVICES can reach the hub; this decides which
// PEOPLE get in without a token. The answer comes from the local tailscaled
// (`tailscale whois`), which knows authoritatively which tailnet user owns the
// peer a connection came from. Nothing sent over HTTP is trusted -- no
// headers, no proxy claims -- so there is nothing to forge.
//
// Three rules keep it honest:
//
//   - An allowlist of logins, not "anyone on the tailnet". A tailnet routinely
//     has shared users and tagged servers on it.
//   - Tagged nodes are never people. A tag means a server; a server does not
//     get a person's view.
//   - The hub's OWN tailnet address is never trusted. It resolves to the
//     machine's owner, so a connection from the machine to itself would
//     identify as them -- which on a shared box would let every other OS login
//     be them. Self and loopback keep needing the token.
//
// Every miss is a 401, exactly as if the feature were off.

// WhoIs is what tailscaled says about one peer.
type WhoIs struct {
	Login  string
	Tagged bool
}

// TailnetViewers grants the viewer role to allowlisted tailnet logins.
type TailnetViewers struct {
	logins map[string]bool
	self   map[netip.Addr]bool
	whois  func(netip.Addr) (WhoIs, error)
	ttl    time.Duration

	mu    sync.Mutex
	cache map[netip.Addr]cacheEntry
}

type cacheEntry struct {
	login string
	ok    bool
	at    time.Time
}

// NewTailnetViewers builds the gate. An empty allowlist returns nil, which
// means OFF -- the caller checks for nil, and an unconfigured hub can never
// grant anything by this path.
//
// self is the hub's own bound addresses (loopback ones are ignored). whois
// may be nil to use the tailscale CLI.
func NewTailnetViewers(logins []string, self []string, whois func(netip.Addr) (WhoIs, error)) *TailnetViewers {
	t := &TailnetViewers{
		logins: map[string]bool{},
		self:   map[netip.Addr]bool{},
		whois:  whois,
		ttl:    5 * time.Minute,
		cache:  map[netip.Addr]cacheEntry{},
	}
	for _, l := range logins {
		if l = strings.ToLower(strings.TrimSpace(l)); l != "" {
			t.logins[l] = true
		}
	}
	if len(t.logins) == 0 {
		return nil
	}
	for _, s := range self {
		if a, err := netip.ParseAddr(strings.TrimSpace(s)); err == nil && !a.IsLoopback() {
			t.self[a] = true
		}
	}
	return t
}

// Logins returns the allowlist, sorted, for the door map at /access — an
// operator reading "who gets in here without a token" should not have to go
// back to the command line the hub was started with. Nil (the feature off)
// returns nothing, which is the honest answer: nobody.
//
// These are logins, not credentials. Nothing here lets anyone in; tailscaled
// still has to say a connection came from one of them.
func (t *TailnetViewers) Logins() []string {
	if t == nil {
		return nil
	}
	out := make([]string, 0, len(t.logins))
	for l := range t.logins {
		out = append(out, l)
	}
	sort.Strings(out)
	return out
}

var (
	tailnetV4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetV6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// IsTailnetAddr reports whether ip is in Tailscale's address ranges.
func IsTailnetAddr(ip netip.Addr) bool {
	return tailnetV4.Contains(ip) || tailnetV6.Contains(ip)
}

// Lookup answers "who is this, and may they view?" for a request's RemoteAddr.
// Anything that is not a remote, untagged, allowlisted tailnet peer is a miss.
func (t *TailnetViewers) Lookup(remoteAddr string) (login string, ok bool) {
	if t == nil {
		return "", false
	}
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return "", false
	}
	ip = ip.Unmap()
	if !IsTailnetAddr(ip) || t.self[ip] {
		// Not a tailnet peer, or ourselves. No lookup: tailscaled would
		// answer "peer not found" for the first and "you" for the second.
		return "", false
	}

	t.mu.Lock()
	if e, hit := t.cache[ip]; hit && time.Since(e.at) < t.ttl {
		t.mu.Unlock()
		return e.login, e.ok
	}
	t.mu.Unlock()

	login, ok = t.resolve(ip)
	t.mu.Lock()
	t.cache[ip] = cacheEntry{login: login, ok: ok, at: time.Now()}
	t.mu.Unlock()
	return login, ok
}

func (t *TailnetViewers) resolve(ip netip.Addr) (string, bool) {
	w, err := t.whois(ip)
	if err != nil || w.Tagged {
		return "", false
	}
	login := strings.ToLower(w.Login)
	if !t.logins[login] {
		return "", false
	}
	return login, true
}

// TailscaleWhoIs asks the local tailscaled via the CLI. No Go dependency on
// tailscale.com, which is enormous; one fork per uncached peer is cheap.
func TailscaleWhoIs(bin string) func(netip.Addr) (WhoIs, error) {
	return func(ip netip.Addr) (WhoIs, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, bin, "whois", "--json", ip.String()).Output()
		if err != nil {
			return WhoIs{}, fmt.Errorf("tailscale whois %s: %w", ip, err)
		}
		return parseWhoIs(out)
	}
}

// parseWhoIs reads the fields this gate needs from `tailscale whois --json`.
func parseWhoIs(b []byte) (WhoIs, error) {
	var v struct {
		Node struct {
			Tags []string `json:"Tags"`
		} `json:"Node"`
		UserProfile struct {
			LoginName string `json:"LoginName"`
		} `json:"UserProfile"`
	}
	if err := json.Unmarshal(b, &v); err != nil {
		return WhoIs{}, err
	}
	if v.UserProfile.LoginName == "" {
		return WhoIs{}, errors.New("whois answer carries no login")
	}
	return WhoIs{Login: v.UserProfile.LoginName, Tagged: len(v.Node.Tags) > 0}, nil
}

// FindTailscaleBin locates the tailscale CLI: an explicit path, then PATH,
// then where the macOS builds put it.
func FindTailscaleBin(explicit string) (string, error) {
	candidates := []string{explicit}
	if p, err := exec.LookPath("tailscale"); err == nil {
		candidates = append(candidates, p)
	}
	candidates = append(candidates,
		"/opt/homebrew/bin/tailscale",
		"/usr/local/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	)
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", errors.New("tailscale CLI not found; pass --tailscale-bin")
}

// viewerKey carries the identity of a tailnet-authenticated request from the
// gate out to the access log.
type viewerKey struct{}

func withViewer(ctx context.Context, login string) context.Context {
	if p, ok := ctx.Value(viewerKey{}).(*string); ok {
		*p = login
	}
	return ctx
}

// viewerOf reads back whoever the gate named, for a handler that records WHO
// did something rather than only THAT it happened (see finding_mutes.go).
//
// It shares the access log's slot deliberately: there is one answer to "who is
// this request", and a second copy could disagree with the line in the log.
//
// Empty is the normal, honest answer and not a failure. A request carrying the
// shared viewer token names nobody -- that is what a shared secret means -- and
// attributing it to a person would be an invention. A caller that stores this
// has to be fine with the empty string.
func viewerOf(ctx context.Context) string {
	if p, ok := ctx.Value(viewerKey{}).(*string); ok && p != nil {
		return *p
	}
	return ""
}
