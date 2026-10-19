package release

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// ReleaseJSON is the repo's top-level file that pins what a managed machine
// runs (claude-fleet#2334): each component's artifact name as a template.
const ReleaseJSON = "release.json"

// DefaultPlatforms: what a managed machine is (docs/MANAGED-NODE.md).
var DefaultPlatforms = []string{"darwin-arm64"}

// Pinned returns every artifact name release.json pins, its {version} {os}
// {arch} expanded for each "<os>-<arch>" platform — the files a release must
// carry for a managed machine to install it (claude-fleet#2631). The expansion
// is fleet-node-update.py's artifact_name.
func Pinned(releaseJSON []byte, platforms []string) ([]string, error) {
	var spec struct {
		Components map[string]struct {
			Version  string `json:"version"`
			Artifact string `json:"artifact"`
			// files the tool needs beside it, name → artifact template
			// (claude-fleet#3017: codex's codex-code-mode-host)
			Helpers map[string]string `json:"helpers"`
		} `json:"components"`
	}
	if err := json.Unmarshal(releaseJSON, &spec); err != nil {
		return nil, fmt.Errorf("%s: %w", ReleaseJSON, err)
	}
	seen := map[string]bool{}
	for _, p := range platforms {
		osn, arch, ok := strings.Cut(p, "-")
		if !ok || osn == "" || arch == "" {
			return nil, fmt.Errorf("platform %q: want <os>-<arch>", p)
		}
		for _, c := range spec.Components {
			r := strings.NewReplacer("{version}", c.Version, "{os}", osn, "{arch}", arch)
			tmpls := make([]string, 0, 1+len(c.Helpers))
			if c.Artifact != "" {
				tmpls = append(tmpls, c.Artifact)
			}
			for _, h := range c.Helpers {
				tmpls = append(tmpls, h)
			}
			for _, t := range tmpls {
				n := r.Replace(t)
				if !ValidArtifact(n) {
					return nil, fmt.Errorf("%s: bad artifact name %q", ReleaseJSON, n)
				}
				seen[n] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for n := range seen {
		out = append(out, n)
	}
	sort.Strings(out)
	return out, nil
}
