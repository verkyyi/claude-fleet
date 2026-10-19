//go:build !darwin && !linux

package agent

import (
	"errors"
	"os"
)

func setPTYSize(f *os.File, cols, rows int) error {
	return errors.New("no pseudo-terminal on this system")
}
