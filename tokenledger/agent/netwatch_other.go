//go:build !darwin && !linux

package agent

import "context"

// netChangeSource has no kernel feed on this platform: the backoff alone.
func netChangeSource(context.Context) <-chan struct{} { return nil }
