# ccquota — one binary, no build step for the dashboard.
#
# The dashboard is hand-written HTML/CSS/JS under web/dist and is embedded by
# `go build`. There is deliberately no npm pipeline: a contributor needs only a
# Go toolchain to produce the complete artifact.

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.Version=$(VERSION)
PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64

.PHONY: build test vet fmt lint dist clean run-hub

build:
	CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/ccquota ./cmd/ccquota

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -l -w .

lint: vet
	@test -z "$$(gofmt -l . | grep -v '^web/')" || (echo "gofmt needed:"; gofmt -l .; exit 1)

# Cross-compiles every supported endpoint platform. CGO_ENABLED=0 is what makes
# this work from any host without a cross toolchain — the SQLite driver is pure
# Go for exactly this reason.
dist:
	@mkdir -p dist
	@for p in $(PLATFORMS); do \
	  os=$${p%/*}; arch=$${p#*/}; ext=""; \
	  [ "$$os" = "windows" ] && ext=".exe"; \
	  echo "  $$os/$$arch"; \
	  CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -ldflags "$(LDFLAGS)" \
	    -o dist/ccquota-$$os-$$arch$$ext ./cmd/ccquota || exit 1; \
	done
	@ls -lh dist/

run-hub: build
	./bin/ccquota hub --addr 127.0.0.1:8787 --token dev-token

clean:
	rm -rf bin dist
