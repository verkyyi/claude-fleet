package api

import (
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
)

// One hub, two audiences (task PNWW). The hub answers on its own hosts
// (tokenman.io · www · core) and, through a trusted edge — the Shenzhen
// ingress that proxies hub.example.com, ccquota.example.com and
// *.preview.example.net to it with Host core.tokenman.io — on the hosts
// mainland users have always used. Three settings, each off when unset (byte
// for byte as before):
//
//	CCQUOTA_FORWARDED_HOSTS  the hosts the edge forwards (a "*.<suffix>" entry
//	                         is any name under it). A request whose
//	                         X-Forwarded-Host is one of them is taken at that
//	                         host, over https, from the LEFTMOST
//	                         X-Forwarded-For entry (the client the edge saw).
//	                         The front proxy (traefik's forwardedHeaders
//	                         .trustedIPs) is what keeps a stranger from
//	                         sending these: it passes X-Forwarded-* on only
//	                         from the edge and overwrites them for anyone else.
//	CCQUOTA_PUBLIC_HOSTS     host=origin pairs: the browser-facing address
//	                         (hubURL) of a request to that host; any other host
//	                         keeps CCQUOTA_FLEET_PUBLIC_URL.
//	CCQUOTA_SITE_HOSTS       host=edition pairs (on | sandbox): the site's
//	                         edition for that host; any other host keeps
//	                         CCQUOTA_SITE's.
//
// The edge is taken once, at the top of the chain (forwardedTrust): it
// rewrites r.Host, X-Forwarded-For / RemoteAddr and X-Forwarded-Proto, so every
// reader below — the preview host match, the client IP (chatClientIP,
// entryReportSource), isHTTPS, sameOrigin, the terminal's Origin check,
// hubURL — needs no change and a WebSocket upgrade passes as any request.

// forwardedTrust is the outermost handler: off (no CCQUOTA_FORWARDED_HOSTS) it
// is not in the chain at all; on, a request whose X-Forwarded-Host is a listed
// host is rewritten to it, any other passes untouched.
func (s *Server) forwardedTrust(next http.Handler) http.Handler {
	if len(s.ForwardedHosts) == 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fh := r.Header.Get("X-Forwarded-Host")
		if i := strings.IndexByte(fh, ','); i >= 0 {
			fh = fh[:i]
		}
		if h, ok := edgeHost(fh); ok && s.forwardedHost(h) {
			r.Host = h
			r.Header.Set("X-Forwarded-Host", h)
			r.Header.Set("X-Forwarded-Proto", "https")
			xff := r.Header.Get("X-Forwarded-For")
			if i := strings.IndexByte(xff, ','); i >= 0 {
				xff = xff[:i]
			}
			if a, err := netip.ParseAddr(strings.TrimSpace(xff)); err == nil {
				a = a.Unmap()
				r.Header.Set("X-Forwarded-For", a.String())
				r.RemoteAddr = net.JoinHostPort(a.String(), "0")
			}
		}
		next.ServeHTTP(w, r)
	})
}

// forwardedHost: h (a host, maybe with a port) is one CCQUOTA_FORWARDED_HOSTS
// names — exactly, or under a "*.<suffix>" entry.
func (s *Server) forwardedHost(h string) bool {
	if hh, _, err := net.SplitHostPort(h); err == nil {
		h = hh
	}
	for _, f := range s.ForwardedHosts {
		if suf, ok := strings.CutPrefix(f, "*."); ok {
			if strings.HasSuffix(h, "."+suf) && len(h) > len(suf)+1 {
				return true
			}
		} else if h == f {
			return true
		}
	}
	return false
}

// ParseForwardedHosts reads CCQUOTA_FORWARDED_HOSTS: space- (or comma-)
// separated DNS hosts, each optionally "*.<suffix>".
func ParseForwardedHosts(v string) ([]string, error) {
	var out []string
	for _, f := range strings.FieldsFunc(v, func(r rune) bool { return r == ' ' || r == ',' || r == '\t' || r == '\n' }) {
		f = strings.ToLower(f)
		if !previewDomainRE.MatchString(strings.TrimPrefix(f, "*.")) {
			return nil, errors.New("bad host " + f)
		}
		out = append(out, f)
	}
	return out, nil
}

// edgeHost is a forwarded host header, lower-cased, if it is a plain DNS host
// (an optional :port allowed) — never a path, a user or a space.
func edgeHost(v string) (string, bool) {
	v = strings.ToLower(strings.TrimSpace(v))
	if v == "" || len(v) > 260 {
		return "", false
	}
	for _, c := range v {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == ':') {
			return "", false
		}
	}
	return v, true
}

// reqHostname is r's host without its port, lower-cased: the key both host
// maps are read by.
func reqHostname(r *http.Request) string {
	h := r.Host
	if hh, _, err := net.SplitHostPort(h); err == nil {
		h = hh
	}
	return strings.ToLower(h)
}

// ParseHostMap reads a space- (or comma-) separated list of host=value pairs.
// Each host is a lower-cased DNS name; check vets (and may rewrite) the value.
func ParseHostMap(v string, check func(string) (string, error)) (map[string]string, error) {
	fields := strings.FieldsFunc(v, func(r rune) bool { return r == ' ' || r == ',' || r == '\t' || r == '\n' })
	if len(fields) == 0 {
		return nil, nil
	}
	out := make(map[string]string, len(fields))
	for _, f := range fields {
		h, val, ok := strings.Cut(f, "=")
		h = strings.ToLower(h)
		if !ok || !previewDomainRE.MatchString(h) {
			return nil, errors.New("bad host=value pair " + f)
		}
		got, err := check(val)
		if err != nil {
			return nil, errors.New(h + ": " + err.Error())
		}
		out[h] = got
	}
	return out, nil
}

// PublicHostOrigin vets a CCQUOTA_PUBLIC_HOSTS value: an http(s) origin, no
// path, query or user.
func PublicHostOrigin(v string) (string, error) {
	u, err := url.Parse(v)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
		(u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("want an origin like https://example.com, got " + v)
	}
	return u.Scheme + "://" + u.Host, nil
}

// SiteHostEdition vets a CCQUOTA_SITE_HOSTS value: on (the default edition,
// "") or sandbox.
func SiteHostEdition(v string) (string, error) {
	switch strings.ToLower(v) {
	case "on":
		return "", nil
	case SiteEditionSandbox:
		return SiteEditionSandbox, nil
	}
	return "", errors.New("edition is on or sandbox, got " + v)
}

// publicHostURL is the origin CCQUOTA_PUBLIC_HOSTS names for r's host, or "".
func (s *Server) publicHostURL(r *http.Request) string {
	if len(s.PublicHosts) == 0 {
		return ""
	}
	return s.PublicHosts[reqHostname(r)]
}

// siteEditionFor is r's site edition: CCQUOTA_SITE_HOSTS's for its host, else
// CCQUOTA_SITE's.
func (s *Server) siteEditionFor(r *http.Request) string {
	if s.portalHost(r) {
		return SiteEditionSandbox
	}
	if r != nil && len(s.SiteHosts) > 0 {
		if e, ok := s.SiteHosts[reqHostname(r)]; ok {
			return e
		}
	}
	return s.SiteEdition
}
