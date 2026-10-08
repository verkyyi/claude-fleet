//go:build !unix

package main

import "os"

// fileUID says nothing where files have no uid; the machine agent is macOS /
// Linux only.
func fileUID(os.FileInfo) (uint32, bool) { return 0, false }
