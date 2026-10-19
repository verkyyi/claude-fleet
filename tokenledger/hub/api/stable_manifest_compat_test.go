package api

import "testing"

// A stable or a release from before the hub was its own module (claude-fleet#4814)
// has the client's manifest at the old path: it still counts as the manifest.
func TestStableManifestOldPathStillCounts(t *testing.T) {
	if !releasePathOK(stableManifestPathOld) || !releasePathOK(StableManifestPath) {
		t.Fatal("a release tree drops the client manifest at one of its two places")
	}
	files, err := releaseTree(map[string][]byte{stableManifestPathOld: []byte("bin/fleet\n"), "tokenledger/hub/api/a.go": nil})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := files[stableManifestPathOld]; !ok || len(files) != 1 {
		t.Fatalf("release tree of an old commit = %v, want its manifest only", files)
	}
}
