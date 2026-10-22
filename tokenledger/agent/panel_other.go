//go:build !unix

package agent

import (
	"fmt"
	"os"
)

// PanelAttach needs a unix socket to hand descriptors over; there is no 看台 off unix.
func PanelAttach(fallback []string) int {
	fmt.Fprintln(os.Stderr, "ccquota panel attach: not on this system")
	return 2
}
