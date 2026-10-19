// Command ccquota-srcdigest prints the digest of the node's Go source in a
// tokenledger/ directory (default "."): the Dockerfile stamps it into every
// ccquota it builds (-X main.SrcDigest), so a release's binary can be held to
// its commit (claude-fleet#2930, release.SourceDigest; the node's source since
// claude-fleet#4813). --image prints the hub image's (release.ImageSourceDigest).
package main

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

func main() {
	dir, digest := ".", release.SourceDigestDir
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--image" {
		digest, args = release.ImageSourceDigestDir, args[1:]
	}
	if len(args) > 0 {
		dir = args[0]
	}
	d, err := digest(dir)
	if err != nil || d == "" {
		fmt.Fprintf(os.Stderr, "ccquota-srcdigest: no Go source in %s: %v\n", dir, err)
		os.Exit(1)
	}
	fmt.Println(d)
}
