// Package web carries the built dashboard.
//
// The SPA is compiled into the binary so a self-hoster deploys one file. When
// the binary is built without running the frontend build, dist holds only a
// placeholder and the hub says so rather than 404-ing mysteriously.
package web

import (
	"embed"
	"io/fs"
)

//go:embed all:dist
var dist embed.FS

// Assets returns the dashboard's file system rooted at dist, or nil when no
// dashboard was built in.
func Assets() fs.FS {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		return nil
	}
	if _, err := fs.Stat(sub, "index.html"); err != nil {
		return nil
	}
	return sub
}
