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
     bin/nogh_live_gateway.py bin/nogh_live_probe.py bin/nogh_live_http.py bin/nogh_live_identity.py /usr/local/lib/fleet-c9/
COPY extras/managed-node/render.py /usr/local/lib/fleet-c9/managed-render.py
COPY deploy/k8s/egress/base/fleet-egress.py /usr/local/lib/fleet-c9/fleet-egress.py
RUN C9_SOURCE_SHA="$C9_SOURCE_SHA" python3 -c 'import hashlib,json,os,pathlib,re; s=os.environ["C9_SOURCE_SHA"]; assert re.fullmatch("[a-f0-9]{40}",s); p=pathlib.Path("/usr/local/lib/fleet-c9/c9-build.json"); p.write_text(json.dumps(dict(source_sha=s,strace_sha256=hashlib.sha256(pathlib.Path("/usr/bin/strace").read_bytes()).hexdigest())))' \
    && printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -I -c '\''import sys; sys.path.insert(0,"/usr/local/lib/fleet-c9"); from nogh_live_runtime import main; sys.exit(main())'\'' guard "$@"' > /usr/local/bin/fleet-c9-guard \
    && printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -I -c '\''import sys; sys.path.insert(0,"/usr/local/lib/fleet-c9"); from nogh_live_runtime import main; sys.exit(main())'\'' supervise "$@"' > /usr/local/bin/fleet-c9-supervise \
    && chmod 755 /usr/local/bin/fleet-c9-guard /usr/local/bin/fleet-c9-supervise \
    && mkdir -p /run/fleet-c9 /opt/fleet-c9 /run/c9-credentials
# A direct run has no production default and does not start a node.
ENTRYPOINT ["/usr/bin/false"]
