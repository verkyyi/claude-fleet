package api

import (
	"context"
	"errors"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
)

type stableCacheLocal struct {
	sha   string
	files map[string][]byte
}

func (local stableCacheLocal) PublishedStable() (string, bool) { return local.sha, true }
func (local stableCacheLocal) PublishedSeen(sha string) bool   { return sha == local.sha }
func (local stableCacheLocal) PublishedTree(string) (map[string][]byte, error) {
	return local.files, nil
}

func TestStableCacheReleaseEviction(t *testing.T) {
	sha := strings.Repeat("a", 40)
	files := map[string][]byte{
		StableManifestPath:    []byte("bin/fleet\nbin/fleet-logout.sh\n"),
		"bin/fleet":           []byte("fleet"),
		"bin/fleet-logout.sh": []byte("logout"),
	}
	for _, source := range []string{"local", "tarball"} {
		t.Run(source, func(t *testing.T) {
			stable := &StableSource{
				files: map[string][]byte{"old/bin/fleet": make([]byte, stableCacheMax-32)},
				size:  stableCacheMax - 32,
				whole: map[string]bool{"old": true},
			}
			if source == "local" {
				stable.Local = stableCacheLocal{sha: sha, files: files}
				stable.Offline = true
			} else {
				github := &fakeGitHub{tarball: true, rawDown: true, files: map[string]string{}}
				for path, body := range files {
					github.files[sha+"/"+path] = string(body)
				}
				server := httptest.NewServer(github)
				defer server.Close()
				stable.Repo, stable.CodeloadBase = "o/r", server.URL
				stable.RawBase = server.URL
			}
			for path, expected := range files {
				body, err := stable.File(context.Background(), sha, path)
				if err != nil || string(body) != string(expected) {
					t.Errorf("%s = %q, %v; want %q", path, body, err, expected)
				}
			}
			if stable.whole["old"] || !stable.whole[sha] {
				t.Errorf("whole releases = %v", stable.whole)
			}
			actualSize := 0
			for _, body := range stable.files {
				actualSize += len(body)
			}
			if stable.size != actualSize || actualSize > stableCacheMax {
				t.Errorf("cache size = %d; actual = %d", stable.size, actualSize)
			}
			if _, err := stable.File(context.Background(), sha, "bin/missing"); !errors.Is(err, errStableNotFound) {
				t.Errorf("missing file: %v", err)
			}
		})
	}
}

func TestStableCacheReplacementSize(t *testing.T) {
	stable := &StableSource{}
	stable.storeLocked("release/bin/fleet", []byte("first"))
	stable.storeLocked("release/bin/fleet", []byte("next"))
	if stable.size != len("next") {
		t.Fatalf("replacement size = %d; want %d", stable.size, len("next"))
	}
}

func TestStableCacheOversizedLocalRelease(t *testing.T) {
	sha := strings.Repeat("b", 40)
	files := map[string][]byte{StableManifestPath: []byte("bin/fleet\n"), "bin/fleet": []byte("fleet")}
	large := make([]byte, stableFileMax)
	for index := 0; index <= stableCacheMax/stableFileMax; index++ {
		files[fmt.Sprintf("bin/large-%d", index)] = large
	}
	files["private/secret"] = []byte("not a client file")
	stable := &StableSource{Local: stableCacheLocal{sha: sha, files: files}, Offline: true}
	for _, path := range []string{"bin/fleet", "bin/large-0", StableManifestPath} {
		body, err := stable.File(context.Background(), sha, path)
		if err != nil || len(body) != len(files[path]) {
			t.Errorf("%s: size %d, error %v", path, len(body), err)
		}
	}
	if stable.whole[sha] || stable.size > stableCacheMax {
		t.Fatalf("oversized release cached as complete: whole=%v size=%d", stable.whole, stable.size)
	}
	if _, err := stable.File(context.Background(), sha, "private/secret"); !errors.Is(err, errStableNotFound) {
		t.Fatalf("non-client file: %v", err)
	}
}
