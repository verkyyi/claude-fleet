//go:build !darwin && !linux

package agent

import (
	"errors"
	"io"
)

func RunPreviewPipe(args []string, stdin io.Reader, stdout io.Writer) error {
	return errors.New("private previews require macOS or Linux peer credentials")
}
