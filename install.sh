#!/usr/bin/env bash
# arr-stack installer: takes a fresh Debian/Ubuntu Docker host to two running
# Portainer GitOps stacks.
#
# It never deploys the stacks itself. It prepares the host, bootstraps
# Portainer, and creates the `infra` and `media` stacks as *Git stacks* through
# the Portainer API. From then on Portainer deploys from git, exactly as in the
# manual guide (docs/). Re-runnable: every step checks state first and skips
# what's already done. Existing stacks are never modified.
#
# Usage:
#   sudo ./install.sh                     interactive
#   sudo ./install.sh --config FILE       answers from a KEY=VALUE file (see install.env.example)
#   ./install.sh --check                  read-only preflight, changes nothing
#   add --yes to skip confirmations (only with --config)
#
# Secrets are never written to disk and never passed as command-line arguments.
set -euo pipefail

cd "$(dirname "$0")"
REPO_DIR=$(pwd)
# The public template. Deploying from it would hand its owner's pushes to your server.
TEMPLATE_REPO=spierenburg/arr-stack
PORTAINER_API=https://127.0.0.1:9443/api   # local, self-signed: curl -k is used only for this

# ------------------------------------------------------------------ output
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}✔${N} $*"; }
warn() { echo "    ${Y}!${N} $*"; }
die()  { echo "    ${R}✘ $*${N}" >&2; exit 1; }

# ------------------------------------------------------------------ args
MODE=install CONFIG='' YES=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --check)  MODE=check ;;
    --config) CONFIG=${2:?--config needs a file}; shift ;;
    --yes)    YES=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ $YES -eq 1 && -z $CONFIG ]] && die "--yes requires --config"

confirm() { # $1 = question; default no
  [[ $YES -eq 1 ]] && return 0
  local a; read -r -p "    $1 [y/N] " a; [[ $a =~ ^[Yy]$ ]]
}

# ask VAR "Prompt" [default] [secret]: keeps a value already loaded from --config
ask() {
  local var=$1 prompt=$2 def=${3:-} secret=${4:-} val
  [[ -n ${!var:-} ]] && return 0
  [[ -n $CONFIG ]] && [[ -n $def ]] && { printf -v "$var" '%s' "$def"; return 0; }
  [[ -n $CONFIG ]] && die "$var missing from $CONFIG"
  while :; do
    if [[ -n $secret ]]; then read -r -s -p "    $prompt: " val; echo
    else read -r -p "    $prompt${def:+ [$def]}: " val; val=${val:-$def}; fi
    [[ -n $val ]] && break
    echo "    (required)"
  done
  printf -v "$var" '%s' "$val"
}

# ------------------------------------------------------------------ preflight (read-only)
preflight() {
  step "Preflight"
  local fail=0
  if [[ -r /etc/os-release ]] && grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then
    ok "Debian/Ubuntu family"
  else warn "not Debian/Ubuntu: untested, continuing"; fi

  command -v docker >/dev/null && ok "docker" || { echo "    ${R}✘${N} docker missing: install from https://docs.docker.com/engine/install/"; fail=1; }
  docker compose version >/dev/null 2>&1 && ok "docker compose plugin" || { echo "    ${R}✘${N} docker compose plugin missing"; fail=1; }
  command -v curl >/dev/null && ok "curl" || { echo "    ${R}✘${N} curl missing"; fail=1; }
  command -v git  >/dev/null && ok "git"  || { echo "    ${R}✘${N} git missing"; fail=1; }
  command -v jq   >/dev/null && ok "jq"   || warn "jq missing (the installer offers to install it)"
  [[ -c /dev/net/tun ]] && ok "/dev/net/tun" || { echo "    ${R}✘${N} /dev/net/tun missing (Gluetun needs it)"; fail=1; }

  local p holder
  for p in 53 80 3000 9443; do
    holder=$(ss -Hltnup "sport = :$p" 2>/dev/null | head -1 || true)
    if [[ -z $holder ]]; then ok "port $p free"
    elif grep -qE 'docker|portainer' <<<"$holder"; then ok "port $p held by docker"
    elif [[ $p == 53 ]] && grep -q systemd-resolve <<<"$holder"; then warn "port 53 held by systemd-resolved (the installer can fix this)"
    else echo "    ${R}✘${N} port $p in use: $holder"; fail=1; fi
  done
  return $fail
}

# ------------------------------------------------------------------ config
ALLOWED_KEYS="DOMAIN TZ PUID PGID CONFIG_ROOT DATA_ROOT
VPN_SERVICE_PROVIDER WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES VPN_SERVER_COUNTRIES VPN_PORT_FORWARDING
REPO_URL REPO_REF REPO_USERNAME REPO_TOKEN PORTAINER_USER PORTAINER_PASSWORD"

load_config() { # parse KEY=VALUE lines, no shell evaluation
  [[ -f $CONFIG ]] || die "config file not found: $CONFIG"
  [[ $(stat -c %a "$CONFIG") =~ ^[46]00$ ]] || die "$CONFIG holds secrets: chmod 600 it first"
  local line key val
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || die "bad line in $CONFIG: $line"
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    val=${val%\"}; val=${val#\"}
    grep -qw "$key" <<<"$ALLOWED_KEYS" || die "unknown key in $CONFIG: $key"
    printf -v "$key" '%s' "$val"
  done < "$CONFIG"
  ok "loaded $CONFIG"
}

collect() {
  step "Settings"
  [[ -n $CONFIG ]] && load_config

  local user_name=${SUDO_USER:-root} tz_def remote_def
  tz_def=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Europe/Amsterdam)
  remote_def=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#' || true)

  echo "    ${B}Host${N}"
  echo "    Home domain: apps live at <app>.<home domain>, e.g. jellyfin.home.arpa."
  echo "    Safe picks: home.arpa, smith.home.arpa, internal, media.internal (docs/02)"
  ask DOMAIN            "Home domain" "home.arpa"
  DOMAIN=$(tr '[:upper:]' '[:lower:]' <<<"${DOMAIN%.}")
  ask TZ                "Timezone" "$tz_def"
  ask PUID              "User ID the apps run as" "$(id -u "$user_name")"
  ask PGID              "Group ID the apps run as" "$(id -g "$user_name")"
  ask CONFIG_ROOT       "App state folder" "/opt/arr/config"
  ask DATA_ROOT         "Downloads + media folder (one filesystem!)" "/srv/data"
  echo "    ${B}VPN${N} (Gluetun, WireGuard)"
  ask VPN_SERVICE_PROVIDER  "VPN provider (gluetun name)" "protonvpn"
  ask WIREGUARD_PRIVATE_KEY "WireGuard private key (input hidden)" "" secret
  ask WIREGUARD_ADDRESSES   "WireGuard address (e.g. 10.2.0.2/32)"
  ask VPN_SERVER_COUNTRIES  "VPN server countries" "Netherlands"
  ask VPN_PORT_FORWARDING   "Provider port forwarding (on/off)" "off"
  echo "    ${B}GitOps${N}"
  echo "    The deploy repo decides what runs on this server: it must be YOUR copy (README step 0)."
  ask REPO_URL          "Git repo Portainer deploys from" "$remote_def"
  local slug
  slug=$(tr '[:upper:]' '[:lower:]' <<<"$REPO_URL" \
    | sed -E 's#^(https?://|ssh://)?(git@)?github\.com[:/]##; s#\.git$##; s#/+$##')
  if [[ $slug == "$TEMPLATE_REPO" ]]; then
    die "$REPO_URL is the template, not your copy. On GitHub: Use this template → create <you>/arr-stack,
      then: git clone https://github.com/<you>/arr-stack.git && cd arr-stack && sudo ./install.sh"
  fi
  ask REPO_REF          "Branch" "refs/heads/main"
  [[ $REPO_REF == refs/* ]] || REPO_REF=refs/heads/$REPO_REF
  echo "    ${B}Portainer${N}"
  ask PORTAINER_USER     "Portainer admin user" "admin"
  ask PORTAINER_PASSWORD "Portainer admin password, min 12 chars (input hidden)" "" secret
}

validate() {
  step "Validating settings"
  [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*[a-z]{2,}$ ]] || die "home domain '$DOMAIN' isn't a valid name"
  case $DOMAIN in
    local|*.local)
      die ".local is reserved for mDNS/Bonjour (printers, Chromecast, Apple devices): lookups would break. Use home.arpa" ;;
    home.arpa|*.home.arpa|internal|*.internal)
      ok "home domain $DOMAIN (reserved for private networks)" ;;
    *)
      warn "'$DOMAIN' is not reserved for private use. If .${DOMAIN##*.} is a real public"
      warn "suffix (now or later), AdGuard will hide the real websites under it."
      confirm "Use '$DOMAIN' anyway?" || die "pick home.arpa or .internal (docs/02)" ;;
  esac
  [[ $PUID =~ ^[0-9]+$ && $PGID =~ ^[0-9]+$ ]] || die "PUID/PGID must be numbers"
  [[ $CONFIG_ROOT == /* && $DATA_ROOT == /* ]] || die "CONFIG_ROOT and DATA_ROOT must be absolute paths"
  [[ $WIREGUARD_PRIVATE_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "WireGuard private key isn't a 44-char base64 key"
  [[ $WIREGUARD_ADDRESSES =~ ^[0-9.]+/[0-9]+ ]] || die "WIREGUARD_ADDRESSES should look like 10.2.0.2/32"
  [[ $VPN_PORT_FORWARDING =~ ^(on|off)$ ]] || die "VPN_PORT_FORWARDING must be on or off"
  [[ ${#PORTAINER_PASSWORD} -ge 12 ]] || die "Portainer password must be at least 12 characters"
  ok "formats look right"

  # Git: reachable anonymously, or ask for read-only credentials
  if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$REPO_URL" "$REPO_REF" >/dev/null 2>&1; then
    ok "repo $REPO_URL ($REPO_REF) reachable"; REPO_AUTH=false
  else
    warn "repo not readable anonymously: private repo needs a read-only token (docs/03)"
    ask REPO_USERNAME "GitHub username"
    ask REPO_TOKEN    "GitHub token, Contents: read-only (input hidden)" "" secret
    # header passed via GIT_CONFIG_* env (git >= 2.31), so the token never appears in argv
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "$REPO_USERNAME" "$REPO_TOKEN" | base64 -w0)" \
      git ls-remote --exit-code "$REPO_URL" "$REPO_REF" >/dev/null 2>&1 \
      || die "repo $REPO_URL ($REPO_REF) not readable with these credentials"
    ok "repo reachable with token"; REPO_AUTH=true
  fi

  # The branch Portainer deploys must be digest-pinned, same gate as CI
  "$REPO_DIR/scripts/check-pins.sh" >/dev/null || die "unpinned images in this checkout: run scripts/check-pins.sh"
  ok "all images digest-pinned"
}

summary() {
  step "About to do"
  cat <<EOF
    1. Free port 53 from systemd-resolved, if needed (asks first)
    2. Create $CONFIG_ROOT and $DATA_ROOT, owner $PUID:$PGID (scripts/init.sh)
    3. Create docker network 'proxy', start Portainer (bootstrap/)
    4. Create Portainer Git stacks 'infra' and 'media'
         repo  $REPO_URL @ $REPO_REF
         poll  every 5m, re-pull images
       Portainer then deploys them from git. Anyone who can push to that
       repo's $REPO_REF controls this server: make sure that's only you.
    Services will live at <app>.$DOMAIN
EOF
  confirm "Proceed?" || die "aborted"
}

# ------------------------------------------------------------------ host
ensure_jq() {
  command -v jq >/dev/null && return 0
  confirm "jq is required. Install it with apt-get?" || die "jq required"
  apt-get update -qq && apt-get install -y -qq jq >/dev/null
  ok "jq installed"
}

fix_resolved() {
  step "Port 53"
  if ! ss -Hltnup 'sport = :53' 2>/dev/null | grep -q systemd-resolve; then ok "nothing to do"; return; fi
  echo "    systemd-resolved listens on :53. The fix (docs/01) disables its stub listener and"
  echo "    points the host itself at public DNS, so the host never depends on AdGuard."
  confirm "Apply it (drop-in /etc/systemd/resolved.conf.d/arr-stack.conf)?" || die "port 53 must be free for AdGuard"
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\nDNS=9.9.9.9 1.1.1.1\n' > /etc/systemd/resolved.conf.d/arr-stack.conf
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
  sleep 1
  ss -Hltnup 'sport = :53' 2>/dev/null | grep -q systemd-resolve && die "port 53 still held"
  ok "port 53 free"
}

host_folders() {
  step "Folders"
  PUID=$PUID PGID=$PGID CONFIG_ROOT=$CONFIG_ROOT DATA_ROOT=$DATA_ROOT "$REPO_DIR/scripts/init.sh" \
    | sed 's/^/    /' || die "scripts/init.sh failed, see above"
}

bootstrap_portainer() {
  step "Portainer"
  docker network inspect proxy >/dev/null 2>&1 || { docker network create proxy >/dev/null; ok "network proxy created"; }
  if [[ $(docker inspect -f '{{.State.Running}}' portainer 2>/dev/null) == true ]]; then
    ok "already running"
  else
    DOMAIN=$DOMAIN docker compose -f "$REPO_DIR/bootstrap/portainer.compose.yaml" up -d --quiet-pull
    ok "started"
  fi
  local i
  for i in $(seq 1 30); do curl -ksf "$PORTAINER_API/system/status" >/dev/null && break; sleep 2; done
  curl -ksf "$PORTAINER_API/system/status" >/dev/null || die "Portainer API not answering on :9443"
  ok "API up"
}

# ------------------------------------------------------------------ portainer api
api() { # api METHOD PATH [curl args...]: JWT sent via header file, never argv
  local m=$1 p=$2; shift 2
  curl -ksS --fail-with-body -X "$m" -H @<(printf 'Authorization: Bearer %s\n' "$JWT") "$@" "$PORTAINER_API$p"
}

portainer_login() {
  local init_body code
  init_body=$(jq -n '{Username: $ENV.PORTAINER_USER, Password: $ENV.PORTAINER_PASSWORD}')
  code=$(curl -ks -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    --data @- "$PORTAINER_API/users/admin/init" <<<"$init_body")
  case $code in
    200) ok "admin user '$PORTAINER_USER' created" ;;
    409) ok "admin already initialised, logging in" ;;
    *) die "admin init failed (HTTP $code). If Portainer was started >5 min ago it locks the wizard: restart the portainer container and re-run" ;;
  esac
  JWT=$(curl -ksS --fail-with-body -H 'Content-Type: application/json' --data @- "$PORTAINER_API/auth" <<<"$init_body" | jq -r .jwt)
  [[ -n $JWT && $JWT != null ]] || die "login failed: wrong Portainer password?"
  ok "logged in"
}

portainer_endpoint() {
  ENDPOINT_ID=$(api GET /endpoints | jq -r '[.[] | select(.Type==1 and (.URL|startswith("unix://")))][0].Id // empty')
  if [[ -z $ENDPOINT_ID ]]; then
    ENDPOINT_ID=$(api POST /endpoints -F Name=local -F EndpointCreationType=1 | jq -r .Id)
    ok "local Docker environment created (id $ENDPOINT_ID)"
  else ok "local Docker environment id $ENDPOINT_ID"; fi
}

create_stack() { # $1 = name; remaining = env var names for that stack
  local name=$1; shift
  if api GET /stacks | jq -e --arg n "$name" --argjson e "$ENDPOINT_ID" \
       'any(.[]; .Name==$n and .EndpointId==$e)' >/dev/null; then
    ok "stack '$name' exists: left untouched (change it via git or the Portainer UI)"
    return
  fi
  echo "    creating stack '$name' (Portainer clones the repo and pulls images, this can take minutes)…"
  local env_json body
  # values go through the environment, not jq's argv, because some are secrets
  env_json=$(for v in "$@"; do K=$v V=${!v} jq -n '{name: $ENV.K, value: $ENV.V}'; done | jq -s .)
  body=$(NAME=$name FILE="stacks/$name/compose.yaml" REPO_AUTH=$REPO_AUTH \
    REPO_USERNAME=${REPO_USERNAME:-} REPO_TOKEN=${REPO_TOKEN:-} \
    jq -n --argjson env "$env_json" '{
      name: $ENV.NAME,
      repositoryURL: $ENV.REPO_URL,
      repositoryReferenceName: $ENV.REPO_REF,
      composeFile: $ENV.FILE,
      repositoryAuthentication: ($ENV.REPO_AUTH == "true"),
      repositoryUsername: $ENV.REPO_USERNAME,
      repositoryPassword: $ENV.REPO_TOKEN,
      autoUpdate: {interval: "5m", forcePullImage: true, forceUpdate: false},
      env: $env
    }')
  api POST "/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" \
    -H 'Content-Type: application/json' --max-time 900 --data @- <<<"$body" >/dev/null \
    || die "Portainer refused stack '$name' (message above)"
  ok "stack '$name' created and deployed from git"
}

wait_healthy() { # $1 = container
  local i s
  for i in $(seq 1 60); do
    s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || true)
    [[ $s == healthy || $s == running ]] && { ok "$1 $s"; return 0; }
    sleep 5
  done
  warn "$1 not healthy after 5 min (state: ${s:-missing}): check its logs in Portainer"
  return 1
}

verify() {
  step "Verifying"
  wait_healthy traefik || true
  wait_healthy gluetun || true
  local ip i
  ip=$(hostname -I | awk '{print $1}')
  # Routing check through Traefik, by Host header (works before DNS is set up).
  # 404 = Traefik has no router for that name; 000 = nothing answered.
  local host code
  for host in traefik jellyfin; do
    for i in $(seq 1 24); do
      code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host.$DOMAIN" http://127.0.0.1/ || true)
      [[ $code != 000 && $code != 404 ]] && { ok "http://$host.$DOMAIN routed (HTTP $code)"; break; }
      [[ $i -eq 24 ]] && warn "http://$host.$DOMAIN not routed after 2 min (HTTP $code): check labels/logs"
      sleep 5
    done
  done
  if [[ $(docker exec gluetun wget -qO- https://ipinfo.io/ip 2>/dev/null) =~ ^[0-9a-f.:]+$ ]]; then
    ok "VPN tunnel up"
  else warn "couldn't confirm VPN egress yet: docker logs gluetun"; fi

  step "Done. Remaining manual steps"
  cat <<EOF
    1. AdGuard wizard:  http://$ip:3000   (admin UI port 3000, DNS port 53)
       then add DNS rewrite  *.$DOMAIN → $ip         docs/04-dns-adguard.md
    2. Router DHCP: DNS server = $ip (no public secondary)
    3. Wire the apps together                         docs/05-apps.md
    4. GitHub: branch protection on main + Renovate app   docs/03-gitops-stacks.md
    Portainer: https://$ip:9443  (user '$PORTAINER_USER'; self-signed, accept the warning once)
    Once DNS is pointed at AdGuard: http://jellyfin.$DOMAIN
EOF
}

# ------------------------------------------------------------------ main
if [[ $MODE == check ]]; then
  preflight && echo && ok "host ready for ./install.sh" || { echo; die "fix the items above"; }
  exit 0
fi

[[ $EUID -eq 0 ]] || die "run with sudo (it creates folders and starts Portainer)"
preflight || die "fix the preflight failures above, then re-run"
ensure_jq
collect
export PORTAINER_USER PORTAINER_PASSWORD REPO_URL REPO_REF
validate
summary
fix_resolved
host_folders
bootstrap_portainer
step "Portainer stacks"
portainer_login
portainer_endpoint
create_stack infra DOMAIN CONFIG_ROOT
create_stack media DOMAIN TZ PUID PGID CONFIG_ROOT DATA_ROOT \
  VPN_SERVICE_PROVIDER WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES VPN_SERVER_COUNTRIES VPN_PORT_FORWARDING
verify
