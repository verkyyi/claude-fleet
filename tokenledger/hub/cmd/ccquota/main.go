// Command ccquota, the hub's build (claude-fleet#4814, EPIC #4810 C4): the
// collector, dashboard and MCP server, and the commands that run beside it.
//
//	ccquota hub       the collector, dashboard and MCP server
//	ccquota enroll    mint an endpoint token (run on the hub)
//	ccquota endpoint  list/retire/delete an endpoint (run on the hub)
//	ccquota credproxy the cluster credential proxy (the hub's image, its own
//	                  Deployment — shared/credproxy; the hub's only, T600)
//
// No node code is compiled in: a node command (agent/cmd/ccquota/commands.txt)
// answers one line naming the node's build and exits 2.
package main

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
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

	var err error
	switch os.Args[1] {
	case "version", "--version", "-v":
		fmt.Println("ccquota", Version)
		if SrcDigest != "" {
			// a second line: the first stays `ccquota <ver>` for every reader
			fmt.Println("src", SrcDigest)
		}
	case "credproxy":
		err = credproxy.Main(Version, os.Args[2:])
	case "hub":
		err = runHub(os.Args[2:])
	case "enroll":
		err = runEnroll(os.Args[2:])
	case "endpoint":
		err = runEndpoint(os.Args[2:])
	case "name":
		err = runName(os.Args[2:])
	case "team":
		err = runTeam(os.Args[2:])
	case "svc":
		err = runSvc(os.Args[2:])
	case "plan":
		err = runPlan(os.Args[2:])
	case "db":
		err = runDB(os.Args[2:])
	case "notify":
		// The hub's FLEET_NOTIFY_CMD (claude-fleet#4086).
		err = runNotify(os.Args[2:])
	case "help", "--help", "-h":
		usage()
	default:
		if nodeCommands[os.Args[1]] {
			fmt.Fprintf(os.Stderr, "ccquota: %q 是节点的命令（this is the node's command: the node's build, agent/cmd/ccquota, runs it — not the hub's）\n", os.Args[1])
			os.Exit(2)
		}
		fmt.Fprintf(os.Stderr, "ccquota: unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota:", err)
		os.Exit(1)
	}
}

// nodeCommands are the node's build's subcommands this build does not run
// (agent/cmd/ccquota/commands.txt less version, which both run;
// bin/tokenledger-modules-selftest.sh holds the two lists together).
var nodeCommands = map[string]bool{
	"agent": true, "budget": true, "chat-pipe": true, "codex": true, "core-exec": true,
	"lease": true, "move": true, "place": true, "release": true, "report": true,
	"stamp": true, "term-pty": true,
}

func usage() {
	fmt.Fprint(os.Stderr, `ccquota — cross-endpoint Claude Code and Codex usage monitor (hub build)

Usage:
  ccquota hub    [flags]    Run the collector, dashboard and MCP server
  ccquota enroll [flags]    Mint an enrollment token for a new endpoint
  ccquota endpoint <cmd>    List, retire or delete an enrolled endpoint
                            (list | retire <id> | delete <id>)
  ccquota name   [flags]    List subscriptions, or name one permanently
  ccquota team   [flags]    Allocate an endpoint's spend to a team
  ccquota svc    <cmd>      Service principals and their fcs_ tokens: /v1/svc/
                            only, scope by scope (list | create | token issue |
                            token revoke | disable | enable)
  ccquota plan   [flags]    Record what a subscription actually costs, and
                            report real (billed, not notional) spend
  ccquota credproxy [flags] The cluster credential proxy: a session pass in, the
                            real credential out, through the relay (its own
                            Deployment beside the hub; deploy/k8s/credproxy)
  ccquota db     <cmd>      Move the hub's SQLite database into Postgres, and
                            check the copy (migrate | verify; deploy/k8s/RUNBOOK.md)
  ccquota notify "<msg>"    Send one message where FLEET_NOTIFY_KF_* /
                            FLEET_NOTIFY_WEBHOOK say (the hub's FLEET_NOTIFY_CMD)
  ccquota version           Print the version

The node's commands (agent, report, stamp, budget, codex, lease, place, move,
release, …) are in the node's build (agent/cmd/ccquota). Run any subcommand
with -h for its flags.
`)
}
