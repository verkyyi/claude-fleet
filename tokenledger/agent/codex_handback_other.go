//go:build !unix

package agent

// handBackCodexHome off unix: no machine agent runs here.
func handBackCodexHome(ra *RunAs, home, bound string) (handBackResult, error) {
	return handBackResult{}, nil
}
