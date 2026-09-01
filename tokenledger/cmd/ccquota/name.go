package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/verkyyi/ccquota/internal/store"
)

// runName lists subscriptions and gives them permanent names.
//
// A subscription identified by its rate-limit schedule has no email to
// discover — the fingerprint is correct but unreadable. Naming it must be a
// one-time act, so the name is stored on the hub and locked against every
// later automatic report; otherwise the operator would re-do it after each
// restart, which is not a workflow anyone keeps up.
func runName(args []string) error {
	fs := flag.NewFlagSet("name", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub URL (used instead of --db when set)")
	token := fs.String("token", os.Getenv("CCQUOTA_VIEWER_TOKEN"), "viewer token, with --hub")
	clear := fs.Bool("clear", false, "remove the name and let automatic naming resume")
	dedupe := fs.Bool("dedupe", false,
		"merge subscriptions that share a seven-day reset schedule.\n"+
			"Repairs a database that accumulated phantom accounts before the\n"+
			"fingerprint stopped including the rolling five-hour window")
	dryRun := fs.Bool("dry-run", false, "with --dedupe, show what would merge and change nothing")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota name [flags]                   list subscriptions and their names
  ccquota name [flags] <account> <name>  name one, permanently

The name is locked: later automatic reports (a tmux window option, an env var,
a login) will not overwrite it. Use --clear to unlock.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *dedupe {
		dbFile, err := resolveExistingDB(*dbPath)
		if err != nil {
			return err
		}
		st, err := store.Open(dbFile)
		if err != nil {
			return err
		}
		defer st.Close()
		return dedupeAccounts(st, *dryRun)
	}

	rest := fs.Args()
	if len(rest) == 0 {
		return listAccounts(*dbPath, *hub, *token)
	}
	account := rest[0]
	label := strings.TrimSpace(strings.Join(rest[1:], " "))
	if *clear {
		label = ""
	}
	if label == "" && !*clear {
		return errors.New("give a name, or pass --clear to remove one")
	}

	if *hub != "" {
		return nameViaHub(*hub, *token, account, label)
	}
	dbFile, err := resolveExistingDB(*dbPath)
	if err != nil {
		return err
	}
	st, err := store.Open(dbFile)
	if err != nil {
		return err
	}
	defer st.Close()
	if err := st.SetAccountLabel(account, label); err != nil {
		return err
	}
	if label == "" {
		fmt.Printf("cleared the name for %s; automatic naming resumes\n", account)
	} else {
		fmt.Printf("%s is now %q, and will stay that way\n", account, label)
	}
	return nil
}

func listAccounts(dbPath, hub, token string) error {
	var accts []store.Account

	if hub != "" {
		req, err := http.NewRequest(http.MethodGet, strings.TrimRight(hub, "/")+"/v1/accounts", nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
			return fmt.Errorf("hub returned HTTP %d: %s", resp.StatusCode, bytes.TrimSpace(b))
		}
		if err := json.NewDecoder(resp.Body).Decode(&accts); err != nil {
			return err
		}
	} else {
		dbFile, err := resolveExistingDB(dbPath)
		if err != nil {
			return err
		}
		st, err := store.Open(dbFile)
		if err != nil {
			return err
		}
		defer st.Close()
		if accts, err = st.ListAccounts(); err != nil {
			return err
		}
	}

	if len(accts) == 0 {
		fmt.Println("No subscriptions have reported to this hub yet.")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ACCOUNT\tNAME\tHOW IDENTIFIED\tENDPOINTS")
	for _, a := range accts {
		how := "login"
		if a.Inferred() {
			how = "rate-limit schedule (inferred)"
		}
		if a.LabelLocked {
			how += ", named by hand"
		}
		name := a.Label()
		if name == a.AccountUUID {
			name = "—"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%d\n", a.AccountUUID, name, how, a.EndpointCount)
	}
	w.Flush()

	fmt.Fprint(os.Stderr, "\nName one permanently:  ccquota name <account> <name>\n")
	return nil
}

func nameViaHub(hub, token, account, label string) error {
	body, err := json.Marshal(map[string]string{"account": account, "label": label})
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost,
		strings.TrimRight(hub, "/")+"/v1/accounts/label", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("hub returned HTTP %d: %s", resp.StatusCode, bytes.TrimSpace(b))
	}
	fmt.Printf("%s is now %q, and will stay that way\n", account, label)
	return nil
}

// dedupeAccounts folds phantom subscriptions into the real ones.
//
// A fingerprint that shares a seven-day reset schedule with another account IS
// that account — the schedule is the very thing the fingerprint is computed
// from. Going forward the hub resolves this at ingest, but usage already split
// across the phantoms stays split until something reunites it.
func dedupeAccounts(st *store.Store, dryRun bool) error {
	dupes, err := st.DuplicateAccountsBySchedule()
	if err != nil {
		return err
	}
	if len(dupes) == 0 {
		fmt.Println("no duplicate subscriptions: every account has a distinct seven-day reset schedule")
		return nil
	}
	for src, dst := range dupes {
		if dryRun {
			fmt.Printf("would merge %s -> %s\n", src, dst)
			continue
		}
		moved, err := st.MergeAccount(src, dst)
		if err != nil {
			return fmt.Errorf("merge %s into %s: %w", src, dst, err)
		}
		fmt.Printf("merged %s into %s (%d turns moved)\n", src, dst, moved)
	}
	if dryRun {
		fmt.Printf("\n%d merge(s) pending; re-run without --dry-run to apply\n", len(dupes))
	}
	return nil
}
