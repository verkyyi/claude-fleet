package codex

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Profile struct {
	Name    string `json:"name"`
	Home    string `json:"home"`
	Default bool   `json:"default,omitempty"`
	Managed bool   `json:"managed"`
}

type registry struct {
	Active   string    `json:"active"`
	Profiles []Profile `json:"profiles"`
}

var profileName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$`)

func registryPath(userHome string) string {
	return filepath.Join(userHome, ".ccquota", "codex-profiles.json")
}

func readRegistry(userHome string) (registry, error) {
	var r registry
	b, err := os.ReadFile(registryPath(userHome))
	if os.IsNotExist(err) {
		return r, nil
	}
	if err != nil || len(b) > 1<<20 {
		return r, errors.New("could not read Codex profile registry")
	}
	if json.Unmarshal(b, &r) != nil {
		return r, errors.New("invalid Codex profile registry")
	}
	seen := map[string]bool{}
	for _, p := range r.Profiles {
		if !profileName.MatchString(p.Name) || p.Name == "default" || seen[p.Name] || !filepath.IsAbs(p.Home) {
			return r, errors.New("invalid or duplicate Codex profile registry entry")
		}
		seen[p.Name] = true
	}
	if r.Active != "" && r.Active != "default" && !seen[r.Active] {
		return r, errors.New("default Codex profile is no longer registered")
	}
	return r, nil
}

// Profiles includes the existing default home, named registrations, and
// explicitly configured extra homes. Canonical paths are collected only once.
func Profiles(userHome, defaultHome, extraHomes string) ([]Profile, error) {
	r, err := readRegistry(userHome)
	if err != nil {
		return nil, err
	}
	if defaultHome == "" {
		defaultHome = filepath.Join(userHome, ".codex")
	}
	if r.Active == "" {
		r.Active = "default"
	}
	all := []Profile{{Name: "default", Home: defaultHome, Managed: true}}
	for _, p := range r.Profiles {
		p.Managed = true
		all = append(all, p)
	}
	for _, home := range strings.Split(extraHomes, ",") {
		if home = strings.TrimSpace(home); home != "" {
			all = append(all, Profile{Name: "profile-" + ProfileID(expandHome(userHome, home))[:10], Home: home})
		}
	}
	out := []Profile{}
	seen := map[string]int{}
	for _, p := range all {
		p.Home, err = filepath.Abs(expandHome(userHome, p.Home))
		if err != nil {
			return nil, errors.New("invalid Codex profile directory")
		}
		p.Default = p.Name == r.Active
		id := ProfileID(p.Home)
		if i, ok := seen[id]; ok {
			// Prefer an explicit name for the existing default home without
			// changing its scanner cursor or account attribution boundary.
			if p.Name == r.Active || out[i].Name == "default" {
				p.Default = p.Default || out[i].Default
				out[i] = p
			}
			continue
		}
		seen[id] = len(out)
		out = append(out, p)
	}
	return out, nil
}

func expandHome(userHome, home string) string {
	if strings.HasPrefix(home, "~/") {
		return filepath.Join(userHome, home[2:])
	}
	return home
}

func updateRegistry(userHome string, change func(*registry) error) error {
	dir := filepath.Dir(registryPath(userHome))
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	unlock, err := AcquireProfile(dir)
	if err != nil {
		return err
	}
	defer unlock()
	r, err := readRegistry(userHome)
	if err != nil {
		return err
	}
	if err := change(&r); err != nil {
		return err
	}
	return atomicJSON(registryPath(userHome), r)
}

func AddProfile(userHome, name, home string) (Profile, error) {
	if !profileName.MatchString(name) || name == "default" {
		return Profile{}, errors.New("use 1–48 letters, digits, hyphens or underscores for the profile name; default is reserved")
	}
	if home == "" {
		home = filepath.Join(userHome, ".codex-accounts", name)
	}
	home, err := filepath.Abs(expandHome(userHome, home))
	if err != nil {
		return Profile{}, err
	}
	p := Profile{Name: name, Home: home}
	err = updateRegistry(userHome, func(r *registry) error {
		for _, old := range r.Profiles {
			if old.Name == name {
				if ProfileID(old.Home) == ProfileID(home) {
					return nil
				}
				return errors.New("profile name already points to a different directory")
			}
			if ProfileID(old.Home) == ProfileID(home) {
				return fmt.Errorf("directory is already registered as %s", old.Name)
			}
		}
		if err := os.MkdirAll(home, 0700); err != nil {
			return err
		}
		r.Profiles = append(r.Profiles, p)
		return nil
	})
	return p, err
}

func UseProfile(userHome, name string) error {
	return updateRegistry(userHome, func(r *registry) error {
		if name == "default" {
			r.Active = name
			return nil
		}
		for _, p := range r.Profiles {
			if p.Name == name {
				r.Active = name
				return nil
			}
		}
		return errors.New("unknown Codex profile; run ccquota codex list")
	})
}

func SelectProfile(userHome, defaultHome, name string) (Profile, error) {
	ps, err := Profiles(userHome, defaultHome, os.Getenv("CCQUOTA_CODEX_HOMES"))
	if err != nil {
		return Profile{}, err
	}
	for _, p := range ps {
		if p.Name == name || (name == "" && p.Default) || (name == "default" && ProfileID(p.Home) == ProfileID(defaultHome)) {
			return p, nil
		}
	}
	return Profile{}, errors.New("unknown Codex profile; run ccquota codex list")
}
