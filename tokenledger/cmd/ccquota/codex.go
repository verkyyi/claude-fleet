package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"text/tabwriter"

	"github.com/verkyyi/ccquota/internal/codex"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/scan"
)

func runCodex(args []string) error {
	fs := flag.NewFlagSet("codex", flag.ContinueOnError)
	home := fs.String("home", "", "OS user home")
	binary := fs.String("codex-bin", os.Getenv("CCQUOTA_CODEX_BINARY"), "Codex executable")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), `Manage Codex accounts without copying login tokens.

  ccquota codex list [--json]                 Show accounts and renewal state
  ccquota codex add NAME [--codex-home DIR]    Register an existing or new home
  ccquota codex login [NAME] [--device-auth]   Official login for one profile
  ccquota codex use NAME                      Default for ccquota codex run
  ccquota codex run [NAME] [-- CODEX_ARGS...]  Launch with isolated credentials
  ccquota codex refresh [NAME]                Renew through official Codex

New homes default to ~/.codex-accounts/NAME. Agents discover registrations
automatically. Selecting a default affects new ccquota launches only.
Use global --home and --codex-bin flags before the subcommand.
`)
	}
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	args = fs.Args()
	if len(args) == 0 {
		fs.Usage()
		return nil
	}
	userHome, err := homeDir(*home)
	if err != nil {
		return err
	}
	defaultHome := scan.CodexHome(userHome, "")
	bin := codex.Binary(userHome, *binary)
	action, rest := args[0], args[1:]
	if action == "list" {
		jsonOutput := len(rest) == 1 && rest[0] == "--json"
		if len(rest) > 0 && !jsonOutput {
			return errors.New("usage: ccquota codex list [--json]")
		}
		ps, err := codex.Profiles(userHome, defaultHome, os.Getenv("CCQUOTA_CODEX_HOMES"))
		if err != nil {
			return err
		}
		type row struct {
			codex.Profile
			Account string             `json:"account,omitempty"`
			Email   string             `json:"email,omitempty"`
			Plan    string             `json:"plan,omitempty"`
			Login   *model.LoginHealth `json:"login"`
		}
		rows := []row{}
		for _, p := range ps {
			a, _ := codex.ReadAuth(p.Home)
			r := row{Profile: p, Login: codex.LoginHealth(p.Home, a, true)}
			if a != nil {
				r.Account, r.Email, r.Plan = a.Identity.AccountUUID, a.Identity.Email, a.Identity.SubscriptionType
			}
			rows = append(rows, r)
		}
		if jsonOutput {
			return json.NewEncoder(os.Stdout).Encode(rows)
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "PROFILE\tDEFAULT\tEMAIL\tPLAN\tLOGIN\tDIRECTORY")
		for _, r := range rows {
			selected := ""
			if r.Default {
				selected = "*"
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", r.Name, selected, r.Email, r.Plan, r.Login.State, r.Home)
		}
		return w.Flush()
	}
	name := ""
	if len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		name, rest = rest[0], rest[1:]
	}
	if action == "add" {
		add := flag.NewFlagSet("codex add", flag.ContinueOnError)
		dir := add.String("codex-home", "", "existing Codex home (default: a new independent directory)")
		if err := add.Parse(rest); err != nil {
			return err
		}
		if name == "" || len(add.Args()) != 0 {
			return errors.New("usage: ccquota codex add NAME [--codex-home DIR]")
		}
		p, err := codex.AddProfile(userHome, name, *dir)
		if err != nil {
			return err
		}
		if err := codex.RecordLogin(p.Home); err != nil {
			return errors.New("profile registered, but its login observation could not be saved")
		}
		fmt.Printf("Registered %s at %s. Agents discover it automatically.\n", p.Name, p.Home)
		fmt.Printf("Login: ccquota codex login %s\nLaunch: ccquota codex run %s\n", p.Name, p.Name)
		return nil
	}
	if action == "use" {
		if name == "" || len(rest) > 0 {
			return errors.New("usage: ccquota codex use NAME")
		}
		if err := codex.UseProfile(userHome, name); err != nil {
			return err
		}
		fmt.Printf("Default for new ccquota codex run launches: %s\n", name)
		return nil
	}
	p, err := codex.SelectProfile(userHome, defaultHome, name)
	if err != nil {
		return err
	}
	if action == "refresh" {
		if len(rest) > 0 {
			return errors.New("usage: ccquota codex refresh [NAME]")
		}
		a, err := codex.Maintain(context.Background(), bin, p.Home, true)
		_ = json.NewEncoder(os.Stdout).Encode(codex.LoginHealth(p.Home, a, true))
		return err
	}
	if action != "login" && action != "run" {
		return errors.New("unknown Codex account command; run ccquota codex -h")
	}
	if bin == "" {
		return errors.New("Codex CLI not found")
	}
	if action == "login" {
		if len(rest) > 1 || (len(rest) == 1 && rest[0] != "--device-auth") {
			return errors.New("usage: ccquota codex login [NAME] [--device-auth]")
		}
		if err := os.MkdirAll(p.Home, 0700); err != nil {
			return err
		}
		rest = append([]string{"login"}, rest...)
	} else if len(rest) > 0 && rest[0] == "--" {
		rest = rest[1:]
	}
	acquire := codex.AcquireProfile
	if action == "run" {
		acquire = codex.AcquireRunProfile
	}
	unlock, err := acquire(p.Home)
	if err != nil {
		return err
	}
	defer unlock()
	// The managed launcher participates in maintenance locking for its whole
	// lifetime. While it runs, Codex owns renewal for this profile.
	cmd := exec.Command(bin, append([]string{"-c", `cli_auth_credentials_store="file"`}, rest...)...)
	cmd.Env, cmd.Stdin, cmd.Stdout, cmd.Stderr = codex.ProfileEnv(p.Home), os.Stdin, os.Stdout, os.Stderr
	if action == "login" {
		// Resolve an explicitly relative --codex-bin before changing cwd.
		cmd.Path, err = filepath.Abs(cmd.Path)
		if err != nil {
			return errors.New("could not resolve Codex executable")
		}
		// sudo -H changes HOME but leaves the caller's working directory.
		// Login must not discover that user's project config. Normal runs
		// keep the caller's project directory.
		cmd.Dir = p.Home
		cmd.Env = append(cmd.Env, "PWD="+p.Home)
	}
	// The interactive child receives terminal signals directly. Keep the
	// parent alive until Wait releases the profile lock.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	if err := cmd.Start(); err != nil {
		return errors.New("could not start Codex")
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			select {
			case sig := <-signals:
				// Terminal SIGINT already reaches the foreground child. Do
				// not turn one Ctrl-C into two interrupts in the Codex TUI.
				if sig == syscall.SIGTERM {
					_ = cmd.Process.Signal(sig)
				}
			case <-done:
				return
			}
		}
	}()
	if err := cmd.Wait(); err != nil {
		return errors.New("Codex exited unsuccessfully; see its output above")
	}
	if action == "login" {
		return codex.RecordLogin(p.Home)
	}
	return nil
}
