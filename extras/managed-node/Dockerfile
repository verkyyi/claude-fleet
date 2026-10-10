# Context: the directory produced by prepare-image.sh (a verified hub release).
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    FLEET_NODE_ROOT=/opt/claude-fleet FLEET_NODE_STATE=/var/db/fleet-node \
    FLEET_NODE_LOG=/var/log/fleet-node FLEET_NODE_USERS=/home \
    FLEET_NODE_SERVICE=foreground FLEET_NODE_UPDATE_OWNER=image \
    FLEET_NODE_LOGIN=fleet FLEET_NODE_UID=10002 \
    PATH=/opt/claude-fleet/current/tools/bin:/opt/claude-fleet/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    ca-certificates curl git gh python3 zsh tini procps openssh-client openssh-server \
    jq ripgrep less sudo passwd libevent-2.1-7 libncursesw6 locales tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 499 fleetcred \
    && useradd --uid 499 --gid 499 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fleetcred
COPY runtime/ /opt/fleet-release/
COPY image-stage.py /usr/local/lib/fleet-image-stage.py
RUN python3 /usr/local/lib/fleet-image-stage.py /opt/fleet-release /opt/claude-fleet \
    && mkdir -p /run/sshd /var/db/fleet-node /var/db/fleet-cred /home
COPY release.pub /etc/fleet-release.pub
# No host privileges or Kubernetes API credentials are needed.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/python3", "-I", "/opt/claude-fleet/current/bin/fleet-node-linux.py", "foreground"]
