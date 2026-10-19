// Command ccquota, the node's build (claude-fleet#4812, EPIC #4810 C2): every
// subcommand a machine, a pod or bin/ runs (agent/cli; commands.txt is the
// list) and none of the hub's — no database, dashboard or MCP server compiled
// in. The combined tokenledger/hub/cmd/ccquota runs the same agent/cli first, so a
// node command behaves the same whichever binary a machine has.
package main

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/agent/cli"
)

// Version is stamped at build time via -ldflags.
var Version = "dev"

// SrcDigest is the digest of the Go source this binary was built from
// (release.SourceDigest, claude-fleet#2930), stamped like Version; "" = unstamped.
var SrcDigest = ""

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cli.Version, cli.SrcDigest = Version, SrcDigest
	if handled, code := cli.Run(os.Args[1], os.Args[2:]); handled {
		os.Exit(code)
	}
	switch os.Args[1] {
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "ccquota: unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `ccquota — cross-endpoint Claude Code and Codex usage monitor (node build)

Usage:
  ccquota report [flags]    Local one-shot usage report (no hub, no network)
  ccquota agent  [flags]    Collect on this endpoint and push to a hub
  ccquota stamp  [flags]    Record which subscription a session is on
                            (install as Claude Code's statusLine)
  ccquota budget [flags]    Is there headroom to start more work? (--gate for
                            a scheduler: exit 0 proceed, 3 hold)
  ccquota codex  [command]  Manage Codex accounts, launch profiles and renew login
  ccquota lease  <cmd>      Take/give back the hub's lease on an issue before a
                            fleet session opens it (acquire | release; exit 3 held)
  ccquota place  <repo> <N> <wid>
                            Ask the hub which machine opens a session on an issue
                            (LOCAL | REMOTE — the hub sent it there; exit 3 held)
  ccquota move   <cmd>      Move a session to another machine through the hub
                            (plan | send; fleet-move.sh --via hub)
  ccquota credproxy [flags] The cluster credential proxy: a session pass in, the
                            real credential out, through the relay
  ccquota release <cmd>     A node release from the hub, signature-checked
                            (fetch | verify | keygen | pubkey; never GitHub)
  ccquota version           Print the version

The hub's commands (hub, enroll, endpoint, name, badge, team, svc, plan, db,
notify) are in the hub's build. Run any subcommand with -h for its flags.
`)
}
