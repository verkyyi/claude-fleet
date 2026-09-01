// Budget answers one question for a scheduler: is there room to start more work
// right now, on the subscription this machine would actually use?
//
// It exists because observability is not the same as a decision. The dashboard
// and MCP tools describe quota state to a human or a model; a dispatcher
// spawning workers on a timer needs a verdict it can branch on, in the shell,
// without parsing a page. `--gate` is that verdict, in the same shape the fleet
// already uses for its disk circuit-breaker: exit 0 to proceed, exit 3 to hold,
// one line of reason on stderr.
//
// ccquota stays READ-ONLY. It reports whether there is room; it never starts,
// stops or throttles anything. Handing a monitor a control channel back to
// every machine it watches is a far larger security surface than "tell me what
// my fleet spent", and the caller is better placed to decide what to do anyway.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/identity"
	"github.com/verkyyi/ccquota/internal/store"
)

// Exit codes, mirroring the fleet's existing gate convention so a caller can
// treat both guards identically.
const (
	exitGateHold = 3
)

// Verdicts.
const (
	verdictGo      = "go"
	verdictHold    = "hold"
	verdictUnknown = "unknown"
)

// BudgetWindow is one rate-limit window, flattened for a scheduler.
type BudgetWindow struct {
	Utilization    float64    `json:"utilization"`
	ResetsAt       *time.Time `json:"resets_at,omitempty"`
	PercentPerHour float64    `json:"percent_per_hour,omitempty"`
	ExhaustedAt    *time.Time `json:"exhausted_at,omitempty"`
}

// BudgetAccount is one subscription's headroom.
type BudgetAccount struct {
	AccountUUID string `json:"account_uuid"`
	Label       string `json:"label,omitempty"`
	Available   bool   `json:"available"`
	Reason      string `json:"reason,omitempty"`
	// HeadroomPct is 100 minus the FULLER of the two windows. A subscription is
	// as constrained as its tightest limit, so the five-hour window being calm
	// says nothing if the weekly one is nearly spent.
	HeadroomPct float64       `json:"headroom_pct"`
	FiveHour    *BudgetWindow `json:"five_hour,omitempty"`
	SevenDay    *BudgetWindow `json:"seven_day,omitempty"`
}

// BudgetReport is the whole answer.
type BudgetReport struct {
	Verdict    string          `json:"verdict"` // go | hold | unknown
	Reason     string          `json:"reason"`
	CeilingPct float64         `json:"ceiling_pct"`
	Scope      string          `json:"scope"` // the account uuid, or "all"
	Accounts   []BudgetAccount `json:"accounts"`
	Disclaimer string          `json:"disclaimer"`
}

const budgetDisclaimer = "Utilization is exact and account-wide. A verdict is advice about " +
	"headroom, not permission: ccquota never starts or stops anything."

func runBudget(args []string) error {
	fs := flag.NewFlagSet("budget", flag.ExitOnError)
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub base URL")
	token := fs.String("token", os.Getenv("CCQUOTA_VIEWER_TOKEN"), "viewer token")
	account := fs.String("account", "",
		"subscription to judge: a uuid, or `all`.\n"+
			"Default: the account THIS machine is logged into, because that is the\n"+
			"one work started here will spend. Headroom on a subscription this\n"+
			"machine cannot reach is not headroom")
	home := fs.String("home", "", "Claude Code home directory (default: your home)")
	ceiling := fs.Float64("ceiling", 90, "hold at or above this utilization, in percent")
	gate := fs.Bool("gate", false, "exit 0 to proceed, 3 to hold; reason on stderr")
	asJSON := fs.Bool("json", false, "print the full report as JSON")
	asTSV := fs.Bool("tsv", false,
		"print one tab-separated row per subscription: uuid, label, headroom%, available.\n"+
			"For shell callers — parseable with `read`, so a scheduler needs no jq")
	timeout := fs.Duration("timeout", 10*time.Second, "how long to wait for the hub")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota budget [flags]          report headroom on the subscription in scope
  ccquota budget --gate [flags]   exit 0 to proceed, 3 to hold (for a scheduler)

Unknown is never a hold. If the hub is unreachable or no endpoint could read
the limits, the gate OPENS and says why: a monitor that silently halts the work
it is meant to observe is worse than one that admits it cannot see.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}

	rep := budget(*hub, *token, *account, *home, *ceiling, *timeout)

	switch {
	case *asJSON:
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(rep); err != nil {
			return err
		}
	case *asTSV:
		printBudgetTSV(rep)
	case !*gate:
		printBudget(rep)
	}

	if *gate {
		if rep.Verdict == verdictHold {
			fmt.Fprintf(os.Stderr, "ccquota budget: HOLD — %s\n", rep.Reason)
			os.Exit(exitGateHold)
		}
		if rep.Verdict == verdictUnknown {
			// Loud enough to notice in a log, but not a refusal.
			fmt.Fprintf(os.Stderr, "ccquota budget: proceeding without a reading — %s\n", rep.Reason)
		}
	}
	return nil
}

// budget builds the report. It never returns an error: every failure is a
// verdict of "unknown" carrying its own reason, because a scheduler calling
// this on a timer needs an answer, not an exception.
func budget(hub, token, account, home string, ceiling float64, timeout time.Duration) BudgetReport {
	rep := BudgetReport{CeilingPct: ceiling, Disclaimer: budgetDisclaimer, Scope: account}

	if hub == "" {
		rep.Verdict, rep.Reason = verdictUnknown,
			"no hub configured (set --hub or CCQUOTA_HUB_URL)"
		return rep
	}

	// Default scope: what this machine is logged into. Resolved locally, so a
	// machine with no Claude Code login says so rather than silently judging
	// somebody else's subscription.
	if account == "" {
		h, err := homeDir(home)
		if err != nil {
			rep.Verdict, rep.Reason = verdictUnknown, "cannot locate a home directory: "+err.Error()
			return rep
		}
		id, err := identity.Detect(h)
		if err != nil {
			rep.Verdict, rep.Reason = verdictUnknown,
				"this machine has no readable Claude Code login, so there is no default "+
					"subscription to judge; pass --account: "+err.Error()
			return rep
		}
		account = id.AccountUUID
		rep.Scope = account
	}

	across, err := fetchHubLimits(hub, token, account, timeout)
	if err != nil {
		rep.Verdict, rep.Reason = verdictUnknown, "hub unreachable: "+err.Error()
		return rep
	}
	rep.Accounts = across

	return decideBudget(rep, ceiling)
}

// decideBudget turns headroom into a verdict.
//
// Split out from the fetching so the rule is testable without a hub, and so the
// rule itself stays readable: hold only when every subscription IN SCOPE is at
// or above the ceiling. With one account in scope — the normal case for a
// scheduler — that is simply "this subscription is full".
func decideBudget(rep BudgetReport, ceiling float64) BudgetReport {
	var readable, blocked int
	var worstLabel string
	var worstUtil float64
	var bestLabel string
	bestHeadroom := -1.0

	for _, a := range rep.Accounts {
		if !a.Available {
			continue
		}
		readable++
		used := 100 - a.HeadroomPct
		if used >= ceiling {
			blocked++
			if used > worstUtil {
				worstUtil, worstLabel = used, a.name()
			}
		}
		if a.HeadroomPct > bestHeadroom {
			bestHeadroom, bestLabel = a.HeadroomPct, a.name()
		}
	}

	switch {
	case readable == 0:
		rep.Verdict = verdictUnknown
		rep.Reason = "no endpoint on the subscription(s) in scope could read the account-wide limits"
	case blocked == readable:
		rep.Verdict = verdictHold
		rep.Reason = fmt.Sprintf("%s is at %.1f%% of a window, at or above the %.0f%% ceiling",
			worstLabel, worstUtil, ceiling)
		if readable > 1 {
			rep.Reason = fmt.Sprintf("all %d subscriptions in scope are at or above the %.0f%% ceiling "+
				"(worst: %s at %.1f%%)", readable, ceiling, worstLabel, worstUtil)
		}
	default:
		rep.Verdict = verdictGo
		rep.Reason = fmt.Sprintf("%s has %.1f%% headroom", bestLabel, bestHeadroom)
	}
	return rep
}

func (a BudgetAccount) name() string {
	if a.Label != "" {
		return a.Label
	}
	return a.AccountUUID
}

// fetchHubLimits reads /v1/limits and flattens it. account may be a uuid or "all".
func fetchHubLimits(hub, token, account string, timeout time.Duration) ([]BudgetAccount, error) {
	url := strings.TrimRight(hub, "/") + "/v1/limits?account=" + account
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	// "all" returns a list, a single account returns one view. The list shape
	// is deliberate — utilization is not summable — so handle both.
	if account == "all" {
		var across api.LimitsAcross
		if err := json.Unmarshal(body, &across); err != nil {
			return nil, err
		}
		out := make([]BudgetAccount, 0, len(across.PerAccount))
		for _, e := range across.PerAccount {
			out = append(out, flatten(e.AccountUUID, e.Label, e.Limits))
		}
		if len(out) == 0 {
			return nil, errors.New("the hub reports no subscriptions yet")
		}
		return out, nil
	}

	var view api.LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		return nil, err
	}
	// The single-account reading carries no label. Look one up: this string
	// ends up in a dispatcher's log as the reason work was held, and a uuid
	// there tells the operator nothing about which subscription to go look at.
	return []BudgetAccount{flatten(account, lookupLabel(hub, token, account, timeout), &view)}, nil
}

// lookupLabel returns a human name for an account, or "" if it cannot get one.
// Cosmetic by design: a failure here must never change a verdict.
func lookupLabel(hub, token, account string, timeout time.Duration) string {
	req, err := http.NewRequest(http.MethodGet, strings.TrimRight(hub, "/")+"/v1/accounts", nil)
	if err != nil {
		return ""
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var accts []store.Account
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&accts) != nil {
		return ""
	}
	for _, a := range accts {
		if a.AccountUUID == account {
			return a.Label()
		}
	}
	return ""
}

func flatten(uuid, label string, v *api.LimitsView) BudgetAccount {
	a := BudgetAccount{AccountUUID: uuid, Label: label}
	if v == nil {
		a.Reason = "no reading"
		return a
	}
	a.Available, a.Reason = v.Available, v.Reason
	if !v.Available {
		return a
	}
	used := 0.0
	if v.FiveHour != nil {
		a.FiveHour = &BudgetWindow{
			Utilization: v.FiveHour.Utilization, ResetsAt: v.FiveHour.ResetsAt,
			PercentPerHour: v.FiveHour.Burn.PercentPerHour, ExhaustedAt: v.FiveHour.Burn.ExhaustedAt,
		}
		used = v.FiveHour.Utilization
	}
	if v.SevenDay != nil {
		a.SevenDay = &BudgetWindow{
			Utilization: v.SevenDay.Utilization, ResetsAt: v.SevenDay.ResetsAt,
			PercentPerHour: v.SevenDay.Burn.PercentPerHour, ExhaustedAt: v.SevenDay.Burn.ExhaustedAt,
		}
		// The tighter of the two governs.
		if v.SevenDay.Utilization > used {
			used = v.SevenDay.Utilization
		}
	}
	a.HeadroomPct = 100 - used
	return a
}

func printBudget(rep BudgetReport) {
	fmt.Printf("%s — %s\n\n", strings.ToUpper(rep.Verdict), rep.Reason)
	for _, a := range rep.Accounts {
		if !a.Available {
			fmt.Printf("  %-28s  unreadable: %s\n", a.name(), a.Reason)
			continue
		}
		fmt.Printf("  %-28s  %5.1f%% headroom", a.name(), a.HeadroomPct)
		if a.FiveHour != nil {
			fmt.Printf("   5h %.1f%%", a.FiveHour.Utilization)
			if a.FiveHour.ExhaustedAt != nil {
				fmt.Printf(" (full ~%s)", a.FiveHour.ExhaustedAt.Local().Format("15:04"))
			}
		}
		if a.SevenDay != nil {
			fmt.Printf("   7d %.1f%%", a.SevenDay.Utilization)
		}
		fmt.Println()
	}
	fmt.Printf("\n%s\n", rep.Disclaimer)
}

// printBudgetTSV writes one row per subscription for a shell caller:
//
//	uuid\tlabel\theadroom_pct\tavailable
//
// Tab-separated and never quoted, so `while IFS=$'\t' read -r uuid label pct ok`
// is the whole parser. A scheduler wanting to rank subscriptions should not have
// to depend on jq being installed — the fleet's own selftests already have to
// skip when it is absent.
//
// An unreadable subscription is still printed, with available=0 and an empty
// headroom, rather than omitted: a caller ranking these must be able to tell
// "no headroom" from "we could not see", and a missing row hides the second.
func printBudgetTSV(rep BudgetReport) {
	for _, a := range rep.Accounts {
		avail, pct := "0", ""
		if a.Available {
			avail = "1"
			pct = strconv.FormatFloat(a.HeadroomPct, 'f', 1, 64)
		}
		fmt.Printf("%s\t%s\t%s\t%s\n", a.AccountUUID, a.Label, pct, avail)
	}
}
