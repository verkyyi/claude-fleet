// Command ccquota collects Claude Code usage from every endpoint on a
// subscription and serves it as a dashboard and an MCP server.
//
// One binary, three roles:
//
//	ccquota report   local one-shot report; no hub, no network
//	ccquota agent    run on each endpoint; scans transcripts, pushes to a hub
//	ccquota hub      the collector, dashboard and MCP server
//	ccquota enroll   mint an endpoint token (run on the hub)
//	ccquota endpoint list/retire/delete an endpoint (run on the hub)
//	ccquota budget   headroom verdict for a scheduler (read-only advice)
//	ccquota credproxy the cluster credential proxy (beside the hub)
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

	// The node's commands are agent/cli's (claude-fleet#4812): one
	// implementation for this binary and the node's own build.
	cli.Version, cli.SrcDigest = Version, SrcDigest
	if handled, code := cli.Run(os.Args[1], os.Args[2:]); handled {
		os.Exit(code)
	}

	var err error
	switch os.Args[1] {
	case "hub":
		err = runHub(os.Args[2:])
	case "enroll":
		err = runEnroll(os.Args[2:])
	case "endpoint":
		err = runEndpoint(os.Args[2:])
	case "name":
		err = runName(os.Args[2:])
	case "badge":
		err = runBadge(os.Args[2:])
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
		fmt.Fprintf(os.Stderr, "ccquota: unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `ccquota — cross-endpoint Claude Code and Codex usage monitor

Usage:
  ccquota report [flags]    Local one-shot usage report (no hub, no network)
  ccquota agent  [flags]    Collect on this endpoint and push to a hub
  ccquota hub    [flags]    Run the collector, dashboard and MCP server
  ccquota enroll [flags]    Mint an enrollment token for a new endpoint
  ccquota endpoint <cmd>    List, retire or delete an enrolled endpoint
                            (list | retire <id> | delete <id>)
  ccquota stamp  [flags]    Record which subscription a session is on
                            (install as Claude Code's statusLine)
  ccquota name   [flags]    List subscriptions, or name one permanently
  ccquota budget [flags]    Is there headroom to start more work? (--gate for
                            a scheduler: exit 0 proceed, 3 hold)
  ccquota badge  [flags]    Render this hub's totals as an SVG badge (local,
                            no network) or as shields.io endpoint JSON
  ccquota team   [flags]    Allocate an endpoint's spend to a team
  ccquota svc    <cmd>      Service principals and their fcs_ tokens: /v1/svc/
                            only, scope by scope (list | create | token issue |
                            token revoke | disable | enable)
  ccquota plan   [flags]    Record what a subscription actually costs, and
                            report real (billed, not notional) spend
  ccquota codex  [command]  Manage Codex accounts, launch profiles and renew login
  ccquota lease  <cmd>      Take/give back the hub's lease on an issue before a
                            fleet session opens it (acquire | release; exit 3 held)
  ccquota place  <repo> <N> <wid>
                            Ask the hub which machine opens a session on an issue
                            (LOCAL | REMOTE — the hub sent it there; exit 3 held)
  ccquota move   <cmd>      Move a session to another machine through the hub
                            (plan | send; fleet-move.sh --via hub)
  ccquota credproxy [flags] The cluster credential proxy: a session pass in, the
                            real credential out, through the relay (its own
                            Deployment beside the hub; deploy/k8s/credproxy)
  ccquota db     <cmd>      Move the hub's SQLite database into Postgres, and
                            check the copy (migrate | verify; deploy/k8s/RUNBOOK.md)
  ccquota release <cmd>     A node release from the hub, signature-checked
                            (fetch | verify | keygen | pubkey; never GitHub)
  ccquota notify "<msg>"    Send one message where FLEET_NOTIFY_KF_* /
                            FLEET_NOTIFY_WEBHOOK say (the hub's FLEET_NOTIFY_CMD)
  ccquota version           Print the version

Run any subcommand with -h for its flags.
`)
}
