package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/verkyyi/ccquota/internal/store"
)

func runTeam(args []string) error {
	fs := flag.NewFlagSet("team", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	endpoint := fs.String("endpoint", "", "the `endpoint id` to assign")
	set := fs.String("set", "", "the team `name`; pass an empty string to un-assign")
	list := fs.Bool("list", false, "list every endpoint and its team")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota team --list                              who is on which team
  ccquota team --endpoint <id> --set <team>        allocate a machine's spend
  ccquota team --endpoint <id> --set ""            un-assign it

Teams are assigned here, on the hub, and never reported by an endpoint: a
machine that could name its own team could move its spend onto another team's
budget. Team is resolved when a query runs, so re-assigning a machine moves its
whole history, not just what it does next.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
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

	switch {
	case *endpoint != "":
		if err := st.SetEndpointTeam(*endpoint, *set); err != nil {
			return err
		}
		if *set == "" {
			fmt.Printf("%s is now unassigned\n", *endpoint)
		} else {
			fmt.Printf("%s is now on %q\n", *endpoint, *set)
		}
		return nil

	case *list:
		eps, err := st.ListEndpoints("")
		if err != nil {
			return err
		}
		if len(eps) == 0 {
			fmt.Println("no endpoints are enrolled on this hub")
			return nil
		}
		fmt.Printf("%-24s  %-20s  %s\n", "ENDPOINT", "TEAM", "MACHINE")
		for _, e := range eps {
			team := e.Team
			if team == "" {
				team = "(unassigned)"
			}
			name := e.Label
			if name == "" {
				name = e.Hostname
			}
			fmt.Printf("%-24s  %-20s  %s\n", e.ID, team, name)
		}
		return nil

	default:
		fs.Usage()
		return fmt.Errorf("nothing to do: pass --list, or --endpoint with --set")
	}
}
