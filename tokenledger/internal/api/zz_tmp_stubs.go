package api

import "net/http"

// TEMP: until C1 (#4049) and C3 (#4051) land — removed at rebase.
const applicantPath = "/apply"

func toApply(r *http.Request) bool                                                   { return r.URL.Query().Get("next") == "/apply" }
func (s *Server) issueApplicant(w http.ResponseWriter, r *http.Request, k, sub, d string) {}
