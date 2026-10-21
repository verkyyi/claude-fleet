package api

import (
	"bytes"
	"compress/gzip"
	"hash/crc32"
	"net/http"
	"path"
	"strings"
	"sync"
)

// The console's assets are compressed on the way out (task V9DJ, change E):
// the app's main script is 1.16 MB as built and went out as is, every first
// visit; gzip makes it ~350 KB. A build's assets never change (their names
// carry a hash, served immutable), so each is compressed once and the result
// kept for the life of the process. Only text types are; an image or a font is
// already compressed.

// consoleGzipTypes are the asset extensions worth compressing.
var consoleGzipTypes = map[string]bool{
	".js": true, ".mjs": true, ".css": true, ".svg": true, ".json": true,
	".webmanifest": true, ".html": true, ".txt": true, ".map": true,
}

// consoleGzipMin is the size below which compression is not worth a header.
const consoleGzipMin = 1024

// consoleGzipCache holds each compressed asset, keyed by its name and its
// bytes' checksum (a test serves several builds from one process).
type consoleGzipCache struct {
	mu sync.Mutex
	m  map[consoleGzipKey][]byte
}

type consoleGzipKey struct {
	name string
	sum  uint32
	size int
}

var consoleGz consoleGzipCache

// get is the gzip bytes of b (asset name), compressed the first time.
func (c *consoleGzipCache) get(name string, b []byte) []byte {
	k := consoleGzipKey{name, crc32.ChecksumIEEE(b), len(b)}
	c.mu.Lock()
	z, ok := c.m[k]
	c.mu.Unlock()
	if ok {
		return z
	}
	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	zw.Write(b)
	zw.Close()
	z = buf.Bytes()
	c.mu.Lock()
	if c.m == nil {
		c.m = map[consoleGzipKey][]byte{}
	}
	c.m[k] = z
	c.mu.Unlock()
	return z
}

// acceptsGzip says whether r's Accept-Encoding takes gzip (q=0 refuses it).
func acceptsGzip(r *http.Request) bool {
	for _, part := range strings.Split(r.Header.Get("Accept-Encoding"), ",") {
		name, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		if !strings.EqualFold(strings.TrimSpace(name), "gzip") {
			continue
		}
		q := strings.ReplaceAll(strings.TrimSpace(params), " ", "")
		return q != "q=0" && q != "q=0.0" && q != "q=0.00" && q != "q=0.000"
	}
	return false
}

// consoleAsset is the body to serve for an asset: b, or its gzip bytes with
// Content-Encoding set when the asset is text and the browser takes gzip.
// Vary is set either way, for a cache in between.
func consoleAsset(w http.ResponseWriter, r *http.Request, name string, b []byte) []byte {
	if !consoleGzipTypes[path.Ext(name)] || len(b) < consoleGzipMin {
		return b
	}
	w.Header().Add("Vary", "Accept-Encoding")
	if !acceptsGzip(r) {
		return b
	}
	w.Header().Set("Content-Encoding", "gzip")
	return consoleGz.get(name, b)
}
