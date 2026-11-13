package store

// Readiness and the deploy probe (claude-fleet#2125, EPIC #2119 C6): what a
// rolling release asks of a hub replica before it sends it traffic, and the one
// write the release's availability probe makes.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"
)

// readyBudget is the longest one readiness check may take (task N9GH): the
// pod's readinessProbe allows 3 s, and /readyz must answer inside it whatever
// the pools are doing.
const readyBudget = 2 * time.Second

// readyGate is Ready's own state: one check in flight at a time, and on
// Postgres a connection of its own.
type readyGate struct {
	mu      sync.Mutex
	running bool    // a check has not come back yet
	closed  bool    // the store was closed
	probe   *sql.DB // Postgres: the readiness pool, one connection, nobody else's
}

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
//
// It answers within readyBudget (or ctx, if sooner) whatever the database
// does (task N9GH): on 2026-11-13 every pool connection hung on a silently
// dropped TCP stream and /readyz answered after 15m49s, so neither replica
// could even be marked NotReady and recover. So the check runs off the
// request — Ready returns at its deadline even if a driver call ignores it —
// at most one at a time (a check still out answers not ready at once rather
// than piling up), and on Postgres it uses a pool of its own, one connection
// no request can be holding: it never waits behind a stuck connection of the
// writer or the readers. A probe connection that times out is thrown away
// with its pool, so the next check dials fresh.
func (s *Store) Ready(ctx context.Context) error {
	s.rg.mu.Lock()
	switch {
	case s.rg.closed:
		s.rg.mu.Unlock()
		return errors.New("database: closed")
	case s.rg.running:
		s.rg.mu.Unlock()
		return errors.New("database: the last readiness check has not come back")
	}
	s.rg.running = true
	s.rg.mu.Unlock()

	budget := readyBudget
	if dl, ok := ctx.Deadline(); ok && time.Until(dl) < budget {
		budget = time.Until(dl)
	}
	cctx, cancel := context.WithTimeout(context.Background(), budget)
	done := make(chan error, 1)
	go func() {
		defer cancel()
		err := s.readyCheck(cctx)
		s.rg.mu.Lock()
		s.rg.running = false
		s.rg.mu.Unlock()
		done <- err
	}()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return fmt.Errorf("database: %w", ctx.Err())
	case <-cctx.Done():
		select {
		case err := <-done: // it came back right at the deadline
			return err
		default:
		}
		// the check's own budget ran out and the driver has not returned
		return fmt.Errorf("database: %w", cctx.Err())
	}
}

// readyCheck is one readiness check within ctx.
func (s *Store) readyCheck(ctx context.Context) error {
	ping, read := s.write, s.read
	if s.d.pg() {
		p, err := s.readyProbe()
		if err != nil {
			return fmt.Errorf("database: %w", err)
		}
		ping, read = p, p
	}
	if err := ping.PingContext(ctx); err != nil {
		s.dropProbe(ping)
		return fmt.Errorf("database: %w", err)
	}
	var have int
	if err := read.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM hub_migrations`).Scan(&have); err != nil {
		s.dropProbe(read)
		return fmt.Errorf("read hub_migrations: %w", err)
	}
	if want := LatestMigration(); have < want {
		return fmt.Errorf("database is at migration %d, this build needs %d", have, want)
	}
	return nil
}

// readyProbe is the readiness pool, opened on first use: read-only, one
// connection, kept idle between checks.
func (s *Store) readyProbe() (*sql.DB, error) {
	s.rg.mu.Lock()
	defer s.rg.mu.Unlock()
	if s.rg.closed {
		return nil, errors.New("closed")
	}
	if s.rg.probe != nil {
		return s.rg.probe, nil
	}
	p, err := openPool(s.d, s.src, true)
	if err != nil {
		return nil, err
	}
	p.SetMaxOpenConns(1)
	p.SetMaxIdleConns(1)
	p.SetConnMaxLifetime(10 * time.Minute)
	s.rg.probe = p
	return p, nil
}

// dropProbe throws the readiness pool p away after a failed check, so the
// next one dials a fresh connection. The writer / readers are never dropped.
func (s *Store) dropProbe(p *sql.DB) {
	s.rg.mu.Lock()
	if s.rg.probe != p {
		s.rg.mu.Unlock()
		return
	}
	s.rg.probe = nil
	s.rg.mu.Unlock()
	go p.Close() // waits for a call still on it; nobody waits for that
}

// closeProbe ends Ready for good (Close).
func (s *Store) closeProbe() {
	s.rg.mu.Lock()
	s.rg.closed = true
	p := s.rg.probe
	s.rg.probe = nil
	s.rg.mu.Unlock()
	if p != nil {
		p.Close()
	}
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
