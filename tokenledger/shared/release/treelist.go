package release

import (
	"bufio"
	"bytes"
	"fmt"
	"strings"
)

// TreeListPath is the repo's one list of what an install holds
// (claude-fleet#2771): the hub filters a commit's tree by the copy inside that
// commit, the shell lints bin/'s reads against the same file, and C2's push
// sends it with the tree. Go cannot //go:embed above its module, so it is
// read from the tree being released, never compiled in.
const TreeListPath = "conf/release-tree.list"

// TreeList is a parsed release-tree.list. One entry a line, `#` comments:
//
//	dir/    every file under dir/
//	path    that one file
//	*       every top-level file whose name does not start with "."
//	!dir/   never anything under dir/ (wins over dir/ and *)
//	!path   never that file
//
// An exact `path` include is more specific than a `!dir/` exclude and wins
// over it (the client manifest under tokenledger/).
type TreeList struct {
	dirs, files, notDirs, notFiles []string
	top                            bool
}

// ParseTreeList reads a release-tree.list; an entry that could climb out of
// the tree, or a list that includes nothing, is an error.
func ParseTreeList(b []byte) (*TreeList, error) {
	l := &TreeList{}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for n := 1; sc.Scan(); n++ {
		e := strings.TrimSpace(sc.Text())
		if e == "" || strings.HasPrefix(e, "#") {
			continue
		}
		if e == "*" {
			l.top = true
			continue
		}
		neg := strings.HasPrefix(e, "!")
		e = strings.TrimPrefix(e, "!")
		dir := strings.HasSuffix(e, "/")
		if !validPath(strings.TrimSuffix(e, "/")) || strings.ContainsAny(e, "*?[ \t") {
			return nil, fmt.Errorf("%s:%d: bad entry %q", TreeListPath, n, sc.Text())
		}
		switch {
		case neg && dir:
			l.notDirs = append(l.notDirs, e)
		case neg:
			l.notFiles = append(l.notFiles, e)
		case dir:
			l.dirs = append(l.dirs, e)
		default:
			l.files = append(l.files, e)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if !l.top && len(l.dirs) == 0 && len(l.files) == 0 {
		return nil, fmt.Errorf("%s: includes nothing", TreeListPath)
	}
	return l, nil
}

// Keep: p belongs in the install.
func (l *TreeList) Keep(p string) bool {
	if !validPath(p) {
		return false
	}
	for _, f := range l.notFiles {
		if p == f {
			return false
		}
	}
	for _, f := range l.files {
		if p == f {
			return true
		}
	}
	for _, d := range l.notDirs {
		if strings.HasPrefix(p, d) {
			return false
		}
	}
	for _, d := range l.dirs {
		if strings.HasPrefix(p, d) {
			return true
		}
	}
	return l.top && !strings.Contains(p, "/") && !strings.HasPrefix(p, ".")
}
