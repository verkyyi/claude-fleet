package api

import "net/http"

// /apply itself is access_requests.go (claude-fleet#4051); the sign-in page
// half of the way there is here (claude-fleet#4049).

// applyNext is the one ?next= the sign-in page recognises: a fixed match,
// so the page never reflects a query string.
const applyNext = ApplyPath

// toApply: /signin was reached on the way to apply.
func toApply(r *http.Request) bool { return r.URL.Query().Get("next") == applyNext }
