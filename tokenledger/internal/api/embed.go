package api

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"strings"
)

// The live embed: an iframe-able page that keeps a badge current.
//
// An <img> is a snapshot and can never re-fetch itself. A page can. This one
// polls the raw figure and, only when it has actually changed, swaps its badge
// for one rendered ?from=<the previous value> -- so the wheels roll the real
// difference. Nothing here extrapolates; if the hub has not measured a new
// number, nothing moves except the character.
//
// It lives behind the same gate as the badges (--public-badges), because it
// exposes exactly what they do and nothing more.

const embedPage = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>%s</title>
<style>html,body{margin:0;padding:0;background:transparent}img{display:block;max-width:100%%;height:auto}</style>
</head><body>
<img id="b" alt="%s" src="%s">
<script>
"use strict";
(() => {
  const img = document.getElementById("b");
  const badge = %s;          // this login's badge path, no extension
  const params = %s;         // the caller's params, forwarded verbatim
  const every = Math.max(5, %d) * 1000;
  let last = null;
  async function tick() {
    try {
      const r = await fetch(badge + ".json?format=raw&" + params, { cache: "no-store" });
      if (!r.ok) return;
      const d = await r.json();
      if (typeof d.tokens !== "number") return;
      if (last === null) { last = d.tokens; return; }
      if (d.tokens === last) return;
      // Roll from the value we were showing to the one we just measured.
      img.src = badge + ".svg?" + params + "&from=" + last + "&v=" + d.tokens;
      last = d.tokens;
    } catch (e) { /* a missed poll is a still badge, not an error */ }
  }
  tick();
  setInterval(tick, every);
})();
</script>
</body></html>
`

// serveEmbed handles /embed/u/<login> and /embed/team/<team>.
func (s *Server) serveEmbed(w http.ResponseWriter, r *http.Request) {
	var kind, name string
	switch {
	case strings.HasPrefix(r.URL.Path, "/embed/u/"):
		kind, name = "u", strings.TrimPrefix(r.URL.Path, "/embed/u/")
	case strings.HasPrefix(r.URL.Path, "/embed/team/"):
		kind, name = "team", strings.TrimPrefix(r.URL.Path, "/embed/team/")
	}
	if name == "" || strings.Contains(name, "/") {
		http.NotFound(w, r)
		return
	}

	// Forward every badge parameter except the poll interval, which is ours.
	q := r.URL.Query()
	every := 30
	if n, err := fmt.Sscanf(q.Get("every"), "%d", &every); n != 1 || err != nil {
		every = 30
	}
	q.Del("every")
	q.Del("from")
	q.Del("v")
	params := q.Encode()

	badgePath := "/badge/" + kind + "/" + url.PathEscape(name)
	first := badgePath + ".svg"
	if params != "" {
		first += "?" + params
	}
	title := name + " \u00b7 Claude Code tokens"

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	// The badge path and params go into the script as JSON string literals,
	// and everything else is HTML-escaped: the name comes off the URL.
	fmt.Fprintf(w, embedPage,
		html.EscapeString(title), html.EscapeString(title), html.EscapeString(first),
		jsString(badgePath), jsString(params), every)
}

// jsString renders s as a JavaScript string literal safe inside <script>.
// encoding/json escapes quotes and backslashes, and by default also turns
// < > & into \u escapes, which is what keeps "</script>" in a login inert.
func jsString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
