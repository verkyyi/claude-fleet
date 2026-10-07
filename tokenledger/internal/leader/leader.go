// Package leader decides which hub replica runs each background job
// (claude-fleet#2123).
//
// With two hubs on one Postgres database every loop the hub runs — the daily
// prune, node alerts, the SPOT controller — would run twice, and a credential
// refreshed by both at once makes the provider revoke the whole grant (it
// happened on 2026-10-04). So each job asks Leader at the top of its tick, and
// only the replica holding that job's Postgres advisory lock does the work.
//
// The lock is session-level on a connection held for it: a replica that dies
// — killed, OOM, its network gone — drops the connection, Postgres releases
// the lock, and the other replica takes it on its next try (Run tries every
// RetryEvery, well under the 15 s handover the issue asks for).
//
// On SQLite (no CCQUOTA_DB_URL) there is only ever one hub, so an Elector made
// from an empty URL is the leader of everything and Lock is a no-op: the
// single hub behaves byte for byte as before.
package leader

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"hash/fnv"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

// RetryEvery is how often Run tries to take the jobs this replica does not
// hold: the upper bound on a handover after the leader's connection drops.
const RetryEvery = 5 * time.Second

// pingTimeout bounds the liveness check of a held lock's connection.
const pingTimeout = 3 * time.Second

// Elector holds this replica's job locks.
type Elector struct {
	replica string
	db      *sql.DB // nil: single hub, leader of everything

	mu   sync.Mutex
	jobs map[string]*sql.Conn // every job asked about; a non-nil conn holds its lock

	logf func(string, ...any)
}

// New makes the elector for a hub whose database is url: "" (SQLite) is a
// single hub, a postgres:// URL elects through that database. replica is this
// hub's name in logs and audit rows ("" = Replica()).
func New(url, replica string) (*Elector, error) {
	if replica == "" {
		replica = Replica()
	}
	e := &Elector{replica: replica, jobs: map[string]*sql.Conn{}, logf: log.Printf}
	if url == "" {
		return e, nil
	}
	cfg, err := pgx.ParseConfig(url)
	if err != nil {
		// pgx's message quotes the connection string, password and all.
		return nil, errors.New("leader: not a valid postgres:// connection string")
	}
	e.db = stdlib.OpenDB(*cfg)
	return e, nil
}

// Replica is this process's replica name: CCQUOTA_REPLICA, else HOSTNAME (a
// Kubernetes pod's name), else the machine's host name.
func Replica() string {
	for _, k := range []string{"CCQUOTA_REPLICA", "HOSTNAME"} {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return v
		}
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "hub"
}

// Name is the replica name this elector logs under.
func (e *Elector) Name() string { return e.replica }

// Elected says whether this elector elects at all (false: a single hub).
func (e *Elector) Elected() bool { return e != nil && e.db != nil }

// key is a job's advisory-lock key. The namespace keeps it apart from any lock
// another program takes on the same database.
func key(job string) int64 {
	h := fnv.New64a()
	h.Write([]byte("ccquota:" + job))
	return int64(h.Sum64())
}

// Leader reports whether this replica runs job right now, taking the job's
// lock when nobody holds it. A nil or single-hub elector is always the leader.
func (e *Elector) Leader(ctx context.Context, job string) bool {
	if !e.Elected() {
		return true
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.hold(ctx, job)
}

// hold is Leader under e.mu.
func (e *Elector) hold(ctx context.Context, job string) bool {
	if c := e.jobs[job]; c != nil {
		pctx, cancel := context.WithTimeout(ctx, pingTimeout)
		err := c.PingContext(pctx)
		cancel()
		if err == nil {
			return true
		}
		// The connection is gone, and the lock with it: someone else may
		// hold the job already. Never hand this connection back to the pool.
		discard(c)
		e.jobs[job] = nil
		e.logf("leader: replica=%s lost %s (%v)", e.replica, job, err)
	}
	if _, seen := e.jobs[job]; !seen {
		e.jobs[job] = nil
	}
	c, err := e.db.Conn(ctx)
	if err != nil {
		return false
	}
	var got bool
	if err := c.QueryRowContext(ctx, `SELECT pg_try_advisory_lock($1)`, key(job)).Scan(&got); err != nil || !got {
		if err != nil {
			discard(c)
		} else {
			c.Close() // holds nothing: safe to reuse
		}
		return false
	}
	e.jobs[job] = c
	e.logf("leader: replica=%s now runs %s", e.replica, job)
	return true
}

// Run keeps trying to take every job this replica has asked about, every
// RetryEvery, until ctx ends — so a handover does not wait for the job's own
// (possibly daily) tick. Run is a no-op on a single hub.
func (e *Elector) Run(ctx context.Context) {
	if !e.Elected() {
		return
	}
	t := time.NewTicker(RetryEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			e.mu.Lock()
			for job := range e.jobs {
				e.hold(ctx, job)
			}
			e.mu.Unlock()
		}
	}
}

// Lock takes name's lock across replicas, waiting for whoever holds it, and
// returns the release. It serialises one short critical section (a
// credential's refresh) rather than electing a runner. On a single hub it
// returns at once.
func (e *Elector) Lock(ctx context.Context, name string) (func(), error) {
	if !e.Elected() {
		return func() {}, nil
	}
	k := key("lock:" + name)
	c, err := e.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := c.ExecContext(ctx, `SELECT pg_advisory_lock($1)`, k); err != nil {
		discard(c)
		return nil, err
	}
	return func() {
		uctx, cancel := context.WithTimeout(context.Background(), pingTimeout)
		defer cancel()
		var ok bool
		if err := c.QueryRowContext(uctx, `SELECT pg_advisory_unlock($1)`, k).Scan(&ok); err != nil || !ok {
			// Unsure whether the lock is gone: end the session, which
			// certainly ends it.
			discard(c)
			return
		}
		c.Close()
	}, nil
}

// Close releases every lock this replica holds (its connections end).
func (e *Elector) Close() error {
	if !e.Elected() {
		return nil
	}
	e.mu.Lock()
	for job, c := range e.jobs {
		if c != nil {
			discard(c)
		}
		e.jobs[job] = nil
	}
	e.mu.Unlock()
	return e.db.Close()
}

// discard closes c's session instead of returning it to the pool: a session
// that may still hold an advisory lock must end, or the lock lives on in the
// pool.
func discard(c *sql.Conn) {
	_ = c.Raw(func(any) error { return driver.ErrBadConn })
	_ = c.Close()
}
