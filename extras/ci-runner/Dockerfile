# fleet-ci-runner — the release train's Linux test runner in the Shenzhen cluster
# (issue #3864, EPIC #3863 C1): the fleet-ack ARC scale set's image.
#
# The shards ran on GitHub's ubuntu-latest until now, and the selftests were written
# against it: Ubuntu 24.04, tmux 3.4, Python 3.12, passwordless sudo, NO fzf (the
# fzf checks skip there). So the base is the official ARC runner image — Ubuntu
# 24.04 (noble), the actions runner as uid 1001 `runner` with passwordless sudo —
# and on top only what ubuntu-latest carries that a selftest reaches for (zsh,
# shellcheck, ssh-keygen, lsof, sqlite3, gawk — ubuntu-latest's awk —, …), Go (its
# module and build caches pre-filled for tokenledger/), Node 22, gh, buildctl (the train's `node image` job builds on the
# cluster's buildkitd from the same set) and the actions a shard uses. A first
# image on Debian 12 (tmux 3.3a, fzf 0.38, no sudo) went red on 19 selftests in a
# full run on fleet-ack — every one an environment difference, none a bug.
#
# The job gate (bin/fleet-ci-job-gate.sh, as on our Macs) is the runner's
# job-started hook: only this repo's master push / dispatch / schedule runs of the
# named workflows, never a pull request — the scale set sets CI_GATE_REPO and
# CI_GATE_WORKFLOWS.
#
# Built from the REPO ROOT by extras/ci-runner/build.sh, tagged by
# extras/ci-runner/tag.sh: the same text ⇒ the same tag ⇒ nothing rebuilt.
ARG RUNNER=ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807
ARG BUILDKIT=docker.io/moby/buildkit:v0.16.0
FROM ${BUILDKIT} AS buildkit
FROM ${RUNNER}

ARG UBUNTU_MIRROR=http://mirrors.aliyun.com/ubuntu
ARG GO_VERSION=1.25.14
ARG GO_SHA256=a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712
ARG GO_MIRROR=https://mirrors.aliyun.com/golang
ARG NODE_VERSION=v22.23.3
ARG NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
ARG NODE_MIRROR=https://registry.npmmirror.com/-/binary/node
ARG GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Ubuntu's own packages, from the in-region mirror — what ubuntu-latest has that
# the selftests use. fzf deliberately absent (as there).
RUN set -eux; \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do \
      [ ! -f "$f" ] || sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu#${UBUNTU_MIRROR}#g" "$f"; \
    done; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tmux zsh shellcheck openssh-client openssh-server lsof sqlite3 rsync \
      openssl procps psmisc iproute2 net-tools netcat-openbsd dnsutils bsdextrautils \
      util-linux file zip unzip zstd xz-utils bzip2 make gcc libc6-dev locales \
      python3 python3-cryptography python3-jwt python3-certifi python3-yaml \
      ca-certificates curl git jq gh time bc gawk; \
    locale-gen en_US.UTF-8 C.UTF-8 || true; \
    rm -rf /var/lib/apt/lists/*

# Go, by its published sha256.
RUN set -eux; \
    curl -fsSL --retry 3 -o /tmp/go.tgz "${GO_MIRROR}/go${GO_VERSION}.linux-amd64.tar.gz"; \
    echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tgz; rm /tmp/go.tgz; \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go; ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Node 22, by its published sha256.
RUN set -eux; \
    curl -fsSL --retry 3 -o /tmp/node.txz "${NODE_MIRROR}/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  /tmp/node.txz" | sha256sum -c -; \
    mkdir -p /opt/node22; tar -C /opt/node22 --strip-components=1 -xJf /tmp/node.txz; rm /tmp/node.txz; \
    for b in node npm npx; do ln -sf "/opt/node22/bin/$b" "/usr/local/bin/$b"; done; \
    node --version

# buildctl, the same version as the cluster's buildkitd (the `node image` job).
COPY --from=buildkit /usr/bin/buildctl /usr/local/bin/buildctl

# The job gate: root's, read-only to the runner.
COPY bin/fleet-ci-job-gate.sh /opt/fleet-ci/job-gate.sh
RUN chown -R root:root /opt/fleet-ci && chmod 0755 /opt/fleet-ci /opt/fleet-ci/job-gate.sh

ENV LANG=C.UTF-8 \
    GOPROXY=${GOPROXY} \
    GOTOOLCHAIN=local \
    GOFLAGS=-buildvcs=false \
    GOPATH=/home/runner/go \
    GOMODCACHE=/home/runner/go/pkg/mod \
    GOCACHE=/home/runner/.cache/go-build \
    ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=/home/runner/action-archive-cache \
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/fleet-ci/job-gate.sh

USER runner

# tokenledger's modules and a warm build cache, so a selftest that builds ccquota
# downloads nothing and compiles only what changed since this image (a cold build
# on one of these cores took a drill from 13 s to 53 s). The source is the build's
# only; the tag does not follow it — a stale cache is only a slower first build.
COPY --chown=runner:runner tokenledger/ /tmp/tl/
# One module a directory (hub · agent · shared · e2e, claude-fleet#4814), each
# built on its own as CI builds them (GOWORK=off).
RUN set -eux; for m in hub agent shared e2e; do ( cd /tmp/tl/$m; export GOWORK=off; go mod download; \
      go build ./... || true; go vet ./... >/dev/null 2>&1 || true ); done; \
    cd /; rm -rf /tmp/tl; du -sh "$GOCACHE" "$GOMODCACHE"

# The actions a shard names (the runner looks here by owner_repo/<sha>.tar.gz
# before downloading). Best effort: a missing one is downloaded per job, as before.
COPY --chown=runner:runner extras/ci-runner/actions.txt /tmp/actions.txt
RUN set -u; d=${ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE}; \
    while read -r repo sha; do \
      case "$repo" in ''|'#'*) continue ;; esac; \
      mkdir -p "$d/${repo%%/*}_${repo#*/}"; \
      curl -fsSL --retry 3 -m 120 -o "$d/${repo%%/*}_${repo#*/}/$sha.tar.gz" \
        "https://codeload.github.com/$repo/tar.gz/$sha" \
        || { echo "no archive for $repo@$sha"; rm -f "$d/${repo%%/*}_${repo#*/}/$sha.tar.gz"; }; \
    done < /tmp/actions.txt; rm -f /tmp/actions.txt; ls -R "$d" | head -20

# Which text this image was built from (tag.sh) — the shard compares it.
ARG TAG=untagged
LABEL org.opencontainers.image.version=${TAG}
ENV FLEET_CI_RUNNER_TAG=${TAG}
