//go:build !unix

package agent

import (
	"errors"
	"io"
)

// RunTermPty has no terminal to open here.
func RunTermPty(args []string, stdin io.Reader, stdout io.Writer) (int, error) {
	return 1, errors.New("term-pty: no pseudo-terminal on this system")
}
