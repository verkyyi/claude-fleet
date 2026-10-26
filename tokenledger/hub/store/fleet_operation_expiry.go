package store

import (
	"errors"
	"time"
)

// Retain the terminal reader for rows already written by the first R4 release.
// Their previous status must be reviewed from operation_expire audit entries;
// a deployment never guesses a status to restore.
func FleetOperationTerminal(status string) bool {
	return status == "succeeded" || status == "failed" || status == "expired"
}

// ErrOperationExpiryReviewRequired refuses age-only expiry. An old timestamp
// proves neither native absence nor that changing the row is invisible in the UI.
var ErrOperationExpiryReviewRequired = errors.New("operation expiry requires verified inactivity and operator review of any visible status change")

// ExpireFleetOperations is retained as a fail-closed entry. No unreviewed old
// row is mutated, including recorded/unknown rows with incomplete provenance.
func (s *Store) ExpireFleetOperations(now time.Time) (int, error) {
	return 0, ErrOperationExpiryReviewRequired
}
