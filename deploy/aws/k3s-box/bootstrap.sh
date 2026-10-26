#!/usr/bin/env bash
# The hub's core on ONE Ubuntu 24.04 EC2 box (task PNWW): k3s, cert-manager,
# the ECR pull secret, the Secrets, deploy/k8s/overlays/aws-k3s, and the
# provisioner's template. Idempotent: every step looks before it acts, so the
# same command installs, repairs and upgrades (a new HUB_IMAGE = a rolling
# release of the hub). Runs as root, on the box. deploy/aws/README.md.
#
#   bootstrap.sh            everything
#   bootstrap.sh apply      the overlay + template only (k3s and cert-manager already up)
#   bootstrap.sh render     print the render it would apply, change nothing
#
# Settings come from the environment, else $FLEET_CORE_CONF
# (/etc/fleet-core/deploy.env, written by user-data.yaml):
#   HUB_IMAGE            <acct>.dkr.ecr.<region>.amazonaws.com/fleet/ccquota:<tag>    (required)
#   MANAGED_NODE_IMAGE   <acct>.dkr.ecr.<region>.amazonaws.com/fleet/managed-node@sha256:…
#                        (required for user pods; unset = the hub alone, WORKERS=0)
#   ACME_EMAIL           Let's Encrypt's contact                                      (required)
#   HUB_HOST             core.tokenman.io
#   PUBLIC_ORIGIN        the hub's public URL (CCQUOTA_*PUBLIC_URL), default https://$HUB_HOST;
#                        another name's when the hub took over another hub's address
#   EDGE_TRUSTED_IPS     CIDRs whose X-Forwarded-* traefik keeps (a reverse proxy in
#                        front, e.g. the Shenzhen ingress' egress address as a /32);
#                        unset = traefik trusts nobody's
#   EXTRA_HOSTS          more names served by the same hub, space-separated, each in
#                        the certificate extra-tls (e.g. HUB_HOST=tokenman.io
#                        EXTRA_HOSTS="www.tokenman.io core.tokenman.io": the apex
#                        is the address, the old one keeps answering nodes)
#   AWS_REGION           us-west-2
#   STORAGE_CLASS        local-path (k3s') · gp3 (EBS CSI, needs the instance role — README)
#   LETSENCRYPT_SERVER   prod · staging
#   K3S_CHANNEL          stable          INSTALL_K3S_VERSION pins one instead
#   CERT_MANAGER_VERSION v1.16.3
#   CLUSTER_NAME         aws-k3s (the name fleet-ops and the hub's fleet.clusters say)
#   USER_POD_REQUESTS    cpu=500m,memory=3Gi        USER_POD_LIMITS  disk=20Gi
#   SECRETS_DIR          /etc/fleet-core/secrets (0700; generated keys land here — back it up)
#   DB_URL_SSM_PARAM     an SSM SecureString holding the Postgres URL, read with the
#                        instance role when SECRETS_DIR/db-url is missing (e.g. /fleet-core/db-url)
#   SITE_ENV_SSM_PARAM   likewise for SECRETS_DIR/site.env (optional)
set -euo pipefail

FLEET_CORE_CONF=${FLEET_CORE_CONF:-/etc/fleet-core/deploy.env}
# shellcheck disable=SC1090
[ -f "$FLEET_CORE_CONF" ] && . "$FLEET_CORE_CONF"

here=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$here/../../.." && pwd)}
OVERLAY=$REPO_DIR/deploy/k8s/overlays/aws-k3s
HUB_HOST=${HUB_HOST:-core.tokenman.io}
EXTRA_HOSTS=${EXTRA_HOSTS:-}
EDGE_TRUSTED_IPS=${EDGE_TRUSTED_IPS:-}
AWS_REGION=${AWS_REGION:-us-west-2}
STORAGE_CLASS=${STORAGE_CLASS:-local-path}
LETSENCRYPT_SERVER=${LETSENCRYPT_SERVER:-prod}
K3S_CHANNEL=${K3S_CHANNEL:-stable}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.16.3}
CLUSTER_NAME=${CLUSTER_NAME:-aws-k3s}
USER_POD_REQUESTS=${USER_POD_REQUESTS:-cpu=500m,memory=3Gi}
USER_POD_LIMITS=${USER_POD_LIMITS:-disk=20Gi}
SECRETS_DIR=${SECRETS_DIR:-/etc/fleet-core/secrets}
MANAGED_NODE_IMAGE=${MANAGED_NODE_IMAGE:-}
WORKERS=${WORKERS:-$([ -n "$MANAGED_NODE_IMAGE" ] && echo 1 || echo 0)}

say() { printf '[fleet-core] %s\n' "$*" >&2; }
die() { say "ERROR: $*"; exit 1; }
# k3s' own kubectl on the box; a plain kubectl elsewhere (`render` on a laptop)
k() { if command -v k3s >/dev/null 2>&1; then k3s kubectl "$@"; else kubectl "$@"; fi; }

need_settings() {
  [ -n "${HUB_IMAGE:-}" ] || die "HUB_IMAGE is not set (the hub image in ECR)"
  [ -n "${ACME_EMAIL:-}" ] || die "ACME_EMAIL is not set (Let's Encrypt's contact)"
  [ "$WORKERS" = 0 ] || [ -n "$MANAGED_NODE_IMAGE" ] || die "WORKERS=1 needs MANAGED_NODE_IMAGE"
  case $MANAGED_NODE_IMAGE in ''|*@sha256:*) ;; *) die "MANAGED_NODE_IMAGE must be pinned by digest (…@sha256:…)" ;; esac
  case $STORAGE_CLASS in local-path|gp3) ;; *) die "STORAGE_CLASS is local-path or gp3, not $STORAGE_CLASS" ;; esac
  [ -f "$OVERLAY/kustomization.yaml" ] || die "no overlay at $OVERLAY (REPO_DIR=$REPO_DIR)"
}

ecr_registry() { printf '%s' "${HUB_IMAGE%%/*}"; }

# ── 1. k3s ──────────────────────────────────────────────────────────────────
install_k3s() {
  if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
    say "k3s: already running ($(k3s --version | head -1))"
  else
    say "k3s: installing (${INSTALL_K3S_VERSION:-channel $K3S_CHANNEL})"
    # traefik, servicelb, local-path, metrics-server and the network-policy
    # controller are k3s' defaults and all used here
    curl -sfL https://get.k3s.io \
      | INSTALL_K3S_CHANNEL="$K3S_CHANNEL" INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-}" \
        sh -s - server --write-kubeconfig-mode 0600
  fi
  for _ in $(seq 1 60); do
    if k get nodes 2>/dev/null | grep -q ' Ready '; then return 0; fi
    sleep 5
  done
  die "k3s: the node never became Ready"
}

# ── 2. the ECR pull secret (refreshed every 6 h: an ECR token lives 12 h) ────
install_awscli() {
  command -v aws >/dev/null 2>&1 && return 0
  say "awscli: installing"
  apt-get update -qq && apt-get install -y -qq unzip curl >/dev/null
  local arch tmp
  arch=$(uname -m)
  tmp=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip" -o "$tmp/aws.zip"
  unzip -q "$tmp/aws.zip" -d "$tmp"
  "$tmp/aws/install" --update >/dev/null
  rm -rf "$tmp"
}

install_ecr_refresh() {
  install -d -m 0755 /usr/local/sbin
  cat > /usr/local/sbin/fleet-ecr-pull.sh <<EOF
#!/usr/bin/env bash
# Written by deploy/aws/k3s-box/bootstrap.sh: Secret ecr-pull in fleet-hub and
# fleet-workers from the instance role's ECR token (never an argv, never a log).
set -euo pipefail
umask 077
d=\$(mktemp -d); trap 'rm -rf "\$d"' EXIT
tok=\$(aws ecr get-login-password --region "$AWS_REGION")
auth=\$(printf 'AWS:%s' "\$tok" | base64 -w0)
printf '{"auths":{"%s":{"auth":"%s"}}}' "$(ecr_registry)" "\$auth" > "\$d/config.json"
for ns in fleet-hub fleet-workers; do
  k3s kubectl get ns "\$ns" >/dev/null 2>&1 || continue
  k3s kubectl -n "\$ns" create secret generic ecr-pull --type=kubernetes.io/dockerconfigjson \\
    --from-file=.dockerconfigjson="\$d/config.json" --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
done
EOF
  chmod 0700 /usr/local/sbin/fleet-ecr-pull.sh
  cat > /etc/systemd/system/fleet-ecr-pull.service <<'EOF'
[Unit]
Description=fleet: refresh the ECR pull secret
After=k3s.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fleet-ecr-pull.sh
EOF
  cat > /etc/systemd/system/fleet-ecr-pull.timer <<'EOF'
[Unit]
Description=fleet: refresh the ECR pull secret every 6 hours
[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now fleet-ecr-pull.timer >/dev/null
}

# ── 3. cert-manager (and the EBS CSI driver, for gp3) through k3s' helm controller
install_charts() {
  say "cert-manager: $CERT_MANAGER_VERSION"
  k apply -f - >/dev/null <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata: {name: cert-manager, namespace: kube-system}
spec:
  repo: https://charts.jetstack.io
  chart: cert-manager
  version: $CERT_MANAGER_VERSION
  targetNamespace: cert-manager
  createNamespace: true
  valuesContent: |-
    crds:
      enabled: true
EOF
  if [ "$STORAGE_CLASS" = gp3 ]; then
    say "aws-ebs-csi-driver + StorageClass gp3"
    k apply -f - >/dev/null <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata: {name: aws-ebs-csi-driver, namespace: kube-system}
spec:
  repo: https://kubernetes-sigs.github.io/aws-ebs-csi-driver
  chart: aws-ebs-csi-driver
  targetNamespace: kube-system
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: gp3}
provisioner: ebs.csi.aws.com
parameters: {type: gp3, encrypted: "true"}
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
  fi
  for _ in $(seq 1 60); do
    if k get crd clusterissuers.cert-manager.io >/dev/null 2>&1 \
      && k -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5s >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "cert-manager never came up (k -n kube-system logs job/helm-install-cert-manager)"
}

# ── 4. the Secrets: generated once into SECRETS_DIR, applied every run ────────
gen() { # gen <file> <command…>: make the file once, 0600
  local f=$SECRETS_DIR/$1; shift
  [ -s "$f" ] && return 0
  say "secret: generating $(basename "$f")"
  # no trailing newline: a Secret made --from-file keeps it, and the hub would
  # read it as part of the token (every Bearer then 401s)
  ( umask 077; v=$("$@") && printf '%s' "$v" > "$f.tmp" ) && mv "$f.tmp" "$f"
}

from_ssm() { # from_ssm <file> <param>: the file once, from SSM Parameter Store
  local f=$SECRETS_DIR/$1
  if [ -s "$f" ] || [ -z "$2" ]; then return 0; fi
  say "secret: $1 from SSM $2"
  ( umask 077; v=$(aws ssm get-parameter --region "$AWS_REGION" --with-decryption --name "$2" \
      --query Parameter.Value --output text) && printf '%s' "$v" > "$f.tmp" ) && mv "$f.tmp" "$f"
}

ensure_secrets() {
  install -d -m 0700 "$SECRETS_DIR"
  # an earlier bootstrap wrote these with a trailing newline: trim it in place
  local f
  for f in viewer-token replica-token credproxy-token session-cred-key cred-key db-url; do
    if [ -s "$SECRETS_DIR/$f" ] && [ "$(tail -c1 "$SECRETS_DIR/$f" | od -An -c | tr -d ' ')" = '\n' ]; then
      ( umask 077; v=$(cat "$SECRETS_DIR/$f") && printf '%s' "$v" > "$SECRETS_DIR/$f.tmp" ) && mv "$SECRETS_DIR/$f.tmp" "$SECRETS_DIR/$f"
    fi
  done
  from_ssm db-url "${DB_URL_SSM_PARAM:-}"
  from_ssm site.env "${SITE_ENV_SSM_PARAM:-}"
  [ -s "$SECRETS_DIR/db-url" ] || die "no $SECRETS_DIR/db-url — the RDS Postgres URL (README «Secrets»)"
  gen viewer-token openssl rand -hex 24
  gen replica-token openssl rand -hex 24
  gen credproxy-token openssl rand -hex 24
  gen session-cred-key openssl rand -base64 32
  gen cred-key openssl rand -base64 32
  gen account-key openssl genpkey -algorithm ed25519
  local t
  for t in ssh-ca ssh-host-ca; do
    if [ ! -s "$SECRETS_DIR/$t" ]; then
      say "secret: generating $t"
      ssh-keygen -q -t ed25519 -N '' -C "fleet-$t" -f "$SECRETS_DIR/$t" && chmod 0600 "$SECRETS_DIR/$t"
    fi
  done
  k apply -f "$OVERLAY/namespaces.yaml" >/dev/null
  sec() { # sec <ns> <name> <args…>
    local ns=$1 name=$2; shift 2
    k -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | k apply -f - >/dev/null
  }
  local S=$SECRETS_DIR
  sec fleet-hub ccquota --from-file=viewer-token="$S/viewer-token"
  sec fleet-hub ccquota-db --from-file=db-url="$S/db-url" --from-file=replica-token="$S/replica-token"
  sec fleet-hub ccquota-ssh-ca --from-file=ca="$S/ssh-ca"
  sec fleet-hub ccquota-ssh-host-ca --from-file=ca="$S/ssh-host-ca"
  sec fleet-hub ccquota-fleet-cred-key --from-file=key="$S/cred-key"
  sec fleet-hub ccquota-account-key --from-file=key="$S/account-key"
  # every other CCQUOTA_* the hub reads: site.env (KEY=VALUE lines, yours) plus
  # the two the box generated
  local env=$S/.site-env.rendered
  ( umask 077
    [ -f "$S/site.env" ] && grep -E '^[A-Z][A-Z0-9_]*=' "$S/site.env"
    printf 'CCQUOTA_FLEET_CREDPROXY_TOKEN=%s\n' "$(cat "$S/credproxy-token")"
    printf 'CCQUOTA_FLEET_SESSION_CRED_KEY=%s\n' "$(cat "$S/session-cred-key")"
  ) > "$env"
  sec fleet-hub ccquota-site-env --from-env-file="$env"
  rm -f "$env"
  [ -f "$S/site.conf" ] && k -n fleet-hub create configmap ccquota-site --from-env-file="$S/site.conf" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  sec fleet-workers fleet-credproxy --from-file=credproxy-token="$S/credproxy-token"
  # optional, a hub that took over another one's state (task PNWW): its debug
  # key, its feedback GitHub App and its price table — each only when present
  [ -s "$S/debug-key" ] && sec fleet-hub ccquota-debug-key --from-file=debug-key="$S/debug-key"
  if [ -d "$S/feedback-github" ]; then
    sec fleet-hub ccquota-feedback-github --from-file="$S/feedback-github"
  fi
  if [ -s "$S/pricing.json" ]; then
    k -n fleet-hub create configmap ccquota-pricing --from-file=pricing.json="$S/pricing.json" \
      --dry-run=client -o yaml | k apply -f - >/dev/null
  fi
  return 0
}

# ── 5. the overlay ──────────────────────────────────────────────────────────
render() {
  local issuer=https://acme-v02.api.letsencrypt.org/directory
  [ "$LETSENCRYPT_SERVER" = staging ] && issuer=https://acme-staging-v02.api.letsencrypt.org/directory
  local tree
  tree=$(mktemp -d)
  # the overlay reaches ../../base and friends: copy deploy/k8s whole
  cp -R "$REPO_DIR/deploy/k8s" "$tree/k8s"
  if [ "$WORKERS" = 0 ]; then
    sed -i.bak '/^  - workers$/d' "$tree/k8s/overlays/aws-k3s/kustomization.yaml"
  fi
  k kustomize "$tree/k8s/overlays/aws-k3s" \
    | sed -e "s#ecr.invalid/fleet/ccquota:set-by-deploy#$HUB_IMAGE#g" \
          -e "s#ecr.invalid/fleet/managed-node:set-by-deploy#${MANAGED_NODE_IMAGE:-ecr.invalid/fleet/managed-node:set-by-deploy}#g" \
          -e "s#acme@example.invalid#$ACME_EMAIL#g" \
          -e "s#https://acme-v02.api.letsencrypt.org/directory#$issuer#g" \
          -e "s#https://core\.tokenman\.io#${PUBLIC_ORIGIN:-https://$HUB_HOST}#g" \
          -e "s#core\.tokenman\.io#$HUB_HOST#g" \
    | edge_trust
  rm -rf "$tree"
  extra_ingress
  credproxy_ingress
}

# EDGE_TRUSTED_IPS: traefik keeps those sources' X-Forwarded-* (the line is
# rendered as a placeholder and dropped when unset).
edge_trust() {
  if [ -n "$EDGE_TRUSTED_IPS" ]; then
    sed -e "s#__EDGE_TRUSTED_IPS__#$(echo $EDGE_TRUSTED_IPS | tr ' ' ',')#g"
  else
    grep -v '__EDGE_TRUSTED_IPS__'
  fi
}

# The cluster credential proxy at /v1/proxy/ on every name the hub answers
# (the hub's own Ingress sends the rest of the path to the hub).
credproxy_ingress() {
  local h
  [ "$WORKERS" = 0 ] && return 0
  printf -- '---\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n'
  printf '  name: fleet-credproxy\n  namespace: fleet-workers\n  annotations:\n'
  printf '    traefik.ingress.kubernetes.io/router.middlewares: fleet-hub-redirect-https@kubernetescrd\n'
  printf 'spec:\n  ingressClassName: traefik\n  tls:\n    - hosts:\n'
  for h in $HUB_HOST $EXTRA_HOSTS; do printf '        - %s\n' "$h"; done
  printf '  rules:\n'
  for h in $HUB_HOST $EXTRA_HOSTS; do
    printf '    - host: %s\n      http:\n        paths:\n          - path: /v1/proxy/\n            pathType: Prefix\n' "$h"
    printf '            backend:\n              service:\n                name: fleet-credproxy\n                port:\n                  number: 80\n'
  done
}

# EXTRA_HOSTS: one more Ingress to the same hub, its own certificate.
extra_ingress() {
  local h
  [ -n "$EXTRA_HOSTS" ] || return 0
  printf -- '---\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n'
  printf '  name: ccquota-hub-extra\n  namespace: fleet-hub\n  annotations:\n'
  printf '    cert-manager.io/cluster-issuer: letsencrypt\n'
  printf '    traefik.ingress.kubernetes.io/router.middlewares: fleet-hub-redirect-https@kubernetescrd\n'
  printf 'spec:\n  ingressClassName: traefik\n  tls:\n    - secretName: extra-tls\n      hosts:\n'
  for h in $EXTRA_HOSTS; do printf '        - %s\n' "$h"; done
  printf '  rules:\n'
  for h in $EXTRA_HOSTS; do
    printf '    - host: %s\n      http:\n        paths:\n          - path: /\n            pathType: Prefix\n' "$h"
    printf '            backend:\n              service:\n                name: ccquota-hub\n                port:\n                  number: 80\n'
  done
}

apply_overlay() {
  local out
  out=$(mktemp)
  render > "$out"
  if grep -q 'ecr.invalid' "$out"; then die "a placeholder image is left in the render"; fi
  # the pull secret before the pods that need it
  /usr/local/sbin/fleet-ecr-pull.sh || say "WARN: the ECR pull secret could not be refreshed (instance role?)"
  say "apply: deploy/k8s/overlays/aws-k3s → $HUB_IMAGE"
  k apply -f "$out"
  rm -f "$out"
  k -n fleet-hub rollout status deploy/ccquota-hub --timeout=10m
}

# ── 6. the provisioner's template (README «User pods») ─────────────────────
kv_json() { # "cpu=500m,memory=3Gi" -> {"cpu": "500m", "memory": "3Gi"}
  python3 -c 'import json,sys; print(json.dumps(dict(p.split("=",1) for p in sys.argv[1].split(",") if p)))' "$1"
}

apply_template() {
  [ "$WORKERS" = 0 ] && { say "workers: off (no MANAGED_NODE_IMAGE) — the hub alone"; return 0; }
  local hub_ip cp_ip tmp
  hub_ip=$(k -n fleet-hub get svc ccquota-hub -o jsonpath='{.spec.clusterIP}')
  cp_ip=$(k -n fleet-workers get svc fleet-credproxy -o jsonpath='{.spec.clusterIP}')
  tmp=$(mktemp -d)
  # the account key's public half, from the hub itself (its Service, from the node)
  curl -fsS "http://$hub_ip/v1/fleet/account-key" > "$tmp/account.pub" \
    || die "the hub did not hand out its account key (is ccquota-account-key mounted?)"
  # k3s' defaults: pods 10.42.0.0/16, services 10.43.0.0/16, DNS 10.43.0.10;  # oss-ok: k3s documented default ranges
  # EC2's metadata address. The guard lets the two in-cluster roads through.
  python3 - "$tmp/template.json" <<EOF
import json, sys
json.dump({"cluster": "$CLUSTER_NAME", "namespace": "fleet-workers",
  "user_pod": {"image": "$MANAGED_NODE_IMAGE", "hub": "https://$HUB_HOST",
    "storage_class": "$STORAGE_CLASS",
    "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local",
    "hub_internal": "http://ccquota-hub.fleet-hub.svc.cluster.local",
    "egress": {"dns": "10.43.0.10", "metadata": "169.254.169.254/32",  # oss-ok: k3s default
               "pod_cidr": "10.42.0.0/16", "service_cidr": "10.43.0.0/16",  # oss-ok: k3s default
               "allow": ["$cp_ip:80", "$hub_ip:80"]},
    "pull_secrets": ["ecr-pull"],
    "requests": $(kv_json "$USER_POD_REQUESTS"),
    "limits": "$USER_POD_LIMITS"}}, open(sys.argv[1], "w"), indent=1)
EOF
  k -n fleet-workers create configmap fleet-provisioner --from-file="$tmp/template.json" \
    --from-file="$tmp/account.pub" --dry-run=client -o yaml | k apply -f - >/dev/null
  rm -rf "$tmp"
  k -n fleet-workers rollout restart deploy/fleet-provisioner >/dev/null
  k -n fleet-workers rollout status deploy/fleet-provisioner --timeout=5m
}

main() {
  case ${1:-all} in
    render) need_settings; render ;;
    apply) need_settings; ensure_secrets; apply_overlay; apply_template ;;
    all)
      need_settings
      install_k3s
      install_awscli
      install_ecr_refresh
      install_charts
      ensure_secrets
      apply_overlay
      apply_template
      say "done: https://$HUB_HOST (the certificate may take a minute: k -n fleet-hub get certificate)"
      ;;
    *) die "usage: bootstrap.sh [all|apply|render]" ;;
  esac
}
main "$@"
