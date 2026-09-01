// Command ccquota collects Claude Code usage from every endpoint on a
// subscription and serves it as a dashboard and an MCP server.
//
// One binary, three roles:
//
//	ccquota report   local one-shot report; no hub, no network
//	ccquota agent    run on each endpoint; scans transcripts, pushes to a hub
//	ccquota hub      the collector, dashboard and MCP server
//	ccquota enroll   mint an endpoint token (run on the hub)
package main

import (
	"fmt"
	"os"
)

// Version is stamped at build time via -ldflags.
var Version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "report":
		err = runReport(os.Args[2:])
	case "agent":
		err = runAgent(os.Args[2:])
	case "hub":
		err = runHub(os.Args[2:])
	case "enroll":
		err = runEnroll(os.Args[2:])
	case "stamp":
		err = runStamp(os.Args[2:])
	case "name":
		err = runName(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println("ccquota", Version)
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
	fmt.Fprint(os.Stderr, `ccquota — cross-endpoint Claude Code usage monitor

Usage:
  ccquota report [flags]    Local one-shot usage report (no hub, no network)
  ccquota agent  [flags]    Collect on this endpoint and push to a hub
  ccquota hub    [flags]    Run the collector, dashboard and MCP server
  ccquota enroll [flags]    Mint an enrollment token for a new endpoint
  ccquota stamp  [flags]    Record which subscription a session is on
                            (install as Claude Code's statusLine)
  ccquota name   [flags]    List subscriptions, or name one permanently
  ccquota version           Print the version

Run any subcommand with -h for its flags.
`)
}

// homeDir resolves the Claude Code home, honoring an override so an operator
// can point at another user's directory.
func homeDir(override string) (string, error) {
	if override != "" {
		return override, nil
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return h, nil
}
