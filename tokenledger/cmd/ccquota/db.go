package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// defaultDBFile is where the hub keeps its database unless told otherwise. It
// sits beside the viewer token and the agent state, all under ~/.ccquota.
const defaultDBFile = "ccquota.db"

// resolveDB decides which database a command should act on: an explicit --db
// wins, then $CCQUOTA_DB, then ~/.ccquota/ccquota.db.
//
// The default used to be "ccquota.db", relative to the working directory. That
// is a trap for every command, because SQLite creates a missing file happily
// and none of them can tell a fresh database from the hub's: running `enroll`
// one directory over mints tokens into a brand-new file, prints them as if they
// worked, and the only symptom is `401 unrecognised enrollment token` in the
// agent's log on another machine. An absolute default means the commands land
// on the same database from wherever they are run.
func resolveDB(flagValue string) (string, error) {
	if flagValue != "" {
		return flagValue, nil
	}
	if env := os.Getenv("CCQUOTA_DB"); env != "" {
		return env, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot locate your home directory to find the database; pass --db: %w", err)
	}
	return filepath.Join(home, ".ccquota", defaultDBFile), nil
}

// resolveExistingDB is resolveDB for commands that READ AND MODIFY the hub's
// database — enrolling an endpoint, naming a subscription.
//
// Creating a database is never the right outcome for those: they are meaningful
// only against a hub that already exists, and a silently created one makes them
// report success while doing nothing that the hub will ever see. Only `ccquota
// hub` may bring a database into being.
func resolveExistingDB(flagValue string) (string, error) {
	path, err := resolveDB(flagValue)
	if err != nil {
		return "", err
	}
	switch _, err := os.Stat(path); {
	case err == nil:
		return path, nil
	case errors.Is(err, os.ErrNotExist):
		return "", fmt.Errorf(
			"no hub database at %s\n\n"+
				"This command changes the hub's own database, so it will not create one.\n"+
				"Run it on the machine hosting `ccquota hub`, and point it at that hub's\n"+
				"database with --db (or $CCQUOTA_DB) if it is not the default path.\n\n"+
				"Enrolling against the wrong database appears to succeed: the token is\n"+
				"printed as usual, and the agent using it is rejected with\n"+
				"\"401 unrecognised enrollment token\".", path)
	default:
		return "", fmt.Errorf("cannot read %s: %w", path, err)
	}
}
