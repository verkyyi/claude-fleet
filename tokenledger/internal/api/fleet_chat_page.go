package api

import (
	"io"
	"io/fs"
	"net/http"
	"path"
	"strings"
)

// The web chat's page on the website (claude-fleet#3646, EPIC #3642 C4): /chat/,
// the same extras/web-chat/ui the conversation service serves, built for here
// (`vite build --mode site` — base /chat/, its API ChatPathPrefix) by
// bin/web-chat-pack.sh into web/dist/chat/ before the image is built, so the
// repo keeps one source and no copy. Only a signed-in person reaches it: the
// gate sends anyone else to /app/signin and the sign-in brings them back here.
// Every byte is the hub's own (chatCSP): no CDN, no other origin.

// ChatPagePath is the page; its files live under it (/chat/assets/…).
const ChatPagePath = "/chat/"

// chatPageDir is where the pack puts the build inside the UI's file system.
const chatPageDir = "chat"

// chatCSP is the page's policy — the conversation service's own, same origin only.
const chatCSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " +
	"font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// handleChatPage serves ChatPagePath: index.html for the page itself, else the
// build file the path names.
func (s *Server) handleChatPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	h := w.Header()
	h.Set("Content-Security-Policy", chatCSP)
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Robots-Tag", "noindex, nofollow")
	var page fs.FS
	if s.UI != nil {
		if sub, err := fs.Sub(s.UI, chatPageDir); err == nil {
			if _, err := fs.Stat(sub, "index.html"); err == nil {
				page = sub
			}
		}
	}
	if page == nil {
		httpError(w, http.StatusNotFound, "this hub was built without the chat page (bin/web-chat-pack.sh)")
		return
	}
	name := strings.TrimPrefix(r.URL.Path, ChatPagePath)
	if name == "" {
		name = "index.html"
	}
	if name != path.Clean(name) || strings.HasPrefix(name, "/") || strings.HasPrefix(name, "..") {
		http.NotFound(w, r)
		return
	}
	f, err := page.Open(name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		http.NotFound(w, r)
		return
	}
	rs, ok := f.(io.ReadSeeker)
	if !ok {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	if strings.HasPrefix(name, "assets/") {
		// the build names each asset by its content
		h.Set("Cache-Control", "private, max-age=31536000, immutable")
	} else {
		h.Set("Cache-Control", "no-cache")
	}
	http.ServeContent(w, r, name, st.ModTime(), rs)
}
