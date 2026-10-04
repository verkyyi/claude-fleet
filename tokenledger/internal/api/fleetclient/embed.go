// Package fleetclient carries the client a colleague installs with one line
// (claude-fleet#1470): `curl -fsSL <hub>/install | sh`.
//
// The canonical files live in the repo's bin/ — bin/fleet, bin/fleet-login.py,
// bin/fleet-connect.py and bin/fleet-install.sh — where the shell selftests
// drive them. The Docker build's context is tokenledger/ alone, so the hub
// cannot embed bin/ directly; these are byte-for-byte copies, and two tests
// hold them to the originals: TestFleetClientMatchesBin here (Go) and
// bin/fleet-install-selftest.sh (shell). Edit in bin/, then copy:
//
//	cp bin/fleet bin/fleet-login.py bin/fleet-connect.py bin/fleet-install.sh tokenledger/internal/api/fleetclient/
package fleetclient

import "embed"

// Files are the client files the hub serves at /install/<name>, plus the
// installer template (fleet-install.sh, served at /install with the hub's
// URL filled in).
//
//go:embed fleet fleet-login.py fleet-connect.py fleet-install.sh
var Files embed.FS

// Names lists the files a client downloads, in install order.
var Names = []string{"fleet", "fleet-login.py", "fleet-connect.py"}

// Installer is the installer template's file name.
const Installer = "fleet-install.sh"

// HubPlaceholder is the token in the installer the hub replaces with its own
// URL, so the script a person pipes to sh already knows where it came from.
const HubPlaceholder = "__FLEET_HUB_URL__"
