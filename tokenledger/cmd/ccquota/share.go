package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/store"
)

func runShare(args []string) error {
	fs := flag.NewFlagSet("share", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	name := fs.String("name", "", "who or what this link is for, e.g. \"conference talk\"")
	withCosts := fs.Bool("with-costs", false,
		"include a notional cost figure.\n"+
			"Off by default: an API-equivalent dollar amount shown to someone who\n"+
			"does not know it is notional reads as a bill")
	expires := fs.Duration("expires", 0, "expire the link after this long (e.g. 720h); 0 = never")
	list := fs.Bool("list", false, "list every link ever minted, including dead ones")
	revoke := fs.String("revoke", "", "revoke a link by `id`")
	base := fs.String("url", os.Getenv("CCQUOTA_PUBLIC_URL"),
		"public base URL of the hub, used to print the full link")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota share --name "<who it is for>"   mint a revocable public link
  ccquota share --list                     what has been handed out
  ccquota share --revoke <id>              kill one

A share link opens a SEPARATE, redacted page: totals over time, model mix, plan
utilization, and counts of machines/logins/projects. It never carries account
emails, project paths, machine names, OS logins, session ids or branches, and it
is not accepted anywhere else in the API. Mint one per recipient so you can
revoke one without disturbing the others.

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
	case *revoke != "":
		changed, err := st.RevokeShareLink(*revoke)
		if err != nil {
			return err
		}
		if !changed {
			return fmt.Errorf("no active link with id %q (already revoked, or never existed)", *revoke)
		}
		fmt.Printf("revoked %s; that link is dead immediately\n", *revoke)
		return nil

	case *list:
		links, err := st.ListShareLinks()
		if err != nil {
			return err
		}
		if len(links) == 0 {
			fmt.Println("no share links have been minted")
			return nil
		}
		now := time.Now().UTC()
		fmt.Printf("%-10s  %-9s  %-7s  %5s  %s\n", "ID", "STATUS", "COSTS", "USES", "FOR")
		for _, l := range links {
			costs := "hidden"
			if l.ShowCosts {
				costs = "shown"
			}
			fmt.Printf("%-10s  %-9s  %-7s  %5d  %s\n",
				l.ID, l.Status(now), costs, l.Uses, l.Label)
		}
		return nil

	case *name != "":
		tok, err := api.MintToken()
		if err != nil {
			return err
		}
		var exp *time.Time
		if *expires > 0 {
			t := time.Now().UTC().Add(*expires)
			exp = &t
		}
		link, err := st.CreateShareLink(*name, api.HashToken(tok), *withCosts, exp)
		if err != nil {
			return err
		}
		url := strings.TrimRight(*base, "/")
		if url == "" {
			url = "https://your-hub.example.com"
		}
		fmt.Printf("Minted %s for %q.\n\n  %s/share?token=%s\n\n",
			link.ID, link.Label, url, tok)
		if exp != nil {
			fmt.Printf("Expires %s. ", exp.Local().Format(time.RFC1123))
		}
		if *withCosts {
			fmt.Print("Notional costs are SHOWN on this link. ")
		}
		fmt.Printf("Revoke with:\n\n  ccquota share --revoke %s\n\n", link.ID)
		fmt.Println("The token is shown once and is not recoverable.")
		return nil

	default:
		fs.Usage()
		return fmt.Errorf("nothing to do: pass --name, --list or --revoke")
	}
}
