// Package cli is the node program's subcommands (claude-fleet#4812, EPIC #4810
// C2): every `ccquota <cmd>` a machine, a pod or bin/ runs. Two binaries call
// it — agent/cmd/ccquota (the node alone, no hub code) and the combined
// cmd/ccquota (the hub's image and today's release) — so the node's commands
// are one implementation however the binary was built. commands.txt beside
// agent/cmd/ccquota is the list; bin/tokenledger-modules-selftest.sh holds it
// to every `ccquota <cmd>` bin/ runs.
package cli

import (
	"fmt"
	"os"
)

// Version and SrcDigest are the calling binary's own (its main stamps them at
// build time via -ldflags and copies them here before Run).
var (
	Version   = "dev"
	SrcDigest = ""
)

// Run runs the node subcommand name with its args. handled is false for a
// name that is not the node's (the caller's own commands, help, unknown);
// otherwise code is the process's exit code — an error is printed the way
// ccquota always printed one.
func Run(name string, args []string) (handled bool, code int) {
	var err error
	switch name {
	case "report":
		err = runReport(args)
	case "agent":
		if machineFlag(args) {
			// One node program for the whole machine (claude-fleet#2333).
			err = runAgentMachine(args)
		} else {
			err = runAgent(args)
		}
	case "core-exec": // agent.CoreExecCmd
		// The seated node program's tenant command, through the root core's
		// exec-as (claude-fleet#3669): exits with the job's code.
		return true, runCoreExec(args)
	case "chat-pipe": // agent.ChatPipeCmd
		// A chat relay's last hop, run as the login (claude-fleet#3644):
		// its own conversation socket on stdio, nothing else.
		return true, runChatPipe(args)
	case "term-pty": // agent.TermPtyCmd
		// A terminal relay's last hop, run as the login (claude-fleet#3838):
		// its own PTY on the one attach command, framed on stdio.
		return true, runTermPty(args)
	case "door":
		// The cluster door's own SSH server (A5SQ): one address, routed by username.
		err = runDoor(args)
	case "stamp":
		err = runStamp(args)
	case "budget":
		err = runBudget(args)
	case "codex":
		err = runCodex(args)
	case "lease":
		err = runLease(args)
	case "place":
		err = runPlace(args)
	case "move":
		err = runMove(args)
	case "release":
		err = runRelease(args)
	case "version", "--version", "-v":
		fmt.Println("ccquota", Version)
		if SrcDigest != "" {
			// a second line: the first stays `ccquota <ver>` for every reader
			fmt.Println("src", SrcDigest)
		}
	default:
		return false, 0
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota:", err)
		return true, 1
	}
	return true, 0
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
