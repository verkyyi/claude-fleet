package api

import (
	"net/http"
	"net/url"
	"path"
	"strings"
)

// A console page opened signed out — a forwarded card, a notice, a bookmark
// (/app/s/D7KQ?view=term) — is where the sign-in comes back to (claude-fleet
// T842): viewerOr remembers it in the return cookie (entryReturnCookie) before
// it sends the browser to /app/signin, and loginReturn — the one landing every
// way in (GitHub, WeChat, the service account's silent road, mail) goes
// through — sends the browser there. Only a same-site path under AppPrefix is
// ever remembered or followed: never another host, never a scheme. Whose page
// it is stays the page's to say — someone else's session is still refused there.

// appReturnMax bounds what the cookie carries.
const appReturnMax = 512

// appReturnOK says whether v is a console address the sign-in may send a
// browser back to.
func appReturnOK(v string) bool {
	if strings.HasPrefix(v, previewAuthorize+"?") {
		return previewReturnOK(v)
	}
	if len(v) > appReturnMax || !strings.HasPrefix(v, AppPrefix+"/") ||
		strings.Contains(v, "//") || strings.Contains(v, `\`) {
		return false
	}
	for i := 0; i < len(v); i++ {
		c := v[i]
		if c < 0x21 || c > 0x7e || c == '"' || c == ';' || c == ',' || c == '#' {
			return false
		}
	}
	u, err := url.Parse(v)
	if err != nil || u.Scheme != "" || u.Host != "" || u.User != nil || u.Opaque != "" || path.Clean(u.Path) != u.Path {
		return false
	}
	switch u.Path {
	case AppPrefix + "/signin", AppPrefix + "/logout":
		return false
	}
	return !strings.HasPrefix(u.Path, AppPrefix+"/assets/")
}

// rememberAppReturn is viewerOr's signed-out step for a page: a console
// address asked for before signing in is where loginReturn sends the browser
// after. The address the browser asked for, prefix and query included.
func rememberAppReturn(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return
	}
	to := stripToken(r)
	if !appReturnOK(to) {
		return
	}
	http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: to, Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r), MaxAge: int(loginCookieTTL.Seconds())})
}
