# ccquota — two builds of one name: the hub's (hub/cmd/ccquota) and the node's
# (agent/cmd/ccquota). Four modules: hub · agent · shared · e2e (claude-fleet#4814).
#
# The console, the website and its docs are packed into hub/web/ before an image is
# built (bin/web-console-pack.sh · site-build.sh · docs-build.sh) and embedded by
# `go build`; a plain `go build` serves the API, the way-in pages and the tab
# icons (hub/web/dist), and no console.

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SRCDIGEST ?= $(shell cd shared && GOWORK=off go run ./cmd/ccquota-srcdigest .. 2>/dev/null)
LDFLAGS := -s -w -X main.Version=$(VERSION) -X main.SrcDigest=$(SRCDIGEST)
PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64

.PHONY: build test vet fmt lint dist clean run-hub

MODULES := hub agent shared e2e

build:
	cd hub && CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o ../bin/ccquota ./cmd/ccquota

test:
	for m in $(MODULES); do (cd $$m && GOWORK=off go test ./...) || exit 1; done
	@command -v node >/dev/null && node --test hub/web/test/*.test.mjs || echo "node not found: skipping web tests"

vet:
	for m in $(MODULES); do (cd $$m && GOWORK=off go vet ./...) || exit 1; done

fmt:
	gofmt -l -w .

lint: vet
	@test -z "$$(gofmt -l . | grep -v '^hub/web/')" || (echo "gofmt needed:"; gofmt -l .; exit 1)

# Cross-compiles every supported endpoint platform — the node's build
# (agent/cmd/ccquota, claude-fleet#4813), stamped with the node's source digest.
# CGO_ENABLED=0 is what makes this work from any host without a cross toolchain.
dist:
	@mkdir -p dist
	@for p in $(PLATFORMS); do \
	  os=$${p%/*}; arch=$${p#*/}; ext=""; \
	  [ "$$os" = "windows" ] && ext=".exe"; \
	  echo "  $$os/$$arch"; \
	  (cd agent && CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -ldflags "$(LDFLAGS)" \
	    -o ../dist/ccquota-$$os-$$arch$$ext ./cmd/ccquota) || exit 1; \
	done
	@ls -lh dist/

run-hub: build
	./bin/ccquota hub --addr 127.0.0.1:8787 --token dev-token

clean:
	rm -rf bin dist
