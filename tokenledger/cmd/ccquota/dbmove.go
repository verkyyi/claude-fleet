package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// runDB is `ccquota db`: moving the hub's database from SQLite into Postgres
// (claude-fleet#2122, EPIC #2119 C3). deploy/k8s/RUNBOOK.md «换库» is the
// procedure around it.
//
//	ccquota db migrate [--from F] [--to URL] [--dry-run] [--verify] [--overwrite]
//	ccquota db verify  [--from F] [--to URL]
//
// Exit 1 = it did not happen or the two sides differ; the per-table report is
// on stdout either way.
func runDB(args []string) error {
	return runDBTo(args, os.Stdout)
}

func runDBTo(args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("db: migrate | verify (ccquota db <cmd> -h)")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	switch args[0] {
	case "migrate":
		fs := flag.NewFlagSet("db migrate", flag.ContinueOnError)
		from, to := dbMoveFlags(fs)
		dry := fs.Bool("dry-run", false, "copy (and --verify) inside one transaction, then roll it back: the target keeps nothing")
		verify := fs.Bool("verify", false, "after the copy, compare every table's row count and content hash, inside the same transaction")
		overwrite := fs.Bool("overwrite", false, "replace a target that already holds data or a finished move")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		f, t, err := dbMoveEnds(*from, *to)
		if err != nil {
			return err
		}
		rep, err := store.MoveDatabase(ctx, store.MoveOptions{
			From: f, To: t, DryRun: *dry, Verify: *verify, Overwrite: *overwrite, Out: out,
		})
		if err != nil {
			return err
		}
		if len(rep.Differ) > 0 {
			return fmt.Errorf("verify: %d table(s) differ", len(rep.Differ))
		}
		return nil
	case "verify":
		fs := flag.NewFlagSet("db verify", flag.ContinueOnError)
		from, to := dbMoveFlags(fs)
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		f, t, err := dbMoveEnds(*from, *to)
		if err != nil {
			return err
		}
		rep, err := store.VerifyDatabase(ctx, f, t, out)
		if err != nil {
			return err
		}
		if len(rep.Differ) > 0 {
			return fmt.Errorf("verify: %d table(s) differ", len(rep.Differ))
		}
		return nil
	}
	return fmt.Errorf("db: unknown command %q (migrate | verify)", args[0])
}

func dbMoveFlags(fs *flag.FlagSet) (from, to *string) {
	from = fs.String("from", "", "the SQLite database: a path or sqlite:///path (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	to = fs.String("to", "", "the Postgres connection string (default: $CCQUOTA_DB_URL; never printed)")
	return
}

// dbMoveEnds fills the defaults: --from as every other command finds the hub's
// database, --to from CCQUOTA_DB_URL — the Secret the hub itself reads, so the
// connection string never has to be typed onto a command line.
func dbMoveEnds(from, to string) (string, string, error) {
	f, err := resolveDB(store.MoveSourcePath(from))
	if err != nil {
		return "", "", err
	}
	if to == "" {
		to = os.Getenv("CCQUOTA_DB_URL")
	}
	if to == "" {
		return "", "", errors.New("no target: pass --to or set CCQUOTA_DB_URL")
	}
	return f, to, nil
}
