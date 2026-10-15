//go:build !darwin && !linux

package agent

import (
	"errors"
	"os"
)

func openPTY() (master, slave *os.File, err error) {
	return nil, nil, errors.New("no pseudo-terminal on this system")
}
