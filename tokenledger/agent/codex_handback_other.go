//go:build !unix

package agent

// handBackCodexHome off unix: no machine agent runs here.
func handBackCodexHome(ra *RunAs, home string) (int, error) { return 0, nil }
