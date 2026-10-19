//go:build !unix

package agent

import (
	"fmt"
	"os"
)

// CoreExec needs a unix socket to pass descriptors over: there is no root core
// off unix.
func CoreExec(sock, login string, argv []string) int {
	fmt.Fprintln(os.Stderr, "ccquota core-exec: no root core on this system")
	return coreRefusedExit
}
