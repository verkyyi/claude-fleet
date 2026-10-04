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
	"strconv"
	"strings"
	"time"
)

// ccquota lease — a node's side of the hub's issue leases (claude-fleet#1422).
//
// claude-fleet's dash-issue-session.sh runs it before opening a session on an
// issue (FLEET_HUB_LEASE_CMD), with the agent's own hub URL and enrollment
// token. One line on stdout, one exit code, so a shell script can branch on it
// without parsing JSON:
//
//	acquire  0  GRANTED <node>
//	         0  FORCED <node> <displaced node> <displaced worker_id>
//	         3  HELD <node> <worker_id> <expires RFC3339>
//	release  0  RELEASED | NOT_HELD
//	any      1  the hub could not be asked (stderr says why) — the caller
//	            carries on as a one-machine fleet
//	         2  usage

// leaseHeld is the exit code of an acquire someone else holds — the same 3
// dash-issue-session.sh exits with for "already claimed".
const leaseHeld = 3

// leaseTimeout bounds the whole round trip: a spawn waits on it, so an
// unreachable hub must cost seconds, not a TCP timeout.
const leaseTimeout = 8 * time.Second

func runLease(args []string) error {
	code, err := lease(args, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota lease:", err)
	}
	if code != 0 {
		os.Exit(code)
	}
	return nil
}

func lease(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("lease", flag.ContinueOnError)
	fs.SetOutput(stderr)
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub base URL")
	token := fs.String("token", os.Getenv("CCQUOTA_TOKEN"), "this endpoint's enrollment token")
	force := fs.Bool("force", false, "acquire: take the lease from a live holder (recorded on the hub)")
	fs.Usage = func() {
		fmt.Fprint(stderr, `Usage: ccquota lease acquire|release [--force] <owner/repo> <issue> <worker_id>

Take or give back the hub's lease on one issue (claude-fleet#1422).
Exit 0 granted/released, 3 held by another node, 1 hub unreachable, 2 usage.
`)
		fs.PrintDefaults()
	}
	if len(args) == 0 {
		fs.Usage()
		return 2, nil
	}
	action := args[0]
	if err := fs.Parse(args[1:]); err != nil {
		return 2, nil
	}
	rest := fs.Args()
	if (action != "acquire" && action != "release") || len(rest) != 3 {
		fs.Usage()
		return 2, nil
	}
	issue, err := strconv.Atoi(rest[1])
	if err != nil || issue <= 0 {
		return 2, fmt.Errorf("issue must be a positive number, not %q", rest[1])
	}
	if *hub == "" || *token == "" {
		return 1, errors.New("no hub configured (CCQUOTA_HUB_URL and CCQUOTA_TOKEN)")
	}
	body, _ := json.Marshal(map[string]any{"action": action, "repo": rest[0], "issue": issue,
		"worker_id": rest[2], "force": *force})
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(*hub, "/")+"/v1/node/lease", bytes.NewReader(body))
	if err != nil {
		return 1, err
	}
	req.Header.Set("Authorization", "Bearer "+*token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: leaseTimeout}).Do(req)
	if err != nil {
		return 1, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	type view struct {
		Node      string    `json:"node"`
		WorkerID  string    `json:"worker_id"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	var out struct {
		Granted   bool  `json:"granted"`
		Released  bool  `json:"released"`
		Lease     *view `json:"lease"`
		Holder    *view `json:"holder"`
		Displaced *view `json:"displaced"`
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusConflict {
		return 1, fmt.Errorf("hub answered HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return 1, fmt.Errorf("hub answered something that is not JSON")
	}
	switch {
	case action == "release":
		if out.Released {
			fmt.Fprintln(stdout, "RELEASED")
		} else {
			fmt.Fprintln(stdout, "NOT_HELD")
		}
		return 0, nil
	case !out.Granted && out.Holder != nil:
		fmt.Fprintf(stdout, "HELD %s %s %s\n", out.Holder.Node, out.Holder.WorkerID, out.Holder.ExpiresAt.UTC().Format(time.RFC3339))
		return leaseHeld, nil
	case out.Granted && out.Lease != nil && out.Displaced != nil:
		fmt.Fprintf(stdout, "FORCED %s %s %s\n", out.Lease.Node, out.Displaced.Node, out.Displaced.WorkerID)
		return 0, nil
	case out.Granted && out.Lease != nil:
		fmt.Fprintf(stdout, "GRANTED %s\n", out.Lease.Node)
		return 0, nil
	}
	return 1, errors.New("hub's answer names neither a lease nor a holder")
}
