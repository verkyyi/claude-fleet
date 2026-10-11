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
    jq ripgrep less sudo passwd iptables libevent-2.1-7t64 libncursesw6 locales tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 499 fleetcred \
    && useradd --uid 499 --gid 499 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fleetcred \
    && ssh-keygen -q -t ed25519 -N '' -f /tmp/hk \
    && mkdir -p /run/sshd && /usr/sbin/sshd -T -f /dev/null -o HostKey=/tmp/hk \
       | grep -Ei '^persourcepenalties ' | grep -Eqv ' no$' \
    && rm -f /tmp/hk /tmp/hk.pub
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
# No host privileges or Kubernetes API credentials are needed. iptables is for the
# egress-guard init container only (#3281); the fleet container has no NET_ADMIN.
# FLEET_NODE_UPDATE_OWNER=image turns the self-update off (the old image-owned way).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/python3", "-I", "/usr/local/lib/fleet-image-stage.py", "boot"]
