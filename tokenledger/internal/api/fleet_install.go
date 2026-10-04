package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// One-line install (claude-fleet#1470, #1486):
//
//	curl -fsSL <hub>/install | sh
//
// GET /install is the installer with this hub's URL filled in; it fetches
// GET /install/manifest — the list of client files this build embeds
// (fleetclient/manifest: `fleet`, what it dispatches to, and the shell, #1484)
// — then GET /install/<path> for each, into ~/.local/share/claude-fleet in the
// repo's own bin/ + conf/ layout, links ~/.local/bin/fleet to it, writes the
// hub's URL to ~/.config/claude-fleet/hub.json, and runs `fleet`. The files
// are the ones this hub's image was built from, so client and hub are always
// the same version — a hub upgrade is picked up by running the one line again.
//
// Public on purpose, like the CA's public key: scripts anyone could read on
// GitHub, carrying no credential. They are served only when the hub can
// actually sign someone in without them having anything yet — a CA and WeCom
// sign-in — because that is what the first `fleet` needs.

// InstallCommand is the line people copy, for this hub.
func (s *Server) InstallCommand(r *http.Request) string {
	return "curl -fsSL " + s.hubURL(r) + "/install | sh"
}

func (s *Server) installReady() bool {
	return s.SSHCA != nil && s.SSO.ready()
}

// handleInstall serves GET /install: the installer, hub URL filled in.
func (s *Server) handleInstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if !s.installReady() {
		http.NotFound(w, r)
		return
	}
	tmpl, err := fleetclient.Files.ReadFile(fleetclient.Installer)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "installer missing from this build")
		return
	}
	body := strings.ReplaceAll(string(tmpl), fleetclient.HubPlaceholder, s.hubURL(r))
	w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write([]byte(body))
}

// handleInstallFile serves GET /install/<path>: the manifest, or one file it
// lists (bin/fleet, bin/fleet-shell.sh, conf/tmux-shell.conf, …), with its
// SHA-256 in X-Ccquota-Sha256 so the installer can refuse a truncated download.
// The template itself and anything else in the package are not downloads.
func (s *Server) handleInstallFile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if !s.installReady() {
		http.NotFound(w, r)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/install/")
	if !fleetclient.Serves(name) {
		http.NotFound(w, r)
		return
	}
	b, err := fleetclient.Files.ReadFile(name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	sum := sha256.Sum256(b)
	w.Header().Set("Content-Type", installContentType(name))
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Ccquota-Sha256", hex.EncodeToString(sum[:]))
	_, _ = w.Write(b)
}

// installContentType: python for .py, plain text for the manifest and a tmux
// conf, a shell script for the rest (bin/fleet and the .sh files).
func installContentType(name string) string {
	switch {
	case strings.HasSuffix(name, ".py"):
		return "text/x-python; charset=utf-8"
	case name == fleetclient.ManifestName, strings.HasSuffix(name, ".conf"):
		return "text/plain; charset=utf-8"
	}
	return "text/x-shellscript; charset=utf-8"
}
