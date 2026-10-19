package store

// Readiness and the deploy probe (claude-fleet#2125, EPIC #2119 C6): what a
// rolling release asks of a hub replica before it sends it traffic, and the one
// write the release's availability probe makes.

import (
	"context"
	"fmt"
	"time"
)

// deployProbeKey is the rollup_meta row the deploy probe overwrites: one row,
// whatever the request rate, so the probe can never grow the database.
const deployProbeKey = "deploy_probe"

// LatestMigration is the highest numbered migration this build knows.
func LatestMigration() int {
	n := 0
	for _, m := range migrations {
		if m.ID > n {
			n = m.ID
		}
	}
	return n
}

// Ready says whether this hub may take traffic: the database answers within
// ctx, and it has run every numbered migration this build knows. A database
// AHEAD of the build is ready — mid-rollout the old replicas keep serving on a
// schema the new image has just moved (migrations only ever add or remove
// what the old build no longer reads); one BEHIND it is not, because this
// build would read a table that is not there yet.
func (s *Store) Ready(ctx context.Context) error {
	if err := s.write.PingContext(ctx); err != nil {
		return fmt.Errorf("database: %w", err)
	}
	var have int
	if err := s.read.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM hub_migrations`).Scan(&have); err != nil {
		return fmt.Errorf("read hub_migrations: %w", err)
	}
	if want := LatestMigration(); have < want {
		return fmt.Errorf("database is at migration %d, this build needs %d", have, want)
	}
	return nil
}

// TouchDeployProbe overwrites the deploy probe's one row with now and who
// answered — a real write through the same writer every request uses.
func (s *Store) TouchDeployProbe(ctx context.Context, now time.Time, replica string) error {
	_, err := s.write.ExecContext(ctx,
		`INSERT INTO rollup_meta(key, value) VALUES(?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		deployProbeKey, now.UTC().Format(time.RFC3339Nano)+" "+replica)
	return err
}
