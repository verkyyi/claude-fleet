# Context: the directory produced by prepare-image.sh (a verified hub release).
# trixie: OpenSSH 10.0 — the entry port's sshd needs PerSourcePenalties (9.8+, #3092)
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    FLEET_NODE_ROOT=/var/db/fleet-node/runtime FLEET_NODE_STATE=/var/db/fleet-node \
    FLEET_NODE_SEED=/opt/claude-fleet/seed \
    FLEET_NODE_LOG=/var/log/fleet-node FLEET_NODE_USERS=/home \
    FLEET_NODE_SERVICE=foreground FLEET_NODE_UPDATE_OWNER=node \
    FLEET_NODE_LOGIN=fleet FLEET_NODE_UID=10002 \
    PATH=/var/db/fleet-node/runtime/current/tools/bin:/var/db/fleet-node/runtime/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    ca-certificates curl git gh python3 zsh tini procps openssh-client openssh-server \
    jq ripgrep less sudo passwd iptables xz-utils libevent-2.1-7t64 libncursesw6 locales tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 499 fleetcred \
    && useradd --uid 499 --gid 499 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fleetcred \
    && ssh-keygen -q -t ed25519 -N '' -f /tmp/hk \
    && mkdir -p /run/sshd && /usr/sbin/sshd -T -f /dev/null -o HostKey=/tmp/hk \
       | grep -Ei '^persourcepenalties ' | grep -Eqv ' no$' \
    && rm -f /tmp/hk /tmp/hk.pub
# The dev toolchain every login gets (#3348), fetched at BUILD time (outside CN)
# and checked by sha256. Every tar runs --no-same-owner: as root tar keeps the
# archive's owner, and node's uid 1001 on /usr/local/lib made the shared proxy's
# launcher `untrusted` — the pod never went Ready (#3421; asserted below). Node versions a repo pins (.nvmrc) come from fnm at run
# time through the CN mirrors /etc/fleet-devnet.env names (fleet-node-linux.py).
ARG NODE_VERSION=24.21.0 NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
ARG GO_VERSION=1.27.2 GO_SHA256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
ARG KUBECTL_VERSION=1.37.1 KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
ARG FNM_VERSION=1.39.0 FNM_SHA256=7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224
ARG ALIYUN_VERSION=3.5.1 ALIYUN_SHA256=3a9a45b9c7899228074135612d2b7ebbf32abb97826d825787cb454cd3011bdc
RUN set -eu; cd /tmp; get() { curl -fsSL --retry 3 -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    get node.txz "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" "$NODE_SHA256"; \
    tar --no-same-owner -xJf node.txz -C /usr/local --strip-components=1 --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'; \
    corepack enable --install-directory /usr/local/bin; \
    get go.tgz "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz" "$GO_SHA256"; \
    tar --no-same-owner -xzf go.tgz -C /usr/local; ln -sfn /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/; \
    get kubectl "https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/amd64/kubectl" "$KUBECTL_SHA256"; \
    install -m 755 kubectl /usr/local/bin/kubectl; \
    get fnm.zip "https://github.com/Schniz/fnm/releases/download/v$FNM_VERSION/fnm-linux.zip" "$FNM_SHA256"; \
    python3 -m zipfile -e fnm.zip fnm.d; install -m 755 fnm.d/fnm /usr/local/bin/fnm; \
    get aliyun.tgz "https://github.com/aliyun/aliyun-cli/releases/download/v$ALIYUN_VERSION/aliyun-cli-linux-$ALIYUN_VERSION-amd64.tgz" "$ALIYUN_SHA256"; \
    tar --no-same-owner -xzf aliyun.tgz -C /usr/local/bin aliyun; chmod 755 /usr/local/bin/aliyun; \
    rm -rf /tmp/*; node --version; go version; kubectl version --client; fnm --version; aliyun version; corepack --version
# Every shell reads the node's machine-wide dev settings (mirrors, the GitHub
# relay) — written at each start by fleet-node-linux.py, absent = nothing set;
# gh alone goes through the relay (git is told by /etc/gitconfig).
COPY devnet/ /usr/local/lib/fleet-devnet/
RUN install -m 755 /usr/local/lib/fleet-devnet/gh /usr/local/bin/gh \
    && install -m 644 /usr/local/lib/fleet-devnet/profile.sh /etc/profile.d/fleet-devnet.sh \
    && printf '\n# fleet: machine-wide dev settings (#3348)\n[ -r /etc/profile.d/fleet-devnet.sh ] && . /etc/profile.d/fleet-devnet.sh\n' \
       | tee -a /etc/zsh/zshenv >> /etc/bash.bashrc
COPY runtime/ /opt/fleet-release/
COPY image-stage.py /usr/local/lib/fleet-image-stage.py
# The image's release is only a SEED (#3212): the first boot copies it onto the
# persistent volume (FLEET_NODE_ROOT), and from then on the machine updater moves
# `current` there as on a Mac — a container restart never goes back to it. The
# tools on PATH follow the disk's `current`, never the image's (#3030 item 1).
RUN python3 /usr/local/lib/fleet-image-stage.py stage /opt/fleet-release /opt/claude-fleet/seed \
    && mkdir -p /run/sshd /var/db/fleet-node /var/db/fleet-cred /home \
    && for t in tmux claude codex; do ln -sfn /var/db/fleet-node/runtime/current/tools/bin/$t /usr/local/bin/$t; done \
    && ln -sfn /var/db/fleet-node/runtime/current/bin/ccquota /usr/local/bin/ccquota
COPY release.pub /etc/fleet-release.pub
# Root runs only root-owned code from a root-owned path (fleet-node-supervisor.py
# trusted()); credsep's LIB is /usr/local/lib/claude-fleet/credsep (#3421).
RUN bad=$(find /usr/local \( ! -user root -o ! -group root \) -print | head -5); \
    [ -z "$bad" ] || { echo "image: /usr/local is not root's: $bad" >&2; exit 1; }; \
    for d in / /usr /usr/local /usr/local/lib; do \
      [ "$(stat -c '%u %g' "$d")" = '0 0' ] && [ -z "$(find "$d" -maxdepth 0 -perm /022)" ] \
        || { echo "image: $d is not root's alone" >&2; exit 1; }; done
# No host privileges or Kubernetes API credentials are needed. iptables is for the
# egress-guard init container only (#3281); the fleet container has no NET_ADMIN.
# FLEET_NODE_UPDATE_OWNER=image turns the self-update off (the old image-owned way).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/python3", "-I", "/usr/local/lib/fleet-image-stage.py", "boot"]
