package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func runPlan(args []string) error {
	fs := flag.NewFlagSet("plan", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	set := fs.String("set", "", "the `plan` to price (matches a subscription's type, e.g. max)")
	source := fs.String("source", model.SourceClaude, "which vendor's `source` this plan belongs to: claude, codex, ...")
	monthly := fs.Float64("monthly", -1, "what the plan costs per month, per seat")
	currency := fs.String("currency", store.DefaultCurrency, "ISO `currency` of --monthly")
	from := fs.String("from", "", "RFC3339 `date` this price took effect (default: now)")
	list := fs.Bool("list", false, "show every recorded price, including superseded ones")
	spend := fs.Bool("spend", false, "what the subscriptions actually cost over --days")
	days := fs.Int("days", 30, "how many `days` back --spend covers")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota plan --list                                     every price, current and superseded
  ccquota plan --set max --monthly 200                    price a plan from now on
  ccquota plan --set max --monthly 250 --from 2026-10-01  record a price change
  ccquota plan --spend --days 30                          real subscription spend

What a plan costs is the one figure the hub cannot observe: no transcript
attests to it, so an operator has to say. Without it the only money figure
available is the notional token cost, which is precisely the figure that is
NOT an invoice.

This is REAL money. It may be added to a metered gateway bill; it must never
be added to the notional token cost. A plan nobody has priced is reported as
unpriced, never as free.

Prices are effective-dated and appended, never overwritten: recording a change
leaves last month's figures priced at last month's price. Seats are counted
from the accounts on the plan at query time, so nothing has to be kept in step
by hand.

Prices can also be declared in the --pricing overrides file that "ccquota hub"
already takes, under a "plans" key:

  {"plans": [{"plan": "max", "source": "claude", "monthly_cost": 200,
              "currency": "USD", "effective_from": "2026-01-01T00:00:00Z"}]}

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
	case *set != "":
		if *monthly < 0 {
			return fmt.Errorf("--set %s needs --monthly: a plan with no amount is not priced, and 0 would claim it is free", *set)
		}
		start := time.Now().UTC()
		if *from != "" {
			if start, err = time.Parse(time.RFC3339, *from); err != nil {
				return fmt.Errorf("--from %q is not RFC3339 (e.g. 2026-10-01T00:00:00Z): %w", *from, err)
			}
		}
		p := model.SubscriptionPlan{
			Plan: *set, Source: *source, MonthlyCost: *monthly,
			Currency: *currency, EffectiveFrom: start.UTC(),
		}
		if err := st.SetPlanPrice(p); err != nil {
			return err
		}
		fmt.Printf("%s/%s costs %.2f %s per seat per month from %s\n",
			*source, *set, *monthly, *currency, start.UTC().Format(time.RFC3339))
		return nil

	case *list:
		plans, err := st.ListPlanPrices()
		if err != nil {
			return err
		}
		if len(plans) == 0 {
			fmt.Println("no subscription prices recorded; see 'ccquota plan -h'")
			return nil
		}
		fmt.Printf("%-10s  %-12s  %14s  %-22s  %s\n", "SOURCE", "PLAN", "PER MONTH", "FROM", "UNTIL")
		for _, p := range plans {
			until := "(current)"
			if p.EffectiveTo != nil {
				until = p.EffectiveTo.Format(time.RFC3339)
			}
			fmt.Printf("%-10s  %-12s  %10.2f %-3s  %-22s  %s\n",
				p.Source, p.Plan, p.MonthlyCost, p.Currency, p.EffectiveFrom.Format(time.RFC3339), until)
		}
		return nil

	case *spend:
		if *days < 1 {
			return fmt.Errorf("--days must be at least 1, got %d", *days)
		}
		end := time.Now().UTC()
		rows, err := st.SubscriptionSpendOver(store.AllAccounts, end.AddDate(0, 0, -*days), end)
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			fmt.Printf("no subscriptions seen in the last %d days\n", *days)
			return nil
		}
		fmt.Printf("%-10s  %-12s  %6s  %8s  %s\n", "SOURCE", "PLAN", "SEATS", "MONTHS", "SPEND")
		totals, unpriced := map[string]float64{}, 0
		for _, r := range rows {
			amount := "unpriced"
			if r.Priced {
				amount = fmt.Sprintf("%.2f %s", r.Amount, r.Currency)
				totals[r.Currency] += r.Amount
			} else {
				unpriced++
			}
			fmt.Printf("%-10s  %-12s  %6d  %8.2f  %s\n", r.Source, r.Plan, r.Seats, r.Months, amount)
		}
		for cur, total := range totals {
			fmt.Printf("\nreal subscription spend over %d days: %.2f %s\n", *days, total, cur)
		}
		if unpriced > 0 {
			fmt.Printf("%d plan(s) have no price, so that total is LOW by however much they cost.\n"+
				"Price them with 'ccquota plan --set <plan> --monthly <amount>'.\n", unpriced)
		}
		fmt.Print("\nThis is real, billed money. The notional token cost reported elsewhere is\n" +
			"not, and the two must never be added together.\n")
		return nil

	default:
		fs.Usage()
		return fmt.Errorf("nothing to do: pass --list, --spend, or --set with --monthly")
	}
}
