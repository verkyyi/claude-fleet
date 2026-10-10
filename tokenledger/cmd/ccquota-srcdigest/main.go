// Command ccquota-srcdigest prints the digest of the Go source in a
// tokenledger/ directory (default "."): the Dockerfile stamps it into every
// ccquota it builds (-X main.SrcDigest), so a release's binary can be held to
// its commit (claude-fleet#2930, release.SourceDigest).
package main

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

func main() {
	dir := "."
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	d, err := release.SourceDigestDir(dir)
	if err != nil || d == "" {
		fmt.Fprintf(os.Stderr, "ccquota-srcdigest: no Go source in %s: %v\n", dir, err)
		os.Exit(1)
	}
	fmt.Println(d)
}
