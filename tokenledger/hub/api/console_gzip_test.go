package api

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

// The console's text assets go out gzip'd when the browser takes it, as is
// otherwise; small files, images and the entry page are never touched (V9DJ E).
func TestConsoleAssetsGzip(t *testing.T) {
	js := strings.Repeat("console.log('fleet');\n", 400)
	png := strings.Repeat("\x89PNG", 600)
	s := &Server{ConsoleFS: fstest.MapFS{
		"app/index.html":      {Data: []byte("ENTRY")},
		"app/assets/main.js":  {Data: []byte(js)},
		"app/assets/tiny.css": {Data: []byte("a{}")},
		"app/assets/icon.png": {Data: []byte(png)},
	}}
	get := func(p, enc string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, p, nil)
		if enc != "" {
			r.Header.Set("Accept-Encoding", enc)
		}
		w := httptest.NewRecorder()
		s.serveConsole(w, r, "app", strings.TrimPrefix(p, "/app"))
		return w
	}
	w := get("/app/assets/main.js", "gzip, deflate, br")
	if w.Code != 200 || w.Header().Get("Content-Encoding") != "gzip" || !strings.Contains(w.Header().Get("Vary"), "Accept-Encoding") {
		t.Fatalf("main.js with gzip: %d enc=%q vary=%q", w.Code, w.Header().Get("Content-Encoding"), w.Header().Get("Vary"))
	}
	if w.Body.Len() >= len(js)/4 {
		t.Errorf("main.js gzip'd to %d of %d bytes", w.Body.Len(), len(js))
	}
	if ct := w.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("main.js Content-Type %q", ct)
	}
	zr, err := gzip.NewReader(bytes.NewReader(w.Body.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := io.ReadAll(zr); string(b) != js {
		t.Error("main.js does not decompress to the build")
	}
	if again := get("/app/assets/main.js", "gzip"); !bytes.Equal(again.Body.Bytes(), w.Body.Bytes()) {
		t.Error("a second read differs from the first")
	}
	for _, c := range []struct{ path, enc, want string }{
		{"/app/assets/main.js", "", js},             // no Accept-Encoding
		{"/app/assets/main.js", "gzip;q=0, br", js}, // gzip refused
		{"/app/assets/tiny.css", "gzip", "a{}"},     // too small to bother
		{"/app/assets/icon.png", "gzip", png},       // already compressed
		{"/app/chat", "gzip", "ENTRY"},              // the entry page
	} {
		w := get(c.path, c.enc)
		if w.Header().Get("Content-Encoding") != "" || w.Body.String() != c.want {
			t.Errorf("%s (Accept-Encoding %q): enc=%q body %d bytes; want as built", c.path, c.enc, w.Header().Get("Content-Encoding"), w.Body.Len())
		}
	}
}
