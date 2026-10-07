package api

import (
	"context"
	"net/http"
	"strings"
)

// viewerKey carries the identity the gate admitted from viewerOnly out to the
// access log.
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

// wantsHTML distinguishes a browser navigation from an API call.
//
// Navigations send an Accept that prefers HTML; fetch/XHR from our own
// dashboard asks for JSON and would rather have the 401 (it can then show a
// sign-in prompt itself instead of trying to render a login page into a table).
func wantsHTML(r *http.Request) bool {
	if r.Header.Get("X-Requested-With") != "" {
		return false
	}
	return strings.Contains(r.Header.Get("Accept"), "text/html")
}

func isHTTPS(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}
