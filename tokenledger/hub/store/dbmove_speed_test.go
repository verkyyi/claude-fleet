package store

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// moveSpeedRows is how many usage_events rows the timing test moves:
// CCQUOTA_MOVE_SPEED_ROWS — CI's timing step sets 1,000,000 (production's two
// big tables, 2026-10-07: 945,491 + 261,595) — else a size the -race leg
// runs in seconds.
func moveSpeedRows() (int, bool) {
	if n, err := strconv.Atoi(os.Getenv("CCQUOTA_MOVE_SPEED_ROWS")); err == nil && n > 0 {
		return n, true
	}
	return 20_000, false
}

// usageEventsSource is a hub database with n rows in usage_events, shaped like
// production's (the indexes, a spread of accounts, sessions and times).
func usageEventsSource(t testing.TB, n int) string {
	t.Helper()
	from := filepath.Join(t.TempDir(), "ccquota.db")
	st, err := openSQLite(from)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	st.Close()
	db, err := sql.Open("sqlite", from)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < ?)
		INSERT INTO usage_events (account_uuid, endpoint_id, session_id, message_uuid, request_id, ts, model,
		  input_tokens, output_tokens, cache_read_tokens, cost_usd, cwd, git_branch, issue_number, git_repo)
		SELECT 'acct-' || (i % 37), 'ep-' || (i % 11), 'sess-' || (i / 400), 'msg-' || i, 'req_' || hex(randomblob(8)),
		  strftime('%Y-%m-%dT%H:%M:%SZ', 1780000000 + i * 7, 'unixepoch'), 'claude-opus-5-5',
		  i % 9000, i % 3000, i % 120000, CASE WHEN i % 13 = 0 THEN NULL ELSE (i % 997) / 1000.0 END,
		  '/Users/someone/projects/repo-' || (i % 23), 'issue-' || (i % 2300), CASE WHEN i % 3 = 0 THEN NULL ELSE i % 2300 END,
		  'owner/repo-' || (i % 23)
		FROM n`, n); err != nil {
		t.Fatal(err)
	}
	return from
}

// claude-fleet#2216: the rehearsal's 84.7s broke the runbook's one-minute
// write stop. Moving + verifying ~1M usage_events rows prints each table's and
// phase's time; the budget is generous for a shared CI runner.
func TestMoveDatabaseSpeed(t *testing.T) {
	to := moveTarget(t)
	n, timed := moveSpeedRows()
	t0 := time.Now()
	from := usageEventsSource(t, n)
	t.Logf("source: %d usage_events rows written in %.1fs", n, time.Since(t0).Seconds())
	var out bytes.Buffer
	t0 = time.Now()
	rep, err := MoveDatabase(context.Background(), MoveOptions{From: from, To: to, Verify: true, DryRun: true, Out: &out})
	took := time.Since(t0)
	t.Log("\n" + out.String())
	if err != nil || len(rep.Differ) > 0 {
		t.Fatalf("move: %v, differ %v", err, rep)
	}
	t.Logf("moved + verified %d rows in %.1fs (%.0f rows/s)", rep.Rows, took.Seconds(), float64(rep.Rows)/took.Seconds())
	// The runbook stops writes for at most a minute; a CI runner beside its
	// own Postgres has no network in the way, so a million rows past half of
	// that is the copy getting slower, not the runner.
	if timed && took > time.Duration(n)*30*time.Microsecond {
		t.Errorf("%d rows took %.1fs, over %.1fs", n, took.Seconds(), (time.Duration(n) * 30 * time.Microsecond).Seconds())
	}
}
