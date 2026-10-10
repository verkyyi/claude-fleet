package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// The stand-alone fleet-debug (claude-fleet#2892, EPIC #2889 C3):
//
//	curl -fsSL <hub>/debug | sh -s report
//
// for a computer whose fleet never installed, or broke: GET /debug is
// bin/fleet-debug with this hub's URL filled in, its version stamped in its
// header, and the four files its bundle needs (C1's bundle script, the awk
// redactor, the shape table, the collect list) spliced in where the script
// carries `__FLEET_DEBUG_EMB__ <path>` — so the one-line copy scrubs with the
// SAME table as an installed client, never a second one. Every piece comes from
// one place: stable's commit when this hub hands stable out (the same version
// the client installs, 共同约定 4), else the client this image was built with.
// GET /debug.sha256 is the SHA-256 of exactly the bytes /debug serves now.
//
// Public on purpose, like /install: scripts anyone could read on GitHub,
// carrying no credential. Off — no CCQUOTA_FLEET_DEBUG_DIR — neither route
// exists (TestDebugOffAddsNothing).
const (
	DebugScriptPath    = "/debug"
	DebugScriptSumPath = "/debug.sha256"

	debugScriptName         = "bin/fleet-debug"
	debugEmbMarker          = "__FLEET_DEBUG_EMB__ "
	debugEmbDelim           = "FLEET_DEBUG_EMB_EOF"
	debugVersionPlaceholder = "__FLEET_DEBUG_VERSION__"
)

// debugScriptKit is what /debug may splice into the script — nothing else.
var debugScriptKit = []string{
	"bin/fleet-doctor-bundle.sh",
	"bin/fleet-redact.awk",
	"conf/secret-shapes.list",
	"conf/debug-collect.list",
}

func (s *Server) handleDebugScript(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	read, ver, ok := s.debugScriptSource(r.Context())
	if !ok {
		httpError(w, http.StatusServiceUnavailable, "this hub was built without its client — pack it (bin/fleet-client-pack.sh) and rebuild")
		return
	}
	body, err := buildDebugScript(read, s.hubURL(r), ver)
	if err != nil {
		httpError(w, http.StatusBadGateway, "fleet-debug: "+err.Error())
		return
	}
	sum := sha256.Sum256(body)
	hexsum := hex.EncodeToString(sum[:])
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Ccquota-Sha256", hexsum)
	w.Header().Set("X-Fleet-Debug-Version", ver)
	if r.URL.Path == DebugScriptSumPath {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(w, "%s  fleet-debug\n", hexsum)
		return
	}
	w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
	_, _ = w.Write(body)
}

// debugScriptSource: where /debug reads its files — stable's commit when it
// carries fleet-debug, else this image's packed client; ok=false when neither.
func (s *Server) debugScriptSource(ctx context.Context) (func(string) ([]byte, error), string, bool) {
	if sha := s.stableCommit(); sha != "" {
		read := func(p string) ([]byte, error) { return s.Stable.File(ctx, sha, p) }
		if _, err := read(debugScriptName); err == nil {
			return read, sha[:12], true
		}
	}
	if !fleetclient.Packed {
		return nil, "", false
	}
	ver := fleetclient.Version
	if len(ver) > 12 {
		ver = ver[:12]
	}
	return fleetclient.Files.ReadFile, "client-" + ver, true
}

// buildDebugScript fills bin/fleet-debug: the hub, the version, and each kit
// file at its marker line. A marker for a file not in the kit, a kit file
// missing, or one carrying a line that would end its heredoc early, is an
// error — never a half-spliced script.
func buildDebugScript(read func(string) ([]byte, error), hub, ver string) ([]byte, error) {
	tmpl, err := read(debugScriptName)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", debugScriptName, err)
	}
	if !strings.HasPrefix(string(tmpl), "#!") {
		return nil, errors.New(debugScriptName + " is not a script")
	}
	var b strings.Builder
	done := map[string]bool{}
	lines := strings.SplitAfter(string(tmpl), "\n")
	for _, line := range lines {
		path, isMark := strings.CutPrefix(strings.TrimSuffix(line, "\n"), debugEmbMarker)
		if !isMark {
			b.WriteString(line)
			continue
		}
		if !containsStr(debugScriptKit, path) {
			return nil, fmt.Errorf("%s splices %q, which is not a kit file", debugScriptName, path)
		}
		f, err := read(path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		for _, l := range strings.Split(string(f), "\n") {
			if strings.HasPrefix(l, debugEmbDelim) {
				return nil, fmt.Errorf("%s has a line that would end its heredoc (%s…)", path, debugEmbDelim)
			}
		}
		b.Write(f)
		if len(f) > 0 && f[len(f)-1] != '\n' {
			b.WriteByte('\n')
		}
		done[path] = true
	}
	for _, p := range debugScriptKit {
		if !done[p] {
			return nil, fmt.Errorf("%s has no place for %s", debugScriptName, p)
		}
	}
	out := strings.ReplaceAll(b.String(), fleetclient.HubPlaceholder, hub)
	return []byte(strings.ReplaceAll(out, debugVersionPlaceholder, ver)), nil
}
