package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// `ccquota endpoint` — the other half of `enroll`.
//
// Hub-local, with the same `-db` and the same access assumption as `enroll`:
// whoever can mint an endpoint can take one back. Nothing here is reachable
// over HTTP, so the attack surface is exactly what it was.
//
// A nested subcommand rather than `--retire` flags, following `ccquota codex`:
// retire and delete are different operations with different consequences --
// one keeps history, the other requires there to be none -- and a flag pair on
// one command invites passing both.

// newEndpointFlags builds a FlagSet carrying the flags that are valid for
// every verb. It is built twice per invocation -- once for flags written
// BEFORE the verb, once for flags written after -- because Go's flag package
// stops parsing at the first non-flag argument, so a single set would silently
// ignore the `--all` in `ccquota endpoint list --all`. Silently: the command
// would succeed and report the active endpoints, which is the wrong answer to
// the question that was asked.
func newEndpointFlags(usage func(*flag.FlagSet)) (*flag.FlagSet, *string, *bool) {
	fs := flag.NewFlagSet("endpoint", flag.ContinueOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	all := fs.Bool("all", false, "list: include retired endpoints")
	fs.Usage = func() { usage(fs) }
	return fs, dbPath, all
}

func runEndpoint(args []string) error {
	usage := func(fs *flag.FlagSet) {
		fmt.Fprint(fs.Output(), `Retire an endpoint that `+"`enroll`"+` minted.

  ccquota endpoint list [--all]        what is enrolled (--all: retired too)
  ccquota endpoint retire <id>         stop accepting its token; keep its history
  ccquota endpoint delete <id>         remove it entirely — only if it never reported

RETIRE is the one to use. It keeps the endpoint's row and every usage row
pointing at it, so past totals do not move, and its enrollment token stops
being accepted immediately — on usage pushes, repo and growth pushes, the live
report and the quota lease alike. There is no un-retire: the token is dead, and
bringing the row back would bring the token back with it. Re-enroll instead.

DELETE is for a token that was minted and never used — a one-off experiment, a
shipper replaced before it ever pushed. It refuses the moment the endpoint has
reported anything, because removing spend that is already in the ledger would
change what last month cost with nothing left to explain the difference.

Flags may be written on either side of the verb.

Flags:
`)
		fs.PrintDefaults()
	}

	// Pass 1: flags before the verb (`ccquota endpoint --db X list`).
	head, headDB, headAll := newEndpointFlags(usage)
	if err := head.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	rest := head.Args()
	if len(rest) == 0 {
		head.Usage()
		return errors.New("nothing to do: pass list, retire or delete")
	}
	action, rest := rest[0], rest[1:]

	// Pass 2: flags after the verb (`ccquota endpoint list --all`), which is
	// how anyone actually types it.
	tail, tailDB, tailAll := newEndpointFlags(usage)
	if err := tail.Parse(rest); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	dbPath, all := *headDB, *headAll || *tailAll
	if *tailDB != "" {
		dbPath = *tailDB
	}
	operands := tail.Args()

	dbFile, err := resolveExistingDB(dbPath)
	if err != nil {
		return err
	}
	st, err := store.Open(dbFile)
	if err != nil {
		return err
	}
	defer st.Close()

	switch action {
	case "list":
		if len(operands) != 0 {
			return fmt.Errorf("usage: ccquota endpoint list [--all] (unexpected %q)", operands[0])
		}
		return endpointList(st, all)
	case "retire":
		if len(operands) != 1 {
			return errors.New("usage: ccquota endpoint retire <endpoint id>")
		}
		return endpointRetire(st, operands[0])
	case "delete":
		if len(operands) != 1 {
			return errors.New("usage: ccquota endpoint delete <endpoint id>")
		}
		return endpointDelete(st, operands[0])
	default:
		head.Usage()
		return fmt.Errorf("unknown command %q: want list, retire or delete", action)
	}
}

// endpointList is the operator's inventory, so it lists EVERY kind -- agents
// and shippers alike. The fleet roster's kind = 'agent' filter is right for
// the dashboard and wrong here: a repo or growth shipper is one of the likelier
// things to need retiring (issue #42's own incident was a shipper), and one
// missing from this list is a token whose id nobody can look up.
func endpointList(st *store.Store, all bool) error {
	eps, err := st.ListEnrollments(all)
	if err != nil {
		return err
	}
	if len(eps) == 0 {
		if all {
			fmt.Println("no endpoints enrolled")
		} else {
			fmt.Println("no active endpoints (try --all for retired ones)")
		}
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tSTATUS\tKIND\tNAME\tLAST SEEN")
	for _, e := range eps {
		status := "active"
		if e.Retired() {
			status = "retired " + e.RetiredAt.Local().Format("2006-01-02")
		}
		// A shipper never reports usage by design, so "never" against one is
		// not the warning it is against an agent. Say so rather than letting
		// the column imply a broken machine.
		last := "never"
		if e.LastSeen != nil {
			last = e.LastSeen.Local().Format(time.RFC3339)
		} else if e.Kind != "agent" {
			last = "n/a"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n", e.ID, status, e.Kind, e.Label, last)
	}
	return w.Flush()
}

func endpointRetire(st *store.Store, id string) error {
	ep, err := st.EndpointByID(id)
	if err != nil {
		return err
	}
	changed, err := st.RetireEndpoint(id)
	if err != nil {
		return err
	}
	if !changed {
		return fmt.Errorf("%s was already retired (%s)", id,
			ep.RetiredAt.Local().Format(time.RFC3339))
	}
	name := ep.Label
	if name == "" {
		name = id
	}
	fmt.Printf("Retired %q (%s). Its enrollment token is no longer accepted.\n", name, id)

	// Say plainly what was kept. An operator who wanted the row gone should
	// find out now, from the machine that did the thing, rather than later
	// from a dashboard that still lists it.
	fp, err := st.EndpointFootprint(id)
	if err != nil {
		return err
	}
	if len(fp) == 0 {
		// "Nothing is keyed to it", not "it never reported": a repo or growth
		// shipper may well have pushed plenty, but those rows are keyed by
		// repository, never by endpoint (deliberately — one repo is worked by
		// endpoints on several plans, so naming one would be a guess presented
		// as a fact). Saying it never reported would be false for exactly the
		// kind of enrollment most likely to be retired.
		fmt.Printf("\nNothing in the ledger is keyed to it, so there is no history to keep.\n")
		if kind, err := st.EndpointKind(id); err == nil && kind != "agent" {
			fmt.Printf("(%s rows are keyed by repository, not by endpoint, so anything it\npushed is unaffected either way.)\n", kind)
		}
		fmt.Printf("\nTo remove the row as well:\n\n  ccquota endpoint delete %s\n", id)
		return nil
	}
	fmt.Print("\nIts history is kept, so past totals are unchanged:\n\n")
	for _, f := range fp {
		fmt.Printf("  %-28s %d rows\n", f.Table, f.Rows)
	}
	fmt.Print("\nIt is hidden from the dashboard roster; `ccquota endpoint list --all`\nand the roster's \"show retired\" toggle still show it.\n")
	return nil
}

func endpointDelete(st *store.Store, id string) error {
	ep, err := st.EndpointByID(id)
	if err != nil {
		return err
	}
	err = st.DeleteEndpoint(id)
	var inUse *store.InUseError
	if errors.As(err, &inUse) {
		// The refusal is the feature, so it explains itself and names the way
		// forward instead of just failing.
		fmt.Fprintf(os.Stderr, "%s has reported usage, so deleting it would change historical totals:\n\n", id)
		for _, f := range inUse.Footprint {
			fmt.Fprintf(os.Stderr, "  %-28s %d rows\n", f.Table, f.Rows)
		}
		fmt.Fprintf(os.Stderr, "\nRetire it instead — same effect on the roster and the token, and the\nnumbers stay true:\n\n  ccquota endpoint retire %s\n", id)
		return errors.New("refusing to delete an endpoint that has reported")
	}
	if err != nil {
		return err
	}
	name := ep.Label
	if name == "" {
		name = id
	}
	fmt.Printf("Deleted %q (%s). It had never reported, so no totals changed.\n", name, id)
	return nil
}
