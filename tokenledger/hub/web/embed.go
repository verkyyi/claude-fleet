// Package web carries what the hub serves of the browser's: the tab icons,
// and the builds packed beside them before the image is built — the website,
// its documentation, the console and the way-in pages' theme. The old
// console that dist used to hold is gone (claude-fleet#3939); dist keeps
// only the three icons, for a hub whose site is off.
package web

import (
	"embed"
	"io/fs"
)

//go:embed all:dist
var dist embed.FS

// Assets returns dist — the tab icons — or nil when this binary carries none.
func Assets() fs.FS { return built(dist, "dist", "favicon.svg") }

// The public website and its documentation (claude-fleet#3584). Both are build
// outputs like the client pack — bin/site-build.sh and bin/docs-build.sh write
// them before the image is built (hub-deploy) — so only each directory's
// .gitkeep is committed, and a binary built without them serves neither.

//go:embed all:site
var site embed.FS

//go:embed all:docs
var docs embed.FS

// Site returns the built website (index.html, en/index.html, its assets), or
// nil when this binary carries none.
func Site() fs.FS { return built(site, "site", "index.html") }

// Docs returns the built documentation (zh/…, en/…), or nil.
func Docs() fs.FS { return built(docs, "docs", "zh/index.html") }

// The new console (claude-fleet#3925, EPIC #3923): bin/web-console-pack.sh
// copies extras/web-console/dist here before the image is built — app/ (the
// member side, /app) and admin/ (the admin side, /admin), each its own
// index.html and assets/. Only .gitkeep is committed.

//go:embed all:console
var console embed.FS

// Console returns the new console's build, or nil when this binary carries
// neither entry.
func Console() fs.FS {
	if c := built(console, "console", "app/index.html"); c != nil {
		return c
	}
	return built(console, "console", "admin/index.html")
}

// The way-in pages' theme (claude-fleet#3932, EPIC #3923 C9): bin/web-console-pack.sh
// copies extras/fleet-theme here — theme.css, fonts.css, fonts/, logo.svg —
// served at /app/assets/fleet-theme/. Only .gitkeep is committed.

//go:embed all:theme
var theme embed.FS

// Theme returns the packed theme, or nil when this binary carries none.
func Theme() fs.FS { return built(theme, "theme", "theme.css") }

func built(f embed.FS, dir, probe string) fs.FS {
	sub, err := fs.Sub(f, dir)
	if err != nil {
		return nil
	}
	if _, err := fs.Stat(sub, probe); err != nil {
		return nil
	}
	return sub
}
