package api

import (
	"net/http"
	"regexp"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/api/fleetclient"
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
//
// With a StableSource (claude-fleet#1805) client_version is stable's commit,
// beside `stable` (the same) and `client_url`, where its files are — so moving
// stable upgrades every client without redeploying this hub (fleet_stable.go).
// compat / min_client_compat stay this hub's own: the protocol it speaks.
//
// One release line (claude-fleet#4671): there is no client_version_macos — a
// Mac follows client_version like every other computer.

// HubCapabilities is /version's `capabilities`: one word per road a node may
// take only when the hub has it.
var HubCapabilities = []string{"task_ids", "task_state"}

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
	out := map[string]any{
		"version":           v,
		"commit":            VersionCommit(v),
		"client_version":    fleetclient.Version,
		"client_compat":     fleetclient.Compat,
		"min_client_compat": fleetclient.MinCompat,
	}
	if sha := s.stableCommit(); sha != "" {
		// a stable still with its canary (claude-fleet#4915): the rest are
		// handed the release before it
		if held, ok := s.followerStable(r.URL.Query().Get("machine")); ok && held != "" {
			sha = held
		}
		out["client_version"] = sha
		out["stable"] = sha
		out["client_url"] = s.hubURL(r) + "/install/stable/" + sha
	}
	// why stable is not being followed, when the operator can fix it — GitHub's
	// rate limit on a hub in China (claude-fleet#4009)
	if p := s.Stable.Problem(); p != "" {
		out["stable_problem"] = p
	}
	// where stable comes from (claude-fleet#4847): release · upstream · github ·
	// image — image when nothing is handed out but this build's own client
	src := s.Stable.Source()
	if _, ok := out["stable"]; !ok {
		if known := s.stableKnown(); known != "" {
			// known, its files not here yet: the image's client until they are
			if _, ok := out["stable_problem"]; !ok {
				out["stable_problem"] = "stable " + known[:7] + " is known but its files are not on this hub yet — handing out the image's client meanwhile"
			}
		}
		src = stableSrcImage
	}
	out["stable_source"] = src
	// what this hub can do, for a node to choose its road by (never by a
	// version number): task_ids — a task record has its ID from its first
	// moment and every /tasks/<ref> takes its code, its ID or T<n> (EPIC T644 C1);
	// task_state — a record's state is its columns, written the moment its ID's
	// result lands, so a list's state needs no read-time projection (C6)
	out["capabilities"] = HubCapabilities
	writeJSON(w, http.StatusOK, out)
}
