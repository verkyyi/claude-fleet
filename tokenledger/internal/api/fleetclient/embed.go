// Package fleetclient carries the client a colleague installs with one line
// (claude-fleet#1470, #1486): `curl -fsSL <hub>/install | sh` — `fleet`, the
// two it dispatches to, and the SHELL (#1484) it opens when tmux is there.
//
// The files live ONCE, in the repo's bin/ conf/ hooks/ commands/ skills/ mod/,
// where the shell selftests drive them (claude-fleet#1803). //go:embed cannot
// reach ../bin, so a hub build packs them first: bin/fleet-client-pack.sh copies
// every file `manifest` lists into pack/ (gitignored, only pack/doc.go is
// committed), at its repo-relative path. ONE list — `manifest` — says which
// (and which is the installer template); TestFleetClientMatchesBin holds it to
// the repo. Edit in bin/ or conf/, then build with:
//
//	bin/fleet-client-pack.sh && docker build -t ccquota tokenledger/
//	bin/fleet-client-pack.sh --check   # pack/ is exactly the repo's files
//
// A build with no pack compiles and runs; it serves no client (Packed false).
package fleetclient

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"strings"
)

// raw holds the manifest and the pack: every file the manifest lists, under
// pack/ at its repo-relative path — the client's bin/ + conf/, and the Agent
// configuration package (#1725) — hooks/ commands/ skills/ mod/, its files
// listed in the manifest's generated `agent bundle` block. `all:` keeps
// mod/fleet/.claude-plugin/ (a dot directory).
//
//go:embed manifest all:pack
var raw embed.FS

// Files is the client at its repo-relative paths: the manifest, and every file
// it lists (read out of pack/). It is what /install and /install/<path> serve.
var Files = clientFS{pack: mustSub(raw, "pack")}

// PackPlaceholder is pack/'s one committed file — never part of the client.
const PackPlaceholder = "doc.go"

// Packed says this build carries the client: every file the manifest lists was
// packed. False for a plain `go build` with no bin/fleet-client-pack.sh before
// it — the hub then answers 503 on /install and an empty client_version.
var Packed bool

type clientFS struct{ pack fs.FS }

func (c clientFS) Open(name string) (fs.File, error) {
	if name == ManifestName {
		return raw.Open(ManifestName)
	}
	if name == PackPlaceholder {
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
	}
	return c.pack.Open(name)
}

func (c clientFS) ReadFile(name string) ([]byte, error) {
	switch name {
	case ManifestName:
		return raw.ReadFile(ManifestName)
	case PackPlaceholder:
		return nil, &fs.PathError{Op: "read", Path: name, Err: fs.ErrNotExist}
	}
	return fs.ReadFile(c.pack, name)
}

func mustSub(f fs.FS, dir string) fs.FS {
	s, err := fs.Sub(f, dir)
	if err != nil {
		panic("fleetclient: " + err.Error())
	}
	return s
}

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
	Packed = true
	for _, n := range append([]string{Installer}, Names...) {
		if _, err := fs.Stat(Files, n); err != nil {
			Packed = false
			break
		}
	}
	if Packed {
		Version = Digest(func(name string) ([]byte, error) { return Files.ReadFile(name) }, Names)
	}
}

// Version is this build's CLIENT version (claude-fleet#1722): a digest of
// every file a client downloads, so it changes exactly when what a colleague
// would install changes — and a client asks GET /version whether its own
// (recorded by the installer in <install home>/.client-version) is still it.
// A digest has no order; "older" is Compat's job. Empty when !Packed.
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

// VendorTmux is the static tmux packed for <platform> (macos-arm64,
// linux-x86_64, … — conf/vendor-tmux.lock's names; claude-fleet#2260), or nil:
// bin/fleet-client-pack.sh puts it at pack/vendor/tmux-<platform>. It rides in
// /install/bundle.tar.gz as vendor/tmux; it is never a download of its own.
func VendorTmux(platform string) []byte {
	if platform == "" || strings.ContainsAny(platform, "/.") {
		return nil
	}
	b, err := fs.ReadFile(Files.pack, "vendor/tmux-"+platform)
	if err != nil {
		return nil
	}
	return b
}
