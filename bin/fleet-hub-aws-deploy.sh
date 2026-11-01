#!/bin/bash
# fleet-hub-aws-deploy.sh — the hub's release onto the AWS k3s box, from a CI
# runner, through AWS SSM (task PNWW; hub-deploy.yml's `deploy-aws` job, read
# when repo variable FLEET_HUB_TARGET=aws-k3s).
#
#   fleet-hub-aws-deploy.sh deploy <sha> <image>   on the box: fetch <sha> into its
#        checkout, check it out detached, set HUB_IMAGE=<image> in deploy.env,
#        `bootstrap.sh apply` (it waits for the rollout). A failed apply puts the
#        previous deploy.env and checkout back and applies them again — then exit 1.
#   fleet-hub-aws-deploy.sh rollback               on the box: the deploy.env and
#        checkout the last `deploy` replaced, applied again (the job's road when
#        the health check fails after a deploy that itself went through)
#   fleet-hub-aws-deploy.sh node-image <image>     on the box: MANAGED_NODE_IMAGE=<image>
#        (pinned by digest) in deploy.env, `bootstrap.sh apply` — the provisioner's
#        template, so new pods and the hub's pod rolls (fleet.user_pod_roll) take it;
#        the checkout and HUB_IMAGE stay. A failed apply puts the old line back (task APVZ)
#   fleet-hub-aws-deploy.sh instance               print the box's instance id
#   fleet-hub-aws-deploy.sh wx-notify <newreq> <fields> <review-sub> <admin>
#        change only the three WeChat settings, restart and probe; undo on failure
#   fleet-hub-aws-deploy.sh script deploy|rollback [<sha> <image>]
#        print the shell the box would run, send nothing (the selftest runs it
#        against a sandbox checkout)
#
# The box is AWS_BOX_INSTANCE_ID, else the ONE running instance tagged
# Name=$AWS_BOX_TAG (tokenman-core): none or two is refused, nothing sent — the
# fleet's addressing rule (refuse, never guess). The command is
# AWS-RunShellScript (root on the box); this script waits for it, prints its
# stdout and stderr, and exits 0 only on Success. A command still running at
# FLEET_SSM_TIMEOUT is cancelled and red.
#
# Settings (environment): AWS_REGION (us-west-2) · AWS_BOX_INSTANCE_ID ·
# AWS_BOX_TAG (tokenman-core) · AWS_BOX_REPO_DIR (/home/ubuntu/src: the box's
# checkout) · AWS_BOX_CONF (/etc/fleet-core/deploy.env) · FLEET_SSM_TIMEOUT
# (1800 s) · FLEET_SSM_POLL (5 s) · FLEET_AWS (the `aws` command: the
# selftest's seam). Credentials are the caller's (the job's OIDC role) — none is
# read or written here.
#
# Exit: 0 done · 1 the box's command failed / timed out, or the box is not one
# instance · 2 usage
set -uo pipefail
die() { printf 'fleet-hub-aws-deploy: %s\n' "$*" >&2; exit 2; }
red() { printf 'fleet-hub-aws-deploy: %s\n' "$*" >&2; exit 1; }

AWS_REGION=${AWS_REGION:-us-west-2}
AWS_BOX_TAG=${AWS_BOX_TAG:-tokenman-core}
AWS_BOX_REPO_DIR=${AWS_BOX_REPO_DIR:-/home/ubuntu/src}
AWS_BOX_CONF=${AWS_BOX_CONF:-/etc/fleet-core/deploy.env}
FLEET_SSM_TIMEOUT=${FLEET_SSM_TIMEOUT:-1800}
FLEET_SSM_POLL=${FLEET_SSM_POLL:-5}
case "$FLEET_SSM_TIMEOUT" in ''|*[!0-9]*) FLEET_SSM_TIMEOUT=1800 ;; esac
case "$FLEET_SSM_POLL" in ''|*[!0-9]*) FLEET_SSM_POLL=5 ;; esac

# shellcheck disable=SC2086  # the seam is a command line, word-split on purpose
aws_() { ${FLEET_AWS:-aws} --region "$AWS_REGION" "$@"; }

safe() {   # safe <what> <value> <ERE>
  case "$2" in *$'\n'*|*$'\r'*) die "$1 must be one line" ;; esac
  printf '%s' "$2" | grep -Eq "$3" || die "$1 '$2' is not what it should be ($3)"
}

# The shell the box runs (root). Values are checked before they are written in.
remote_script() {   # remote_script deploy|rollback [<sha> <image>]
  local mode=$1 sha=${2:-} image=${3:-}
  safe repo-dir "$AWS_BOX_REPO_DIR" '^/[A-Za-z0-9._/-]+$'
  safe conf "$AWS_BOX_CONF" '^/[A-Za-z0-9._/-]+$'
  if [ "$mode" = wx-notify ]; then
    [ "$#" = 5 ] || die 'usage: wx-notify <newreq> <fields> <review-sub> <admin>'
    safe newreq "$2" '^[A-Za-z0-9_-]{20,100}$'
    safe fields "$3" '^[a-z0-9_=,]+$'
    safe review-sub "$4" '^[A-Za-z0-9_-]{20,100}$'
    safe admin "$5" '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
    printf "#!/bin/bash\nset -uo pipefail\npython3 - --repo '%s' --conf '%s' --newreq '%s' --fields '%s' --review-sub '%s' --admin '%s' <<'WX_CONFIG_PY'\n" \
      "$AWS_BOX_REPO_DIR" "$AWS_BOX_CONF" "$2" "$3" "$4" "$5"
    cat "$(dirname "$0")/fleet-wx-config.py"
    printf '\nWX_CONFIG_PY\n'
    return
  fi
  if [ "$mode" = deploy ]; then
    safe sha "$sha" '^[0-9a-f]{40}$'
    safe image "$image" '^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
  elif [ "$mode" = node-image ]; then
    image=$sha sha=''
    safe image "$image" '^[A-Za-z0-9][A-Za-z0-9._/-]*@sha256:[0-9a-f]{64}$'
  fi
  printf '#!/bin/bash\nset -uo pipefail\nmode=%s sha=%s image=%s repo=%s conf=%s\n' \
    "$mode" "$sha" "$image" "$AWS_BOX_REPO_DIR" "$AWS_BOX_CONF"
  cat <<'BOX'
say() { printf '[hub-deploy@box] %s\n' "$*"; }
[ -d "$repo/.git" ] || { say "no checkout at $repo — nothing changed"; exit 3; }
[ -f "$conf" ] || { say "no $conf — nothing changed"; exit 3; }
# the checkout's owner runs git (root in another user's tree: «dubious ownership»)
owner=$(stat -c %U "$repo" 2>/dev/null || stat -f %Su "$repo")
g() {
  if [ "$owner" = "$(id -un)" ]; then git -C "$repo" "$@"; else sudo -u "$owner" -H git -C "$repo" "$@"; fi
}
boot() { bash "$repo/deploy/aws/k3s-box/bootstrap.sh" apply; }
set_image() {   # HUB_IMAGE=<image> in $conf, every other line byte for byte
  local tmp; tmp=$(mktemp "$conf.XXXXXX")
  awk -v img="$1" 'BEGIN{d=0} /^HUB_IMAGE=/{print "HUB_IMAGE=" img; d=1; next} {print} END{if(!d) print "HUB_IMAGE=" img}' "$conf" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f "$tmp" "$conf"
}
put_back() {   # the deploy.env + checkout the last deploy replaced, applied
  [ -f "$conf.prev" ] && [ -s "$conf.prev-ref" ] || { say "no previous release recorded — nothing to roll back to"; return 1; }
  cp -p "$conf.prev" "$conf"
  g -c advice.detachedHead=false checkout -q --detach "$(cat "$conf.prev-ref")" || { say "could not check out $(cat "$conf.prev-ref")"; return 1; }
  say "rolling back to $(sed -n 's/^HUB_IMAGE=//p' "$conf") at $(cat "$conf.prev-ref")"
  boot
}

if [ "$mode" = node-image ]; then
  was=$(sed -n 's/^MANAGED_NODE_IMAGE=//p' "$conf" | tail -1)
  [ "$was" = "$image" ] && { say "the template is already $image"; exit 0; }
  cp -p "$conf" "$conf.node-prev" || { say "could not record the live template image — nothing changed"; exit 3; }
  tmp=$(mktemp "$conf.XXXXXX")
  awk -v img="$image" 'BEGIN{d=0} /^MANAGED_NODE_IMAGE=/{print "MANAGED_NODE_IMAGE=" img; d=1; next} {print} END{if(!d) print "MANAGED_NODE_IMAGE=" img}' "$conf" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f "$tmp" "$conf" || { say "could not write MANAGED_NODE_IMAGE into $conf"; exit 3; }
  say "template: ${was:-none} → $image"
  if ! boot; then
    say "bootstrap.sh apply failed — putting the previous template image back"
    cp -p "$conf.node-prev" "$conf" && boot || say "ROLLBACK FAILED — the box needs a person (deploy/aws/README.md «Roll back»)"
    exit 1
  fi
  say "template on $image"
  exit 0
fi

if [ "$mode" = rollback ]; then
  put_back || exit 1
  say "rolled back"
  exit 0
fi

say "live: $(sed -n 's/^HUB_IMAGE=//p' "$conf" | tail -1) at $(g rev-parse HEAD 2>/dev/null)"
g cat-file -e "$sha^{commit}" 2>/dev/null || g fetch -q --no-tags origin "$sha" 2>/dev/null \
  || g fetch -q --no-tags origin '+refs/heads/*:refs/remotes/origin/*'
g cat-file -e "$sha^{commit}" 2>/dev/null || { say "$sha is not in $repo even after a fetch — nothing changed"; exit 3; }
# what is live, for a rollback (this one's or the job's after a red health check)
cp -p "$conf" "$conf.prev" && g rev-parse HEAD > "$conf.prev-ref" || { say "could not record the live release — nothing changed"; exit 3; }
g -c advice.detachedHead=false checkout -q --detach "$sha" || { say "could not check out $sha — nothing changed"; exit 3; }
set_image "$image" || { say "could not write HUB_IMAGE into $conf"; put_back; exit 1; }
say "apply: $image at $sha"
if ! boot; then
  say "bootstrap.sh apply failed — putting the previous release back"
  put_back || say "ROLLBACK FAILED — the box needs a person (deploy/aws/README.md «Roll back»)"
  exit 1
fi
say "deployed $image at $sha"
BOX
}

instance() {
  if [ -n "${AWS_BOX_INSTANCE_ID:-}" ]; then
    safe AWS_BOX_INSTANCE_ID "$AWS_BOX_INSTANCE_ID" '^i-[0-9a-f]{8,17}$'
    printf '%s\n' "$AWS_BOX_INSTANCE_ID"; return 0
  fi
  local ids n
  ids=$(aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=$AWS_BOX_TAG" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) \
    || red "cannot list instances tagged Name=$AWS_BOX_TAG: $ids"
  # shellcheck disable=SC2086  # ids are i-… words
  n=$(set -- $ids; echo $#)
  [ "$n" = 1 ] || red "$n running instances are tagged Name=$AWS_BOX_TAG (${ids:-none}) — refusing to guess; set AWS_BOX_INSTANCE_ID"
  safe instance "$ids" '^i-[0-9a-f]{8,17}$'
  printf '%s\n' "$ids"
}

# send <mode> [<sha> <image>]: the script through SSM, wait, print, judge
send() {
  local iid script params cid t0 inv st code
  iid=$(instance) || exit 1
  script=$(remote_script "$@") || exit 2
  # shellcheck disable=SC2016  # $rc is the box's, written in on purpose
  params=$(B64=$(printf '%s\n' "$script" | base64 | tr -d '\n') TMO="$FLEET_SSM_TIMEOUT" python3 -c '
import json, os
print(json.dumps({"commands": ["echo %s | base64 -d > /tmp/fleet-hub-deploy.sh && bash /tmp/fleet-hub-deploy.sh; rc=$?; rm -f /tmp/fleet-hub-deploy.sh; exit $rc" % os.environ["B64"]],
                  "executionTimeout": [os.environ["TMO"]]}))')
  cid=$(aws_ ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
    --comment "hub-deploy $1 ${2:0:7}" --timeout-seconds 120 \
    --parameters "$params" --query Command.CommandId --output text 2>&1) \
    || red "ssm send-command to $iid failed: $cid"
  printf '%s' "$cid" | grep -Eq '^[0-9a-f-]{36}$' || red "ssm send-command named no command id: $cid"
  echo "ssm: $1 → $iid, command $cid"
  t0=$SECONDS st=Pending
  while :; do
    sleep "$FLEET_SSM_POLL"
    inv=$(aws_ ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --output json 2>/dev/null) || inv=''
    st=$(printf '%s' "$inv" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("Status") or "")
except Exception: print("")' 2>/dev/null)
    case "$st" in Success|Failed|Cancelled|TimedOut|Undeliverable|Terminated) break ;; esac
    if [ $((SECONDS - t0)) -ge "$FLEET_SSM_TIMEOUT" ]; then
      aws_ ssm cancel-command --command-id "$cid" --instance-ids "$iid" >/dev/null 2>&1
      st=timeout; break
    fi
  done
  printf '%s' "$inv" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
o=d.get("StandardOutputContent") or ""; e=d.get("StandardErrorContent") or ""
if o: print("── the box (stdout) ──\n" + o.rstrip())
if e: print("── the box (stderr) ──\n" + e.rstrip())' 2>/dev/null
  code=$(printf '%s' "$inv" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("ResponseCode"))
except Exception: print("?")' 2>/dev/null)
  [ "$st" = Success ] || red "the box's $1 ended $st (exit ${code:-?}) — command $cid on $iid"
  echo "ssm: $1 on $iid succeeded"
}

cmd=${1:-}
case "$cmd" in
  deploy)   [ "$#" = 3 ] || die "usage: deploy <sha> <image>"; send deploy "$2" "$3" ;;
  rollback) [ "$#" = 1 ] || die "usage: rollback"; send rollback ;;
  node-image) [ "$#" = 2 ] || die "usage: node-image <image@sha256:…>"; send node-image "$2" ;;
  wx-notify) [ "$#" = 5 ] || die 'usage: wx-notify <newreq> <fields> <review-sub> <admin>'; send "$@" ;;
  instance) instance ;;
  script)   shift; case "${1:-}" in deploy|rollback|node-image|wx-notify) remote_script "$@" ;; *) die "usage: script deploy|rollback|node-image|wx-notify [arguments]" ;; esac ;;
  -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "usage: deploy <sha> <image> | rollback | node-image <image@sha256:…> | wx-notify <newreq> <fields> <review-sub> <admin> | instance | script <mode> [arguments]" ;;
esac
