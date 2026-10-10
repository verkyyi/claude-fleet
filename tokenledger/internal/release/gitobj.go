package release

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"path"
	"sort"
	"strconv"
	"strings"
)

// Git's own object hashes, so the hub can tell what a publish handed it IS the
// commit it names without trusting the road it came by (claude-fleet#2772,
// EPIC #2770 C2): the tree is hashed file by file out of `git archive`'s tar,
// the commit object's sha out of its own bytes, and the two must meet in the
// commit's `tree` line.

// GitFile is one file of a tree read out of an archive.
type GitFile struct {
	Data []byte
	Mode string // 100644 · 100755 · 120000 (Data = the link's target)
}

// ArchiveLimits bound what TreeFromArchive reads.
type ArchiveLimits struct {
	Files     int   // most entries; default 20000
	FileBytes int64 // largest file; default 16 MiB
	Total     int64 // all files together; default 256 MiB
}

func (l ArchiveLimits) or() ArchiveLimits {
	if l.Files <= 0 {
		l.Files = 20000
	}
	if l.FileBytes <= 0 {
		l.FileBytes = 16 << 20
	}
	if l.Total <= 0 {
		l.Total = 256 << 20
	}
	return l
}

// GitHash is git's sha1 of an object: "<kind> <len>\0<body>".
func GitHash(kind string, body []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "%s %d\x00", kind, len(body))
	h.Write(body)
	return hex.EncodeToString(h.Sum(nil))
}

// TreeFromArchive reads a `git archive --format=tar` stream (gzip or not) and
// returns its files and the tree sha git would give them. Only regular files,
// symlinks, directories and the archive's global header are allowed — anything
// else (a hard link, a device, a path that climbs) is an error, never skipped,
// so nothing can ride along that the hash does not cover.
func TreeFromArchive(r io.Reader, lim ArchiveLimits) (map[string]GitFile, string, error) {
	lim = lim.or()
	br := bufio.NewReader(r)
	if magic, err := br.Peek(2); err == nil && magic[0] == 0x1f && magic[1] == 0x8b {
		zr, err := gzip.NewReader(br)
		if err != nil {
			return nil, "", err
		}
		defer zr.Close()
		r = zr
	} else {
		r = br
	}
	tr := tar.NewReader(r)
	files := map[string]GitFile{}
	var total int64
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, "", err
		}
		switch hd.Typeflag {
		case tar.TypeXGlobalHeader:
			continue
		case tar.TypeDir:
			if !archivePathOK(strings.TrimSuffix(hd.Name, "/")) {
				return nil, "", fmt.Errorf("archive: bad directory %q", hd.Name)
			}
			continue // git has no empty trees: a directory is its files
		case tar.TypeReg, tar.TypeSymlink:
		default:
			return nil, "", fmt.Errorf("archive: %q is neither a file nor a symlink (type %q)", hd.Name, hd.Typeflag)
		}
		if !archivePathOK(hd.Name) {
			return nil, "", fmt.Errorf("archive: bad path %q", hd.Name)
		}
		if _, dup := files[hd.Name]; dup {
			return nil, "", fmt.Errorf("archive: %q twice", hd.Name)
		}
		if len(files) >= lim.Files {
			return nil, "", fmt.Errorf("archive: more than %d files", lim.Files)
		}
		f := GitFile{Mode: "100644"}
		if hd.Typeflag == tar.TypeSymlink {
			f.Mode, f.Data = "120000", []byte(hd.Linkname)
		} else {
			if hd.Size > lim.FileBytes {
				return nil, "", fmt.Errorf("archive: %q is larger than %d bytes", hd.Name, lim.FileBytes)
			}
			if hd.Mode&0o111 != 0 {
				f.Mode = "100755"
			}
			b, err := io.ReadAll(io.LimitReader(tr, hd.Size))
			if err != nil {
				return nil, "", err
			}
			if int64(len(b)) != hd.Size {
				return nil, "", fmt.Errorf("archive: %q cut short", hd.Name)
			}
			f.Data = b
		}
		if total += int64(len(f.Data)); total > lim.Total {
			return nil, "", fmt.Errorf("archive: more than %d bytes", lim.Total)
		}
		files[hd.Name] = f
	}
	if len(files) == 0 {
		return nil, "", errors.New("archive: no files")
	}
	sha, err := TreeSHA(files)
	return files, sha, err
}

func archivePathOK(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00") || path.Clean(p) != p {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "." || seg == ".." || seg == ".git" {
			return false
		}
	}
	return true
}

// TreeSHA is the sha of the git tree holding exactly files.
func TreeSHA(files map[string]GitFile) (string, error) {
	type node struct {
		files map[string]GitFile
		dirs  map[string]*node
	}
	root := &node{files: map[string]GitFile{}, dirs: map[string]*node{}}
	for p, f := range files {
		segs := strings.Split(p, "/")
		n := root
		for _, d := range segs[:len(segs)-1] {
			if _, clash := n.files[d]; clash {
				return "", fmt.Errorf("tree: %q is both a file and a directory", d)
			}
			c := n.dirs[d]
			if c == nil {
				c = &node{files: map[string]GitFile{}, dirs: map[string]*node{}}
				n.dirs[d] = c
			}
			n = c
		}
		leaf := segs[len(segs)-1]
		if _, clash := n.dirs[leaf]; clash {
			return "", fmt.Errorf("tree: %q is both a file and a directory", p)
		}
		n.files[leaf] = f
	}
	var hash func(n *node) string
	hash = func(n *node) string {
		type ent struct {
			key, name, mode string
			sha             []byte
		}
		var ents []ent
		for name, f := range n.files {
			s, _ := hex.DecodeString(GitHash("blob", f.Data))
			ents = append(ents, ent{name, name, f.Mode, s})
		}
		for name, c := range n.dirs {
			s, _ := hex.DecodeString(hash(c))
			// git sorts a tree as if a directory's name ended in "/"
			ents = append(ents, ent{name + "/", name, "40000", s})
		}
		sort.Slice(ents, func(i, j int) bool { return ents[i].key < ents[j].key })
		var buf bytes.Buffer
		for _, e := range ents {
			buf.WriteString(e.mode + " " + e.name + "\x00")
			buf.Write(e.sha)
		}
		return GitHash("tree", buf.Bytes())
	}
	return hash(root), nil
}

// Commit is a commit object read out of its own bytes.
type Commit struct {
	SHA     string
	Tree    string
	Parents []string
	Raw     []byte
}

// ParseCommit reads a raw commit object (`git cat-file commit <sha>`).
func ParseCommit(raw []byte) (*Commit, error) {
	c := &Commit{SHA: GitHash("commit", raw), Raw: raw}
	head, _, _ := bytes.Cut(raw, []byte("\n\n"))
	for i, line := range strings.Split(string(head), "\n") {
		k, v, _ := strings.Cut(line, " ")
		switch {
		case i == 0 && k != "tree":
			return nil, errors.New("commit: no tree line first")
		case k == "tree" && i == 0:
			c.Tree = v
		case k == "parent":
			c.Parents = append(c.Parents, v)
		}
	}
	if !ValidSHA(c.Tree) {
		return nil, fmt.Errorf("commit: bad tree %q", c.Tree)
	}
	for _, p := range c.Parents {
		if !ValidSHA(p) {
			return nil, fmt.Errorf("commit: bad parent %q", p)
		}
	}
	return c, nil
}

// ParseCommitBatch reads `git cat-file --batch` output of commit objects —
// "<sha> commit <size>\n<body>\n", repeated — each checked against the sha it
// is listed under. At most max commits.
func ParseCommitBatch(r io.Reader, max int) ([]*Commit, error) {
	br := bufio.NewReader(r)
	var out []*Commit
	for {
		line, err := br.ReadString('\n')
		if err == io.EOF && line == "" {
			return out, nil
		}
		if err != nil {
			return nil, fmt.Errorf("commits: %v", err)
		}
		f := strings.Fields(line)
		if len(f) != 3 || f[1] != "commit" || !ValidSHA(f[0]) {
			return nil, fmt.Errorf("commits: bad header %q", strings.TrimSpace(line))
		}
		n, err := strconv.Atoi(f[2])
		if err != nil || n < 0 || n > 1<<20 {
			return nil, fmt.Errorf("commits: bad size %q", f[2])
		}
		if len(out) >= max {
			return nil, fmt.Errorf("commits: more than %d", max)
		}
		body := make([]byte, n+1)
		if _, err := io.ReadFull(br, body); err != nil || body[n] != '\n' {
			return nil, fmt.Errorf("commits: %s cut short", f[0][:7])
		}
		c, err := ParseCommit(body[:n])
		if err != nil {
			return nil, err
		}
		if c.SHA != f[0] {
			return nil, fmt.Errorf("commits: %s hashes to %s", f[0][:7], c.SHA[:7])
		}
		out = append(out, c)
	}
}
