# extras/spot-node — the image of a SPOT execution node (issue #1428, EPIC
# #1419 R1): everything a fleet machine has (git, tmux, gh, python3, zsh,
# Claude Code, Codex CLI, claude-fleet itself, the ccquota agent), as one
# unprivileged login, started by the hub on the cluster's SPOT machines and
# released again when idle.
#
# Build from the REPO ROOT (the fleet install is copied from this checkout):
#
#   docker build -f extras/spot-node/Dockerfile \
#     --build-arg VERSION=$(git rev-parse --short HEAD) \
#     --platform linux/amd64 -t <registry>/ccquota-node:<tag> .
#
# Run (the hub does this; by hand for a test):
#
#   docker run --rm -e CCQUOTA_HUB_URL=https://hub… -e FLEET_JOIN_CODE=fj_… \
#     -e FLEET_NODE_KIND=ephemeral <image>
#
# The container's PID 1 is tini, so the kubelet's SIGTERM reaches the agent
# (which tells the hub and moves idle sessions off before it exits) and the
# tmux server's orphans are reaped. No systemd, no launchd: the fleet's
# background daemons do not run here — the hub drives the node (worker_start,
# messages, moves), which is all a 30-minute machine needs.
#
# Build args:
#   GOPROXY            Go module proxy for the agent build (国内默认 goproxy.cn)
#   VERSION            stamped into the agent binary
#   CLAUDE_INSTALL=1   install Claude Code (claude.ai/install.sh); 0 skips (CI)
#   CODEX_INSTALL=1    install the Codex CLI (npm i -g @openai/codex); 0 skips
#   NPM_REGISTRY       npm registry for the Codex install

# ── 1. the agent, from this checkout ───────────────────────────────────────
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS agent
WORKDIR /src
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=$GOPROXY
COPY tokenledger/go.mod tokenledger/go.sum ./
RUN go mod download
COPY tokenledger/ .
ARG VERSION=docker
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -ldflags "-s -w -X main.Version=${VERSION}" -o /out/ccquota ./cmd/ccquota

# ── 2. the node ────────────────────────────────────────────────────────────
FROM debian:bookworm-slim
ARG CLAUDE_INSTALL=1
ARG CODEX_INSTALL=1
ARG NPM_REGISTRY=https://registry.npmmirror.com
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Asia/Shanghai
# What fleet-node-join.sh would apt-get on a bare box (deps are baked, so the
# join runs --no-deps and takes seconds), plus tini for PID 1, nodejs for the
# Codex CLI, and the editors/tools a worker session reaches for.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git tmux gh python3 zsh tini procps openssh-client \
      jq ripgrep less vim-tiny nodejs npm unzip locales tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -u 10002 -s /bin/zsh fleet \
 && mkdir -p /home/fleet/.local/bin /home/fleet/.config/claude-fleet /home/fleet/projects \
 && chown -R fleet:fleet /home/fleet
COPY --from=agent /out/ccquota /usr/local/bin/ccquota
# The fleet install the join clones FROM (--fleet-src): this checkout, so the
# node runs the same code the hub was built from. The join still clones it to
# ~/.claude/fleet the way it would from GitHub.
COPY --chown=fleet:fleet . /opt/claude-fleet
COPY --chown=fleet:fleet extras/spot-node/entrypoint.sh /usr/local/bin/spot-node-entrypoint
RUN chmod 755 /usr/local/bin/spot-node-entrypoint \
 && git -C /opt/claude-fleet config --global --add safe.directory /opt/claude-fleet || true

USER fleet
WORKDIR /home/fleet
ENV HOME=/home/fleet PATH=/home/fleet/.local/bin:/usr/local/bin:/usr/bin:/bin
# Claude Code and the Codex CLI, as the login that runs them. Both are
# switchable off for a build with no outside network (CI smoke-builds the
# image with CLAUDE_INSTALL=0 CODEX_INSTALL=0).
RUN if [ "$CLAUDE_INSTALL" = 1 ]; then curl -fsSL https://claude.ai/install.sh | bash; fi \
 && if [ "$CODEX_INSTALL" = 1 ]; then npm config set registry "$NPM_REGISTRY" && npm install -g --prefix /home/fleet/.local @openai/codex; fi \
 && git -C /opt/claude-fleet config --global --add safe.directory /opt/claude-fleet || true

# The hub's pod sets CCQUOTA_HUB_URL, FLEET_JOIN_CODE, FLEET_NODE_KIND and
# FLEET_SPOT_ID. Nothing listens: the agent dials out.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/spot-node-entrypoint"]
