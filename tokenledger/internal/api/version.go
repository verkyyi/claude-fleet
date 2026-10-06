package api

import (
	"net/http"
	"regexp"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// GET /version (claude-fleet#1696) — the build stamp and the git commit it
// names. The image's tag (`prod-<sha>`) is only readable with cluster access,
// and the tag-to-commit mapping is a naming convention; this answers "which
// commit is the hub running" for anyone, and fleet-doctor compares it with
// refs/tags/stable. The stamp is the Dockerfile's VERSION build arg — the
// runbook passes `prod-$(git rev-parse --short HEAD)`, the Makefile `git
// describe --always` — so the commit is the hex run that ends it. A build
// stamped without one (`docker`, `dev`) reports commit "" and the doctor says
// unknown, never current.
//
// It also says which CLIENT this build hands out (claude-fleet#1722), for a
// client's own start to compare with what it has: client_version (the digest
// of the files /install serves — fleetclient.Version), client_compat and
// min_client_compat (fleetclient.Compat / MinCompat). Behind client_version →
// the client updates in the background for its next start; below
// min_client_compat → it updates before it opens.

var versionCommitRe = regexp.MustCompile(`(?:^|[-_.g])([0-9a-f]{7,40})(?:-dirty)?$`)

// VersionCommit extracts the git commit a build stamp names, or "".
func VersionCommit(v string) string {
	m := versionCommitRe.FindStringSubmatch(v)
	if m == nil {
		return ""
	}
	return m[1]
}

func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	v := s.Version
	if v == "" {
		v = "dev"
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"version":           v,
		"commit":            VersionCommit(v),
		"client_version":    fleetclient.Version,
		"client_compat":     fleetclient.Compat,
		"min_client_compat": fleetclient.MinCompat,
	})
}
