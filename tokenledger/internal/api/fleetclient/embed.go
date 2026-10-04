// Package fleetclient carries the client a colleague installs with one line
// (claude-fleet#1470, #1486): `curl -fsSL <hub>/install | sh` — `fleet`, the
// two it dispatches to, and the SHELL (#1484) it opens when tmux is there.
//
// The canonical files live in the repo's bin/ and conf/, where the shell
// selftests drive them. The Docker build's context is tokenledger/ alone, so
// the hub cannot embed them from there; this directory holds byte-for-byte
// copies in the same bin/ + conf/ layout, and ONE list — `manifest` — says
// which (and which is the installer template). Two tests hold the copies to
// the originals, both reading the manifest: TestFleetClientMatchesBin here (Go)
// and bin/fleet-install-selftest.sh leg A (shell). Edit in bin/ or conf/, then:
//
//	bin/fleet-client-mirror.sh          # copy every manifest file over
//	bin/fleet-client-mirror.sh --check  # what the two tests assert
package fleetclient

import (
	"bufio"
	"bytes"
	"embed"
	"strings"
)

// Files holds the manifest and every file it lists, at its repo-relative path.
//
//go:embed manifest bin conf
var Files embed.FS

// ManifestName is the manifest's own path. The hub serves it at
// /install/manifest, so the installer walks the very list this build embeds.
const ManifestName = "manifest"

// Installer is the installer template's path (the manifest's `installer`
// line), served at /install with HubPlaceholder replaced by the hub's URL —
// never as a download of its own.
var Installer string

// Names lists the files a client downloads — every manifest path but the
// installer's — in install order; each is served at /install/<name>.
var Names []string

// HubPlaceholder is the token in the installer the hub replaces with its own
// URL, so the script a person pipes to sh already knows where it came from.
const HubPlaceholder = "__FLEET_HUB_URL__"

func init() {
	b, err := Files.ReadFile(ManifestName)
	if err != nil {
		panic("fleetclient: manifest missing from the build: " + err.Error())
	}
	Installer, Names = ParseManifest(b)
	if Installer == "" {
		panic("fleetclient: the manifest names no `installer` line")
	}
}

// ParseManifest reads a manifest: one repo-relative path per line, an optional
// second word `installer` marking the template, `#` comments and blank lines
// ignored. It returns the installer's path and the download list in order.
func ParseManifest(b []byte) (installer string, names []string) {
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) > 1 && f[1] == "installer" {
			installer = f[0]
			continue
		}
		names = append(names, f[0])
	}
	return installer, names
}

// Serves says whether /install/<name> is a download: the manifest itself or a
// file it lists. The template and anything else in the package are not.
func Serves(name string) bool {
	if name == ManifestName {
		return true
	}
	for _, n := range Names {
		if n == name {
			return true
		}
	}
	return false
}
