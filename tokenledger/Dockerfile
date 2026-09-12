# Build
#
# --platform=$BUILDPLATFORM: compile natively on whatever machine is building and
# cross-compile to the target, instead of running the whole Go toolchain under
# QEMU. The binary is pure Go (CGO_ENABLED=0, modernc SQLite), so this is just
# GOARCH — and it turns a ~10 minute emulated build on an arm64 laptop into a
# native one.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
WORKDIR /src
# ★ 默认走国内代理：从境内（开发机与深圳的自建 runner 都是）直连 proxy.golang.org
#   会挂在那里几十分钟而不报错 —— 表现是「构建卡住，没有任何输出」。
#   direct 兜底，所以在能直连的环境里行为不变。
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=$GOPROXY
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=docker
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -ldflags "-s -w -X main.Version=${VERSION}" -o /out/ccquota ./cmd/ccquota

# Run
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -u 10001 ccquota \
 && mkdir -p /data && chown ccquota /data
COPY --from=build /out/ccquota /usr/local/bin/ccquota
USER ccquota
VOLUME /data
EXPOSE 8787
# Binds to all interfaces because a container's loopback is not reachable from
# outside it. Put TLS in front, and always pass a viewer token.
ENTRYPOINT ["ccquota", "hub", "--addr", "0.0.0.0:8787", "--db", "/data/ccquota.db"]
