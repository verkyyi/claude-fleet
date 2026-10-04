package store

import (
	"testing"
	"time"
)

// TestStore_ReadsDoNotQueueBehindAWrite pins the reason the dashboard used to
// feel slow.
//
// Every read endpoint is single-digit milliseconds measured on its own, but the
// hub once served reads and writes from one connection: a fleet of agents
// pushing ingest held it, and the page's fan-out queued behind them. Prod logged
// `GET /v1/limits 200 10.308s` for a query that takes 10ms, sitting behind
// `POST /v1/ingest 200 13.187s`.
//
// The read pool is what fixes it, so this asserts the property directly: while a
// write transaction holds the writer, a read still goes through.
func TestStore_ReadsDoNotQueueBehindAWrite(t *testing.T) {
	s := newStore(t)

	tx, err := s.write.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	// Take the write lock for real — an open transaction that has not written
	// anything yet does not hold it.
	if _, err := tx.Exec(`INSERT OR REPLACE INTO rollup_meta(key, value) VALUES('pool-probe','1')`); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := s.Collectors("", "")
		done <- err
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("read failed while a write was in flight: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a read queued behind an in-flight write: reads and writes are sharing one connection again, " +
			"so any slow ingest will stall the whole dashboard")
	}
}

// TestStore_ReadPoolRefusesAWrite keeps the two pools from quietly collapsing
// back into one.
//
// query_only is the only thing that makes "reads go here, writes go there" an
// enforced rule rather than a convention: without it a stray write on the read
// pool would work, and modernc's driver would be taking concurrent writers —
// exactly what the single writer connection exists to prevent.
func TestStore_ReadPoolRefusesAWrite(t *testing.T) {
	s := newStore(t)

	if _, err := s.read.Exec(`INSERT OR REPLACE INTO rollup_meta(key, value) VALUES('pool-probe','1')`); err == nil {
		t.Fatal("the read pool accepted a write: query_only is not in force")
	}
}
