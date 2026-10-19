package release

import (
	"archive/tar"
	"bytes"
	"os/exec"
	"strings"
	"testing"
)

// claude-fleet#2772: the tree sha out of a real `git archive` and the commit
// sha out of real `git cat-file --batch` are git's own — checked against git.
func TestTreeFromArchiveMatchesGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	dir := t.TempDir()
	run := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(cmd.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	run("init", "-q")
	write := func(p, s string, exe bool) {
		t.Helper()
		cmd := exec.Command("sh", "-c", `mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1" && if [ "$3" = 1 ]; then chmod +x "$1"; fi`, "sh", p, s, map[bool]string{true: "1", false: "0"}[exe])
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v %s", err, out)
		}
	}
	// git sorts "a-b/" < "a.b" < "a/" (a directory as if its name ended in "/")
	write("a-b/x", "x", false)
	write("a.b", "dot", false)
	write("a/c", "nested", true)
	write("b", "B", false)
	run("add", "a-b", "a.b", "a/c", "b")
	if out, err := exec.Command("ln", "-s", "b", dir+"/link").CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	run("add", "link")
	run("commit", "-qm", "one")
	write("bin/tool", "#!/bin/sh\n", true)
	run("add", "bin/tool")
	run("commit", "-qm", "two")
	head := strings.TrimSpace(run("rev-parse", "HEAD"))
	tree := strings.TrimSpace(run("rev-parse", "HEAD^{tree}"))

	arch := exec.Command("git", "archive", "--format=tar", head)
	arch.Dir = dir
	tarb, err := arch.Output()
	if err != nil {
		t.Fatal(err)
	}
	files, got, err := TreeFromArchive(bytes.NewReader(tarb), ArchiveLimits{})
	if err != nil {
		t.Fatal(err)
	}
	if got != tree {
		t.Fatalf("tree %s, git says %s", got, tree)
	}
	if files["link"].Mode != "120000" || files["bin/tool"].Mode != "100755" || files["b"].Mode != "100644" {
		t.Fatalf("modes: %+v", files)
	}

	batch := exec.Command("git", "cat-file", "--batch")
	batch.Dir = dir
	batch.Stdin = strings.NewReader(run("rev-list", "--first-parent", "HEAD"))
	out, err := batch.Output()
	if err != nil {
		t.Fatal(err)
	}
	cs, err := ParseCommitBatch(bytes.NewReader(out), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(cs) != 2 || cs[0].SHA != head || cs[0].Tree != tree || len(cs[0].Parents) != 1 || cs[0].Parents[0] != cs[1].SHA || len(cs[1].Parents) != 0 {
		t.Fatalf("commits: %+v", cs)
	}

	// one byte off anywhere and the tree is another
	bad := bytes.Replace(tarb, []byte("#!/bin/sh"), []byte("#!/bin/sH"), 1)
	if _, s, err := TreeFromArchive(bytes.NewReader(bad), ArchiveLimits{}); err != nil || s == tree {
		t.Fatalf("tampered archive: %v, tree %s", err, s)
	}
	// a commit body edited under its listed sha is refused
	if _, err := ParseCommitBatch(bytes.NewReader(bytes.Replace(out, []byte("two"), []byte("tw0"), 1)), 10); err == nil {
		t.Fatal("edited commit accepted")
	}
}

func TestTreeFromArchiveRefusesOddEntries(t *testing.T) {
	for _, hd := range []*tar.Header{
		{Name: "../x", Typeflag: tar.TypeReg, Mode: 0o644},
		{Name: "a/./b", Typeflag: tar.TypeReg, Mode: 0o644},
		{Name: ".git/config", Typeflag: tar.TypeReg, Mode: 0o644},
		{Name: "h", Typeflag: tar.TypeLink, Linkname: "x"},
		{Name: "dev", Typeflag: tar.TypeChar},
	} {
		var buf bytes.Buffer
		tw := tar.NewWriter(&buf)
		_ = tw.WriteHeader(&tar.Header{Name: "ok", Typeflag: tar.TypeReg, Mode: 0o644, Size: 1})
		_, _ = tw.Write([]byte("x"))
		_ = tw.WriteHeader(hd)
		_ = tw.Close()
		if _, _, err := TreeFromArchive(&buf, ArchiveLimits{}); err == nil {
			t.Errorf("%s (type %q) accepted", hd.Name, hd.Typeflag)
		}
	}
}

// The whole claude-fleet commit this test runs in: the tree sha out of its
// archive is the one git names.
func TestTreeFromArchiveThisRepo(t *testing.T) {
	top, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		t.Skip("not in a git checkout")
	}
	root := strings.TrimSpace(string(top))
	want, err := exec.Command("git", "-C", root, "rev-parse", "HEAD^{tree}").Output()
	if err != nil {
		t.Skip(err)
	}
	arch := exec.Command("git", "-C", root, "archive", "--format=tar", "HEAD")
	tarb, err := arch.Output()
	if err != nil {
		t.Skip(err)
	}
	_, got, err := TreeFromArchive(bytes.NewReader(tarb), ArchiveLimits{})
	if err != nil {
		t.Fatal(err)
	}
	if got != strings.TrimSpace(string(want)) {
		t.Fatalf("tree %s, git says %s", got, want)
	}
}
