# Build
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=docker
RUN CGO_ENABLED=0 go build -ldflags "-s -w -X main.Version=${VERSION}" -o /out/ccquota ./cmd/ccquota

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
