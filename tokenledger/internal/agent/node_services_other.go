//go:build !unix

package agent

import "os"

// openOwnedLog: no machine daemon here, so no service log is read.
func openOwnedLog(string, int) (*os.File, os.FileInfo, bool) { return nil, nil, false }
