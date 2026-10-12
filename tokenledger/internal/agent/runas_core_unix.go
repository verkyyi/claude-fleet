//go:build unix

package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"syscall"
)

// CoreExec is `ccquota core-exec` (claude-fleet#3669): ask the root core at sock
// to run argv as login on THIS process's stdin, stdout and stderr, and answer
// the job's exit code. The core's refusal (or no core) is one stderr line and
// coreRefusedExit; a job killed by a signal is 128+signal, as a shell says it.
// Killing this process closes the connection, and the core stops the job.
func CoreExec(sock, login string, argv []string) int {
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: sock, Net: "unix"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "ccquota core-exec: the root core (%s): %v\n", sock, err)
		return coreRefusedExit
	}
	defer conn.Close()
	line, err := json.Marshal(map[string]any{"op": "exec-as", "args": map[string]any{"login": login, "argv": argv}})
	if err != nil {
		fmt.Fprintf(os.Stderr, "ccquota core-exec: %v\n", err)
		return coreRefusedExit
	}
	rights := syscall.UnixRights(int(os.Stdin.Fd()), int(os.Stdout.Fd()), int(os.Stderr.Fd()))
	if _, _, err := conn.WriteMsgUnix(append(line, '\n'), rights, nil); err != nil {
		fmt.Fprintf(os.Stderr, "ccquota core-exec: send to the root core: %v\n", err)
		return coreRefusedExit
	}
	rd := bufio.NewReader(conn)
	first, err := coreReply(rd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ccquota core-exec: the root core: %v\n", err)
		return coreRefusedExit
	}
	if first.OK == nil || !*first.OK {
		why := first.Why
		if why == "" {
			why = first.Error
		}
		fmt.Fprintf(os.Stderr, "ccquota core-exec: the root core did not run %s as %s: %s\n", argv[0], login, why)
		return coreRefusedExit
	}
	end, err := coreReply(rd)
	if err != nil || end.Exit == nil {
		fmt.Fprintf(os.Stderr, "ccquota core-exec: the root core went away before %s ended\n", argv[0])
		return coreRefusedExit
	}
	if rc := *end.Exit; rc < 0 {
		return 128 - rc
	}
	return *end.Exit
}

type coreAnswer struct {
	OK    *bool  `json:"ok"`
	Exit  *int   `json:"exit"`
	Why   string `json:"why"`
	Error string `json:"error"`
}

func coreReply(rd *bufio.Reader) (coreAnswer, error) {
	var a coreAnswer
	b, err := rd.ReadBytes('\n')
	if err != nil && (err != io.EOF || len(b) == 0) {
		return a, fmt.Errorf("no answer (%v)", err)
	}
	if err := json.Unmarshal(b, &a); err != nil {
		return a, fmt.Errorf("unreadable answer %q", b)
	}
	return a, nil
}
