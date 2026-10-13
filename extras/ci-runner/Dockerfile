# fleet-ci-runner — the release train's Linux test runner in the Shenzhen cluster
# (issue #3864, EPIC #3863 C1): the fleet-ack ARC scale set's image.
#
# The base is the cluster's own ARC runner image (Debian 12, the actions runner as
# uid 1001 `runner`, bash 5 / python3 / jq / gh / node / git / buildctl — the last
# keeps the train's `node image` job working on the same set). On top: what the
# selftests reach for on GitHub's ubuntu-latest — tmux 3.5 (backports), zsh, fzf, shellcheck,
# ssh-keygen, lsof, sqlite3, … — Go (its module cache pre-filled for
# tokenledger/), Node 22, and the actions a shard uses, so a job neither installs
# a tool nor crosses the Pacific for one.
#
# Built from the REPO ROOT (it reads tokenledger/go.{mod,sum}) by
# extras/ci-runner/build.sh, tagged by extras/ci-runner/tag.sh: the same text ⇒
# the same tag ⇒ nothing rebuilt.
# BASE: the cluster's ARC runner image (build.sh's second argument, the repo
# variable CI_RUNNER_BASE) — e.g. registry.example.com/acme/arc-runner:slimbase-…
ARG BASE
FROM ${BASE}

ARG DEBIAN_MIRROR=http://mirrors.aliyun.com/debian
ARG GO_VERSION=1.25.14
ARG GO_SHA256=a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712
ARG GO_MIRROR=https://mirrors.aliyun.com/golang
ARG NODE_VERSION=v22.23.3
ARG NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
ARG NODE_MIRROR=https://registry.npmmirror.com/-/binary/node
ARG GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Debian's own packages, from the in-region mirror.
RUN set -eux; \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
      [ ! -f "$f" ] || sed -i -E "s#https?://(deb|security)\.debian\.org/debian(-security)?#${DEBIAN_MIRROR}\2#g" "$f"; \
    done; \
    # tmux from bookworm-backports (3.5a, as on the Macs): bookworm's 3.3a does not
    # open a mouse menu the sidebar selftest drives (#3864)
    echo "deb ${DEBIAN_MIRROR} bookworm-backports main" > /etc/apt/sources.list.d/backports.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm-backports tmux; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      zsh fzf shellcheck openssh-client openssh-server lsof sqlite3 rsync \
      openssl procps psmisc iproute2 net-tools netcat-openbsd dnsutils bsdextrautils \
      util-linux file zip unzip zstd xz-utils bzip2 make gcc libc6-dev locales \
      python3-cryptography python3-jwt python3-certifi python3-yaml \
      ca-certificates curl git jq; \
    sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(C.UTF-8\)/\1/' /etc/locale.gen; locale-gen; \
    rm -rf /var/lib/apt/lists/*

# Go, by its published sha256.
RUN set -eux; \
    curl -fsSL --retry 3 -o /tmp/go.tgz "${GO_MIRROR}/go${GO_VERSION}.linux-amd64.tar.gz"; \
    echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tgz; rm /tmp/go.tgz; \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go; ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Node 22, by its published sha256 (the base's node 20 stays under it on PATH).
RUN set -eux; \
    curl -fsSL --retry 3 -o /tmp/node.txz "${NODE_MIRROR}/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  /tmp/node.txz" | sha256sum -c -; \
    mkdir -p /opt/node22; tar -C /opt/node22 --strip-components=1 -xJf /tmp/node.txz; rm /tmp/node.txz; \
    for b in node npm npx; do ln -sf "/opt/node22/bin/$b" "/usr/local/bin/$b"; done; \
    node --version

ENV LANG=C.UTF-8 \
    GOPROXY=${GOPROXY} \
    GOTOOLCHAIN=local \
    GOFLAGS=-buildvcs=false \
    GOPATH=/home/runner/go \
    GOMODCACHE=/home/runner/go/pkg/mod \
    GOCACHE=/home/runner/.cache/go-build \
    ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=/home/runner/action-archive-cache

USER runner

# tokenledger's modules, so a selftest that builds ccquota downloads nothing.
COPY --chown=runner:runner tokenledger/go.mod tokenledger/go.sum /tmp/tl/
RUN set -eux; cd /tmp/tl; go mod download; rm -rf /tmp/tl

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
