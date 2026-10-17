# Explicit TEST-ONLY overlay. The production Dockerfile and off_template are
# unchanged. Build from a verified managed-node image digest, using repo root
# as the context; the live owner prepares/publishes it through normal tooling.
ARG C9_BASE
FROM ${C9_BASE}
ARG C9_SOURCE_SHA
USER root
RUN apt-get update -qq && apt-get install -y --no-install-recommends strace iproute2 \
    && rm -rf /var/lib/apt/lists/*
COPY bin/nogh_live_contract.py bin/nogh_live_observer.py bin/nogh_live_runtime.py \
     bin/nogh_live_gateway.py bin/nogh_live_probe.py bin/nogh_live_http.py bin/nogh_live_identity.py \
     bin/nogh_live_evidence.py /usr/local/lib/fleet-c9/
COPY extras/managed-node/render.py /usr/local/lib/fleet-c9/managed-render.py
COPY deploy/k8s/egress/base/fleet-egress.py /usr/local/lib/fleet-c9/fleet-egress.py
RUN C9_SOURCE_SHA="$C9_SOURCE_SHA" python3 -c 'import hashlib,json,os,pathlib,re; s=os.environ["C9_SOURCE_SHA"]; assert re.fullmatch("[a-f0-9]{40}",s); p=pathlib.Path("/usr/local/lib/fleet-c9/c9-build.json"); p.write_text(json.dumps(dict(source_sha=s,strace_sha256=hashlib.sha256(pathlib.Path("/usr/bin/strace").read_bytes()).hexdigest())))' \
    && printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -I -c '\''import sys; sys.path.insert(0,"/usr/local/lib/fleet-c9"); from nogh_live_runtime import main; sys.exit(main())'\'' guard "$@"' > /usr/local/bin/fleet-c9-guard \
    && printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -I -c '\''import sys; sys.path.insert(0,"/usr/local/lib/fleet-c9"); from nogh_live_runtime import main; sys.exit(main())'\'' supervise "$@"' > /usr/local/bin/fleet-c9-supervise \
    && chmod 755 /usr/local/bin/fleet-c9-guard /usr/local/bin/fleet-c9-supervise \
    && mkdir -p /run/fleet-c9 /opt/fleet-c9 /run/c9-credentials
# The workload logins (uid/gid >= 10000, runtime.workload_identity) and a usable
# toolchain (#4630). The base image's ccquota/claude/tmux links name the disk
# runtime that only `boot` fills; boot never runs here, so they point at the
# image's own staged seed. The logins must equal the plan's endpoint logins.
ARG C9_HUB_LOGIN=c9-hub
ARG C9_NODE_A_LOGIN=c9-node-a
ARG C9_NODE_B_LOGIN=c9-node-b
RUN set -eu; seed=/opt/claude-fleet/seed/current; \
    for t in tmux claude; do test -x "$seed/tools/bin/$t"; ln -sfn "$seed/tools/bin/$t" /usr/local/bin/$t; done; \
    if [ -x "$seed/tools/bin/codex" ]; then ln -sfn "$seed/tools/bin/codex" /usr/local/bin/codex; \
    else rm -f /usr/local/bin/codex; fi; \
    test -x "$seed/bin/ccquota"; ln -sfn "$seed/bin/ccquota" /usr/local/bin/ccquota; \
    id=10001; for login in "$C9_HUB_LOGIN" "$C9_NODE_A_LOGIN" "$C9_NODE_B_LOGIN"; do \
      printf '%s\n' "$login" | grep -Eqx '[a-z][a-z0-9-]{0,31}'; \
      groupadd --gid "$id" "$login"; \
      useradd --uid "$id" --gid "$id" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$login"; \
      id=$((id + 1)); done
# A direct run has no production default and does not start a node.
ENTRYPOINT ["/usr/bin/false"]
