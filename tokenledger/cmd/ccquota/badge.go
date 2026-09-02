package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"time"

	"github.com/verkyyi/ccquota/internal/badge"
	"github.com/verkyyi/ccquota/internal/store"
)

// dayPeriod matches the only relative window a badge may carry.
//
// Go's time.ParseDuration has no day unit and would accept "24h" while
// rejecting "30d", which is backwards for a badge: the label a reader
// understands is days. Anything else is refused rather than quietly falling
// back to all-time, because a lifetime figure under a "7d" label is a lie.
var dayPeriod = regexp.MustCompile(`^([1-9][0-9]*)d$`)

func periodRange(period string, now time.Time) (start time.Time, all bool, err error) {
	if period == "" || period == "all" {
		return time.Time{}, true, nil
	}
	m := dayPeriod.FindStringSubmatch(period)
	if m == nil {
		return time.Time{}, false, fmt.Errorf(
			"unknown period %q: use \"all\" or a number of days like \"30d\"", period)
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return time.Time{}, false, fmt.Errorf("unknown period %q", period)
	}
	return now.AddDate(0, 0, -n), false, nil
}

func runBadge(args []string) error {
	fs := flag.NewFlagSet("badge", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	out := fs.String("out", "", "write to this file (default: stdout)")
	theme := fs.String("theme", "dark", "\"dark\" or \"light\"; chosen explicitly because a badge\n"+
		"loaded through <img> cannot read the reader's color scheme")
	period := fs.String("period", "all", "\"all\", or a window like \"30d\"")
	asJSON := fs.Bool("json", false, "emit shields.io endpoint JSON instead of an SVG")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota badge --out ccquota.svg --theme dark --period all
  ccquota badge --json --out ccquota.json      # shields.io endpoint schema

Renders this hub's totals as a badge. Entirely local: no server, no account,
no submission, and the rendered SVG contains no external reference of any kind
(an <img>-loaded SVG cannot fetch scripts, fonts, CSS or images).

Publish the result however you like -- commit the SVG to a profile repo and
reference it by raw.githubusercontent.com, or write the JSON to a gist and
point img.shields.io at it.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *theme != "dark" && *theme != "light" {
		return fmt.Errorf("unknown theme %q: use \"dark\" or \"light\"", *theme)
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

	d, err := badgeData(st, *period, *theme)
	if err != nil {
		return err
	}

	var payload []byte
	if *asJSON {
		payload, err = json.MarshalIndent(badge.ToShields(d), "", "  ")
		if err != nil {
			return fmt.Errorf("encode shields JSON: %w", err)
		}
		payload = append(payload, '\n')
	} else {
		payload = badge.Render(d)
	}

	if *out == "" {
		_, err = os.Stdout.Write(payload)
		return err
	}
	if err := os.WriteFile(*out, payload, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", *out, err)
	}
	fmt.Fprintf(os.Stderr, "wrote %s (%s, %s)\n", *out, d.LabelText(), d.MessageText())
	return nil
}

// badgeData reads the figure the badge shows.
//
// All-time uses LifetimeTotals, which is the same expression every other total
// on this hub uses. A windowed period sums the per-account buckets and discards
// their keys -- the badge must never carry an account identifier.
func badgeData(st *store.Store, period, theme string) (badge.Data, error) {
	d := badge.Data{Period: period, Theme: theme}
	if d.Period == "" {
		d.Period = "all"
	}

	start, all, err := periodRange(period, time.Now().UTC())
	if err != nil {
		return d, err
	}
	if all {
		turns, tokens, err := st.LifetimeTotals()
		if err != nil {
			return d, err
		}
		d.Turns, d.Tokens = turns, tokens
		return d, nil
	}

	buckets, err := st.UsageBy(store.AllAccounts, store.ByAccount, start, time.Now().UTC(), 1000)
	if err != nil {
		return d, err
	}
	for _, b := range buckets {
		d.Turns += b.Events
		d.Tokens += b.Tokens
	}
	return d, nil
}
