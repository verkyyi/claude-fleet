# Base images (claude-fleet#4133): every FROM names one of these two, so a
# builder whose docker.io road is down (the Shenzhen buildkitd resolves docker.io
# through a public mirror that answered 502 on 2026-10-14) can point them at a
# registry copy — `--opt build-arg:ALPINE_IMAGE=<registry>/alpine:3.20`, repo
# variable HUB_BASE_IMAGES on the train. Unset = docker.io, byte for byte.
ARG GO_IMAGE=golang:1.25-alpine
ARG ALPINE_IMAGE=alpine:3.20

# Build
#
# --platform=$BUILDPLATFORM: compile natively on whatever machine is building and
# cross-compile to the target, instead of running the whole Go toolchain under
# QEMU. The binary is pure Go (CGO_ENABLED=0, modernc SQLite), so this is just
# GOARCH — and it turns a ~10 minute emulated build on an arm64 laptop into a
# native one.
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
WORKDIR /src
# ★ 默认走国内代理：从境内（开发机与深圳的自建 runner 都是）直连 proxy.golang.org
#   会挂在那里几十分钟而不报错 —— 表现是「构建卡住，没有任何输出」。
#   direct 兜底，所以在能直连的环境里行为不变。
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=$GOPROXY
# Three modules: the root, shared/ (what the hub and the node both build in,
# claude-fleet#4811) and agent/ (the node, claude-fleet#4812), joined by the
# go.mods' replaces — go.work is a developer's convenience, never what an image
# builds from.
ENV GOWORK=off
COPY go.mod go.sum ./
COPY shared/go.mod shared/go.sum ./shared/
COPY agent/go.mod agent/go.sum ./agent/
RUN go mod download && cd agent && go mod download
COPY . .
# The client /install serves is packed from the repo before the build
# (claude-fleet#1803): bin/fleet-client-pack.sh && docker build … tokenledger/.
# An image without it would serve no client — refuse to build one.
RUN test -f internal/api/fleetclient/pack/bin/fleet || { \
      echo "no client in internal/api/fleetclient/pack/ — run bin/fleet-client-pack.sh before docker build" >&2; exit 1; }
# End VERSION with the commit (`prod-$(git rev-parse --short HEAD)`): the hub
# serves it on GET /version and fleet-doctor's hub-image row compares that
# commit with refs/tags/stable (claude-fleet#1696). `docker` names none.
ARG VERSION=docker
ARG TARGETOS
ARG TARGETARCH
# SrcDigest: the digest of the node's Go source (shared/ + agent/ — what the
# dist below compiles; claude-fleet#2930, #4813) — the hub builds a node release
# only from a commit whose node source hashes the same, so a release never
# carries a ccquota older (or newer) than its commit. The hub binary carries the
# same stamp: it is the DistSrc the hub vouches for (`ccquota version`'s src).
RUN go run github.com/verkyyi/claude-fleet/tokenledger/shared/cmd/ccquota-srcdigest . > /tmp/srcdigest
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -ldflags "-s -w -X main.Version=${VERSION} -X main.SrcDigest=$(cat /tmp/srcdigest)" -o /out/ccquota ./cmd/ccquota
# The agent binaries a joining machine downloads from this hub
# (/v1/node/dist/<os>-<arch>, claude-fleet#1418) — there are no tagged releases,
# and `go install` on a fresh SPOT box means installing Go first. Pure Go, so
# each is a cross-compile, not an emulated build. DIST_TARGETS="" skips them.
# Built from the node's own module (agent/cmd/ccquota, claude-fleet#4813): no
# hub code inside, the same subcommands (agent/cmd/ccquota/commands.txt), the
# same artifact names.
ARG DIST_TARGETS="darwin/arm64 darwin/amd64 linux/amd64 linux/arm64"
RUN mkdir -p /out/dist && cd agent && for t in $DIST_TARGETS; do \
      CGO_ENABLED=0 GOOS=${t%/*} GOARCH=${t#*/} \
      go build -ldflags "-s -w -X main.Version=${VERSION} -X main.SrcDigest=$(cat /tmp/srcdigest)" -o /out/dist/ccquota-${t%/*}-${t#*/} ./cmd/ccquota || exit 1; \
    done

# The chat entry's offline city database (claude-fleet#4039, #4034): ip2region's
# IPv4 xdb (~11 MB, Chinese place names; dual Apache-2.0 / MIT — its LICENSE.md
# ships beside it), fetched HERE at a pinned upstream commit and refused unless
# both files hash to the pins — never downloaded at run time. Any mirror will do
# because the hash decides: jsDelivr first (it answers from Shenzhen, where the
# cluster's buildkitd builds), GitHub raw second. To move it: a PR bumping the
# three pins (docs/dev/WEB-CHAT.md «城市库»).
FROM ${ALPINE_IMAGE} AS geo
ARG GEO_DB_COMMIT=0af9fb06b0651f0fe314b8794266bcce498532a9
ARG GEO_DB_SHA256=61b1c8cd4a1e0935fc1d3bd915350cf38e34ab54e34c9146154956ce97bfa047
ARG GEO_LICENSE_SHA256=fe01f2f8fcaafac539154e6aa80b0b7f8af54e01dc4d52322f72971991c6280e
ARG GEO_DB_MIRRORS="https://cdn.jsdelivr.net/gh/lionsoul2014/ip2region@{c} https://raw.githubusercontent.com/lionsoul2014/ip2region/{c}"
RUN set -eu; mkdir -p /out/ip2region; cd /out/ip2region; \
    fetch() { for m in $GEO_DB_MIRRORS; do \
        u="$(echo "$m" | sed "s/{c}/$GEO_DB_COMMIT/")/$1"; \
        wget -q -T 60 -O "$2" "$u" && echo "$3  $2" | sha256sum -c -s && { echo "geo: $2 ← $u"; return 0; }; \
        echo "geo: $u did not give the pinned $2" >&2; rm -f "$2"; \
      done; return 1; }; \
    fetch data/ip2region_v4.xdb ip2region_v4.xdb "$GEO_DB_SHA256"; \
    fetch LICENSE.md LICENSE.md "$GEO_LICENSE_SHA256"; \
    echo "lionsoul2014/ip2region@$GEO_DB_COMMIT data/ip2region_v4.xdb" > SOURCE

# Run
FROM ${ALPINE_IMAGE}
RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -u 10001 ccquota \
 && mkdir -p /data && chown ccquota /data
COPY --from=build /out/ccquota /usr/local/bin/ccquota
COPY --from=build /out/dist /usr/share/ccquota/dist
ENV CCQUOTA_FLEET_DIST_DIR=/usr/share/ccquota/dist
COPY --from=geo /out/ip2region /usr/share/ccquota/ip2region
# The hub's FLEET_NOTIFY_CMD (claude-fleet#4086): one path that execs `ccquota
# notify` — this image has no python3 or curl for the node's notifier. Where it
# goes is the environment's FLEET_NOTIFY_KF_* / FLEET_NOTIFY_WEBHOOK (Secret keys).
COPY notify/fleet-hub-notify.sh /usr/local/bin/fleet-hub-notify
USER ccquota
VOLUME /data
EXPOSE 8787
# Binds to all interfaces because a container's loopback is not reachable from
# outside it. Put TLS in front, and always pass a viewer token.
ENTRYPOINT ["ccquota", "hub", "--addr", "0.0.0.0:8787", "--db", "/data/ccquota.db"]
