package api

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// ConfigurePortal is opt-in. Origins are separate from the machine address and
// from request-local OAuth callback URLs (whose cookies belong to that host).
func (s *Server) ConfigurePortal(origin, aliases, wechat string) error {
	if strings.TrimSpace(origin) == "" {
		return nil
	}
	origin = strings.TrimSpace(origin)
	if !strings.Contains(origin, "://") {
		origin = "https://" + origin
	}
	o, err := PublicHostOrigin(origin)
	if err != nil || !strings.HasPrefix(o, "https://") {
		return fmt.Errorf("CCQUOTA_PORTAL must be an HTTPS origin")
	}
	hosts, err := ParseForwardedHosts(aliases)
	if err != nil {
		return fmt.Errorf("CCQUOTA_PORTAL_ALIASES: %w", err)
	}
	u, _ := url.Parse(o)
	for _, h := range hosts {
		if h == strings.ToLower(u.Hostname()) {
			return fmt.Errorf("CCQUOTA_PORTAL_ALIASES contains the portal itself")
		}
		if strings.Contains(h, "*") {
			return fmt.Errorf("CCQUOTA_PORTAL_ALIASES requires exact hosts")
		}
	}
	wx := ""
	if wechat != "" {
		wx, err = PublicHostOrigin(wechat)
		if err != nil || !strings.HasPrefix(wx, "https://") {
			return fmt.Errorf("CCQUOTA_WECHAT_PUBLIC_URL must be an HTTPS origin")
		}
	}
	if wx == o {
		return fmt.Errorf("CCQUOTA_WECHAT_PUBLIC_URL must differ from the portal")
	}
	s.PortalURL, s.PortalAliases, s.WeChatPublicURL = o, hosts, wx
	s.Site = true
	return nil
}

func (s *Server) portalHost(r *http.Request) bool {
	if s.PortalURL == "" || r == nil {
		return false
	}
	u, _ := url.Parse(s.PortalURL)
	return reqHostname(r) == u.Hostname()
}

// Only human page routes move. Unknown paths, APIs, upgrades, authentication
// callbacks and install/client downloads keep their existing handlers.
func portalPage(p string) bool {
	if strings.HasPrefix(p, "/auth/") || strings.HasPrefix(p, "/fleet/") {
		return false
	}
	for _, base := range []string{"/app", "/admin", "/apply", "/signin", "/try", "/i", "/docs", "/en", "/zh", "/terms", "/privacy", "/site"} {
		if p == base || strings.HasPrefix(p, base+"/") {
			return true
		}
	}
	if p == "/" || isAppPage(p) {
		return true
	}
	for _, page := range consolePages {
		if p == page.old || (page.under && strings.HasPrefix(p, page.old)) {
			return true
		}
	}
	return false
}

func (s *Server) portal(next http.Handler) http.Handler {
	if s.PortalURL == "" {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			// Start silent OAuth where the registered relay returns its host-only cookie.
			if s.portalHost(r) && inWeChat(r) && r.URL.Path == "/auth/wechat/start" && s.WeChatPublicURL != "" {
				w.Header().Set("Cache-Control", "no-store")
				http.Redirect(w, r, s.WeChatPublicURL+r.URL.RequestURI(), http.StatusFound)
				return
			}
			alias := false
			for _, h := range s.PortalAliases {
				if reqHostname(r) == h {
					alias = true
					break
				}
			}
			if alias && portalPage(r.URL.Path) && r.Header.Get("Upgrade") == "" {
				// A shared cache must never send WeChat to the unregistered domain.
				w.Header().Add("Vary", "User-Agent")
				w.Header().Set("Cache-Control", "private, no-store")
				if !strings.Contains(strings.ToLower(r.UserAgent()), "micromessenger") {
					http.Redirect(w, r, s.PortalURL+r.URL.RequestURI(), http.StatusMovedPermanently)
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

func localeOfPage(r *http.Request) string {
	if loc, ok := r.Context().Value(pageLangKey{}).(string); ok {
		return loc
	}
	if loc := parseLang(r.URL.Query().Get("lang")); loc != "" {
		return loc
	}
	if c, err := r.Cookie(langCookie); err == nil {
		if loc := parseLang(c.Value); loc != "" {
			return loc
		}
	}
	return i18n.FromAcceptLanguage(r.Header.Get("Accept-Language"))
}

// humanURL is for invitations and outgoing mail, not authentication callbacks.
func (s *Server) humanURL(r *http.Request) string {
	if s.PortalURL != "" {
		return s.PortalURL
	}
	if r != nil {
		return s.hubURL(r)
	}
	return strings.TrimRight(s.FleetPublicURL, "/")
}

func (s *Server) wechatURL(r *http.Request) string {
	if s.PortalURL != "" && s.WeChatPublicURL != "" {
		return s.WeChatPublicURL
	}
	if r != nil {
		return s.nodeHubURL(r)
	}
	return strings.TrimRight(s.FleetPublicURL, "/")
}

// Both template links and customer-service text stay on the WeChat origin;
// email fallback still receives the original canonical message.
func (s *Server) wechatNotice(text string) string {
	if s.PortalURL == "" || s.WeChatPublicURL == "" {
		return text
	}
	return strings.ReplaceAll(text, s.PortalURL+"/", s.WeChatPublicURL+"/")
}
