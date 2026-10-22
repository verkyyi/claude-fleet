package cli

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
)

// runPanel is `ccquota panel probe | attach -- <fallback…>` (claude-fleet T890):
// the 看台's ⌘P connector. probe answers `panel 1` (fleet_view.py direct_popup asks
// before binding the key to it).
func runPanel(args []string) int {
	if len(args) > 0 && args[0] == "probe" {
		fmt.Println("panel 1")
		return 0
	}
	if len(args) > 0 && args[0] == "attach" {
		rest := args[1:]
		if len(rest) > 0 && rest[0] == "--" {
			rest = rest[1:]
		}
		return agent.PanelAttach(rest)
	}
	fmt.Fprintln(os.Stderr, "usage: ccquota panel probe | attach -- <fallback command…>")
	return 2
}
