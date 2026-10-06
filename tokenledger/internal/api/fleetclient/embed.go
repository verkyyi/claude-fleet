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
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"strings"
)

// Files holds the manifest and every file it lists, at its repo-relative path:
// the client's bin/ + conf/, and the Agent configuration package (#1725) —
// hooks/ commands/ skills/ mod/, its files listed in the manifest's generated
// `agent bundle` block. `all:` keeps mod/fleet/.claude-plugin/ (a dot directory).
//
//go:embed manifest bin conf hooks commands skills all:mod
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
	Version = Digest(func(name string) ([]byte, error) { return Files.ReadFile(name) }, Names)
}

// Version is this build's CLIENT version (claude-fleet#1722): a digest of
// every file a client downloads, so it changes exactly when what a colleague
// would install changes — and a client asks GET /version whether its own
// (recorded by the installer in <install home>/.client-version) is still it.
// A digest has no order; "older" is Compat's job.
var Version string

// Compat is the client↔hub protocol level of the client this build serves,
// and MinCompat the lowest level this hub still serves (claude-fleet#1722).
// A client whose level is below MinCompat updates BEFORE it opens; one that is
// only behind Version updates in the background and switches on its next
// start. The promise is that a hub serves the current client and the one
// before it — so MinCompat never rises above Compat-1 (TestClientCompatPromise):
// a change an older client cannot survive bumps Compat, and the NEXT one may
// raise MinCompat. bin/fleet-client-update.sh carries the same Compat for a
// client that has none recorded.
const (
	Compat    = 1
	MinCompat = 1
)

// Digest is the client version of a file list: the first 12 hex of the
// SHA-256 over "<name>\x00<sha256 hex of the file>\n" for each, in order.
func Digest(read func(string) ([]byte, error), names []string) string {
	h := sha256.New()
	for _, n := range names {
		b, err := read(n)
		if err != nil {
			continue
		}
		sum := sha256.Sum256(b)
		h.Write([]byte(n + "\x00" + hex.EncodeToString(sum[:]) + "\n"))
	}
	return hex.EncodeToString(h.Sum(nil))[:12]
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
