package release

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseTreeList(t *testing.T) {
	l, err := ParseTreeList([]byte("# c\nbin/\n.claude-plugin/\n*\n!bin/secret/\n!LICENSE\nkeep/one\n!keep/\n"))
	if err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]bool{
		"bin/fleet": true, ".claude-plugin/plugin.json": true, "README.md": true,
		"bin/secret/x": false, "LICENSE": false, ".gitignore": false, "docs/x": false,
		"keep/one": true, "keep/two": false, "bin/../x": false, "": false, "/bin/x": false,
	} {
		if l.Keep(p) != want {
			t.Errorf("Keep(%q) = %v", p, !want)
		}
	}
	for _, bad := range []string{"../x/\n", "bin/*\n", "/etc/\n", "# nothing\n", "a b\n"} {
		if _, err := ParseTreeList([]byte(bad)); err == nil {
			t.Errorf("ParseTreeList(%q) accepted", bad)
		}
	}
}

// The repo's own list: the whole install — .claude-plugin/ and extras/ too
// (claude-fleet#2771) — and never the hub's source, deploy tree or CI files.
func TestRepoTreeList(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "..", TreeListPath))
	if err != nil {
		t.Skip("not in the claude-fleet checkout:", err)
	}
	l, err := ParseTreeList(b)
	if err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]bool{
		"bin/fleet-lib.sh": true, "conf/release-tree.list": true, ".claude-plugin/plugin.json": true,
		"extras/iterm2/install.sh": true, "mod/fleet/x": true, "release.json": true, "README.md": true,
		"tokenledger/go.mod": false, "deploy/k8s/x": false, ".github/workflows/x.yml": false, ".gitignore": false,
	} {
		if l.Keep(p) != want {
			t.Errorf("Keep(%q) = %v", p, !want)
		}
	}
}
