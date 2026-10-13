package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// runSvc is `ccquota svc` (claude-fleet#4003): the admin's tool for service
// principals — an identity like SPACE's back end that may dispatch, read and
// cancel runs on /v1/svc/ and nothing else — and their fcs_ tokens. It writes
// the hub's database directly, so only someone who holds that database (the
// hub's pod, its operator) can run it; POST /v1/fleet/svc is the same over
// HTTP, admin only. Every change is audited.
func runSvc(args []string) error {
	fs := flag.NewFlagSet("svc", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	scopes := fs.String("scopes", "", "create: the scopes, comma separated ("+strings.Join(store.SvcScopes, ",")+")")
	days := fs.Int("days", 365, "token issue: days until the token expires (0 = never)")
	reason := fs.String("reason", "", "token revoke: why, for the audit")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota svc list                                    every principal and its tokens
  ccquota svc create <name> --scopes runs:write,...   add svc:<name>
  ccquota svc token issue <name> [--days N]           mint a token (printed once)
  ccquota svc token revoke <prefix> [--reason why]    refuse it from the next call
  ccquota svc disable <name> | enable <name>          switch every token of it off / on

A service token (fcs_<prefix8>_<secret>) opens /v1/svc/ only, route by route
by scope; only its hash is stored. A principal holds at most two live tokens,
the old and the new during a rotation.

Flags:
`)
		fs.PrintDefaults()
	}
	// flags may follow the positional words: pull them apart first
	var words, flags []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
			if !strings.Contains(a, "=") && i+1 < len(args) && a != "-h" && a != "--help" {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		words = append(words, a)
	}
	if err := fs.Parse(flags); err != nil {
		return err
	}
	if len(words) == 0 {
		fs.Usage()
		return errors.New("nothing to do")
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
	if err := st.EnsureSvc(); err != nil {
		return err
	}
	actor := "cli:" + os.Getenv("USER")
	now := time.Now()
	arg := func(i int) (string, error) {
		if len(words) <= i {
			fs.Usage()
			return "", fmt.Errorf("%s: missing an argument", strings.Join(words, " "))
		}
		return words[i], nil
	}

	switch words[0] {
	case "list":
		ps, err := st.SvcPrincipals()
		if err != nil {
			return err
		}
		if len(ps) == 0 {
			fmt.Println("no service principals on this hub")
			return nil
		}
		for _, p := range ps {
			state := "enabled"
			if !p.Enabled {
				state = "DISABLED"
			}
			fmt.Printf("%s  %s  [%s]\n", p.ID, state, strings.Join(p.Scopes, " "))
			toks, err := st.SvcTokens(p.ID)
			if err != nil {
				return err
			}
			for _, t := range toks {
				fmt.Printf("  fcs_%s_…  created %s  %s\n", t.Prefix, t.Created.Format(time.RFC3339), svcTokenState(t, now))
			}
		}
		return nil

	case "create":
		name, err := arg(1)
		if err != nil {
			return err
		}
		p, err := api.SvcCreate(st, name, *scopes, actor, now)
		if err != nil {
			return err
		}
		fmt.Printf("%s created  [%s]\n", p.ID, strings.Join(p.Scopes, " "))
		return nil

	case "token":
		op, err := arg(1)
		if err != nil {
			return err
		}
		what, err := arg(2)
		if err != nil {
			return err
		}
		switch op {
		case "issue":
			tok, t, err := api.SvcIssue(st, what, *days, actor, now)
			if err != nil {
				return err
			}
			fmt.Fprintf(os.Stderr, "issued fcs_%s_… for %s (%s); the token is printed once, below\n",
				t.Prefix, t.Principal, svcTokenState(t, now))
			fmt.Println(tok)
			return nil
		case "revoke":
			t, e, err := api.SvcRevoke(st, what, actor, *reason, now)
			if err != nil {
				return err
			}
			svcRevList(st, e, now)
			fmt.Printf("fcs_%s_… of %s revoked at %s\n", t.Prefix, t.Principal, t.RevokedAt.Format(time.RFC3339))
			return nil
		}
		return fmt.Errorf("svc token: issue or revoke, not %q", op)

	case "disable", "enable":
		name, err := arg(1)
		if err != nil {
			return err
		}
		p, e, err := api.SvcSetEnabled(st, name, words[0] == "enable", actor, now)
		if err != nil {
			return err
		}
		if words[0] == "enable" {
			if rt, _ := envOrFile("CCQUOTA_FLEET_REVOCATIONS_TOKEN"); rt != "" {
				if _, _, err := st.LiftRevocations(e.Src); err != nil {
					fmt.Fprintln(os.Stderr, "revocation list:", err)
				}
			}
		} else {
			svcRevList(st, e, now)
		}
		fmt.Printf("%s %sd\n", p.ID, words[0])
		return nil
	}
	fs.Usage()
	return fmt.Errorf("unknown svc command %q", words[0])
}

// svcRevList puts a revocation on #3560's list — only while the list is on
// (the hub's own rule: with it off the table stays empty).
func svcRevList(st *store.Store, e store.Revocation, now time.Time) {
	if rt, _ := envOrFile("CCQUOTA_FLEET_REVOCATIONS_TOKEN"); rt == "" {
		return
	}
	if _, err := st.AddRevocations([]store.Revocation{e}, now); err != nil {
		fmt.Fprintln(os.Stderr, "revocation list:", err)
	}
}

func svcTokenState(t store.SvcToken, now time.Time) string {
	switch {
	case t.RevokedAt != nil:
		return "revoked " + t.RevokedAt.Format(time.RFC3339)
	case t.Expires != nil && !now.Before(*t.Expires):
		return "expired " + t.Expires.Format(time.RFC3339)
	case t.Expires != nil:
		return "live until " + t.Expires.Format(time.RFC3339)
	}
	return "live, no expiry"
}
