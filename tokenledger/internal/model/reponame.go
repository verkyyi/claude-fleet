package model

import (
	"fmt"
	"strings"
)

// ValidRepoName accepts the "owner/name" spelling GitHub uses and nothing else.
//
// A spend row's git_repo is a grouping key, so "Owner/Name", "owner/name/"
// and "https://github.com/owner/name" must not be allowed to become three
// separate repositories that never reconcile. Rejecting is the only honest
// option: silently normalising would make a typo invisible, and the hub cannot
// know which spelling was intended.
func ValidRepoName(repo string) error {
	if repo == "" {
		return fmt.Errorf("repo is required")
	}
	owner, name, ok := strings.Cut(repo, "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
		return fmt.Errorf("repo %q is not owner/name", repo)
	}
	if strings.TrimSpace(repo) != repo {
		return fmt.Errorf("repo %q has surrounding whitespace", repo)
	}
	return nil
}
