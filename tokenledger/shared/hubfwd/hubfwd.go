// Package hubfwd is the node's warm road to the hub (claude-fleet T672).
//
// Every `ccquota place` / `lease`, every task-record curl and every python
// authority read used to open its own HTTPS connection to the hub: a TCP and
// TLS handshake each (≈ 0.55 s from a machine in Shenzhen, one round trip
// ≈ 0.18 s), three or four of them per dispatch. The running `ccquota agent`
// already talks to the hub all day; it now also serves one local unix socket
// that forwards a caller's request to ITS hub on its own keep-alive client,
// kept warm — so a caller pays one round trip, not three.
//
// The forwarder adds nothing to a request: the caller signs it (its node
// token / FleetSig) exactly as it would directly, and the forwarder only
// carries it — to the one hub it serves (a caller naming another hub in
// HubHeader is refused 421, before anything is sent), on /v1/node/… and
// /v1/fleet/… only, never an upgrade. So the socket can be 0666: anyone who
// can use it could reach the hub directly with the same credential.
//
// The client side (Transport) tries the socket first and falls back to the
// direct connection when there is no socket, nobody answers on it, or the
// forwarder refused before forwarding — never after a request was sent.
package hubfwd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	// HubHeader names the hub base URL the caller means.
	HubHeader = "X-Fleet-Hub"
	// ViaHeader marks an answer the forwarder wrote itself (its refusal or
	// its own failure to reach the hub), never the hub's.
	ViaHeader = "X-Fleet-Hubfwd"
	// SockEnv overrides where the socket is (both sides); "off" = none.
	SockEnv = "CCQUOTA_HUB_SOCK"
	// SockName is the socket's name under a per-login agent's state dir.
	SockName = "hub.sock"
	// MachineSock is the managed machine's: beside its agent's state.
	MachineSock = "/var/db/fleet-node/hub.sock"

	maxBody = 1 << 20
)

// WarmEvery is how often the forwarder touches the hub so its connection is
// never idle long enough for a proxy to close it. A variable for tests.
var WarmEvery = 25 * time.Second

// Forwarder carries callers' requests to one hub.
type Forwarder struct {
	// Hub is the base URL callers know the hub by (what they put in HubHeader).
	Hub string
	// Dial is where the forwarder actually connects ("" = Hub): a pod's
	// in-cluster Service, as the agent's own calls do.
	Dial string
	// Client is the keep-alive client (nil = one of its own).
	Client *http.Client
}

func norm(u string) string { return strings.TrimRight(strings.TrimSpace(u), "/") }

// Allowed is the path set a forwarder carries.
func Allowed(p string) bool {
	if p == "/v1/node/connect" || strings.Contains(p, "..") {
		return false
	}
	return p == "/healthz" || strings.HasPrefix(p, "/v1/node/") || strings.HasPrefix(p, "/v1/fleet/")
}

var hopByHop = map[string]bool{"Connection": true, "Keep-Alive": true, "Proxy-Connection": true,
	"Te": true, "Trailer": true, "Transfer-Encoding": true, "Upgrade": true, HubHeader: true}

func (f *Forwarder) client() *http.Client {
	if f.Client != nil {
		return f.Client
	}
	return http.DefaultClient
}

func (f *Forwarder) base() string {
	if f.Dial != "" {
		return norm(f.Dial)
	}
	return norm(f.Hub)
}

func refuse(w http.ResponseWriter, code int, why string) {
	w.Header().Set(ViaHeader, "refused")
	http.Error(w, "hubfwd: "+why, code)
}

func (f *Forwarder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if norm(r.Header.Get(HubHeader)) != norm(f.Hub) {
		refuse(w, http.StatusMisdirectedRequest, "this forwarder serves "+norm(f.Hub)+" only")
		return
	}
	if !Allowed(r.URL.Path) || r.Header.Get("Upgrade") != "" {
		refuse(w, http.StatusForbidden, "not a path it carries")
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, f.base()+r.URL.RequestURI(), http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		refuse(w, http.StatusBadRequest, err.Error())
		return
	}
	req.ContentLength = r.ContentLength
	for k, vs := range r.Header {
		if !hopByHop[http.CanonicalHeaderKey(k)] {
			req.Header[k] = vs
		}
	}
	if f.Dial != "" {
		if u, err := url.Parse(norm(f.Hub)); err == nil {
			req.Host = u.Host
		}
	}
	resp, err := f.client().Do(req)
	if err != nil {
		// The hub could not be reached from here: said as the transport error
		// it was, so the caller's own words for it (dial tcp …, timeout) hold.
		w.Header().Set(ViaHeader, "unreachable")
		http.Error(w, "hubfwd: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for k, vs := range resp.Header {
		if !hopByHop[http.CanonicalHeaderKey(k)] {
			w.Header()[k] = vs
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

// Serve listens on path until ctx ends, removing the socket on the way out.
// A socket a live forwarder still answers on is left alone (an error); a
// stale one is replaced.
func (f *Forwarder) Serve(ctx context.Context, path string) error {
	if path == "" || path == "off" {
		return nil
	}
	if c, err := net.DialTimeout("unix", path, 200*time.Millisecond); err == nil {
		c.Close()
		return fmt.Errorf("hubfwd: %s already answers", path)
	}
	_ = os.Remove(path)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	// Anyone who can use it could reach the hub with the same credential:
	// the socket is open to every local caller.
	_ = os.Chmod(path, 0o666)
	srv := &http.Server{Handler: f, ReadHeaderTimeout: 10 * time.Second}
	go f.warm(ctx)
	go func() { <-ctx.Done(); _ = srv.Close() }()
	err = srv.Serve(ln)
	_ = os.Remove(path)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (f *Forwarder) warm(ctx context.Context) {
	t := time.NewTicker(WarmEvery)
	defer t.Stop()
	touch := func() {
		c, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(c, http.MethodGet, f.base()+"/healthz", nil)
		if err != nil {
			return
		}
		if f.Dial != "" {
			if u, err := url.Parse(norm(f.Hub)); err == nil {
				req.Host = u.Host
			}
		}
		if resp, err := f.client().Do(req); err == nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
		}
	}
	touch()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			touch()
		}
	}
}

// SockPath is where a caller looks for a forwarder: $CCQUOTA_HUB_SOCK ("off"
// = nowhere), else the per-login agent's (~/.ccquota/hub.sock), else the
// managed machine's.
func SockPath() string {
	if v := os.Getenv(SockEnv); v != "" {
		if v == "off" {
			return ""
		}
		return v
	}
	if h, err := os.UserHomeDir(); err == nil {
		if p := filepath.Join(h, ".ccquota", SockName); exists(p) {
			return p
		}
	}
	if exists(MachineSock) {
		return MachineSock
	}
	return ""
}

// Known says whether p is a place SockPath looks (with no $CCQUOTA_HUB_SOCK):
// a forwarder anywhere else would serve nobody.
func Known(p string) bool {
	if p == MachineSock {
		return true
	}
	h, err := os.UserHomeDir()
	return err == nil && filepath.Clean(p) == filepath.Join(h, ".ccquota", SockName)
}

func exists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode()&os.ModeSocket != 0
}

// Transport is base (nil = http.DefaultTransport) with the forwarder in
// front for requests to hub.
func Transport(hub string, base http.RoundTripper) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return &transport{hub: norm(hub), base: base}
}

type transport struct {
	hub  string
	base http.RoundTripper
	once sync.Once
	sock string
	unix http.RoundTripper
}

func (t *transport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.once.Do(func() {
		t.sock = SockPath()
		if t.sock != "" {
			p := t.sock
			t.unix = &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", p)
			}, DisableKeepAlives: true}
		}
	})
	if t.unix == nil || !strings.HasPrefix(req.URL.String(), t.hub+"/") || !Allowed(req.URL.Path) {
		return t.base.RoundTrip(req)
	}
	fr := req.Clone(req.Context())
	fr.Header.Set(HubHeader, t.hub)
	// Plain HTTP on the socket, whatever the hub's scheme: the forwarder
	// holds the TLS connection. The path (what a signature covers) is unchanged.
	fr.URL.Scheme, fr.Host = "http", req.URL.Host
	resp, err := t.unix.RoundTrip(fr)
	if err == nil && resp.Header.Get(ViaHeader) != "refused" {
		if resp.Header.Get(ViaHeader) == "unreachable" {
			// The forwarder could not reach the hub: its transport error,
			// in the words a direct call would have used.
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			return nil, errors.New(strings.TrimSpace(strings.TrimPrefix(string(b), "hubfwd: ")))
		}
		return resp, nil
	}
	if err == nil {
		resp.Body.Close()
	} else if !dialFailed(err) {
		return nil, err // it may have been sent: never twice
	}
	// Nobody there, or refused before forwarding: the direct road.
	if req.Body != nil && req.GetBody != nil {
		b, gerr := req.GetBody()
		if gerr != nil {
			return nil, gerr
		}
		req = req.Clone(req.Context())
		req.Body = b
	}
	return t.base.RoundTrip(req)
}

// dialFailed: the connection to the socket itself failed — nothing was sent.
func dialFailed(err error) bool {
	var op *net.OpError
	return errors.As(err, &op) && op.Op == "dial"
}
