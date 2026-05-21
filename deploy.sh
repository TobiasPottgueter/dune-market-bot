#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_USER="dune"
REMOTE_DIR="/opt/market-bot"
DEPLOY_CONFIG="${SCRIPT_DIR}/.deploy-config"
MANIFEST_PATH="${SCRIPT_DIR}/k8s/market-bot.yaml"

# ── Parse flags ───────────────────────────────────────────────────────────────
SETUP_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--setup" || "$arg" == "-s" ]] && SETUP_MODE=true
done

# ── Load .deploy-config into env (never overwrites already-set vars) ──────────
load_config() {
  [ -f "$DEPLOY_CONFIG" ] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    [ -z "${!key+x}" ] && export "$key=$val"
  done < "$DEPLOY_CONFIG"
}

# ── Upsert a key in .deploy-config ────────────────────────────────────────────
save_config() {
  local key="$1" val="$2" tmp="${DEPLOY_CONFIG}.tmp"
  touch "$DEPLOY_CONFIG"
  grep -v "^${key}=" "$DEPLOY_CONFIG" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$DEPLOY_CONFIG"
}

# ── Find SSH key from standard candidate paths ────────────────────────────────
resolve_ssh_key() {
  local candidates=(
    "${SCRIPT_DIR}/sshKey"
    "${HOME}/.ssh/dune"
    "${HOME}/.ssh/id_ed25519"
    "${HOME}/.ssh/id_rsa"
  )
  for p in "${candidates[@]}"; do
    [ -f "$p" ] && printf '%s' "$p" && return 0
  done
  return 1
}

# ── List battlegroup names from the VM ───────────────────────────────────────
# Tries: 1) direct 'battlegroup list'  2) bash -lc  3) ~/.dune/*.yaml basenames
list_battlegroups_ssh() {
  local key="$1" vm_ip="$2"
  # Run on the remote side: try direct invocation first (PATH may differ), then login shell
  local raw
  raw=$(ssh -o StrictHostKeyChecking=no -i "$key" "${VM_USER}@${vm_ip}" \
    'battlegroup list 2>/dev/null || bash -lc "battlegroup list" 2>/dev/null' 2>/dev/null)
  if [ -n "$raw" ]; then
    printf '%s\n' "$raw" | \
      sed -n 's/^[[:space:]]*-[[:space:]]\(.*\)/\1/p' | \
      sed 's/[[:space:]]*$//' | grep -v '^$'
    return
  fi
  # Fall back: basenames of YAML files in ~/.dune/
  ssh -o StrictHostKeyChecking=no -i "$key" "${VM_USER}@${vm_ip}" \
    'for f in ~/.dune/*.yaml; do [ -f "$f" ] && basename "$f" .yaml; done' 2>/dev/null
}

# ── Read creds from ~/.dune/<battlegroup>.yaml on the VM ─────────────────────
# Sets DISCOVERED_DB_USER / DISCOVERED_DB_PASS on success, returns 1 otherwise.
read_battlegroup_creds() {
  local key="$1" vm_ip="$2" battlegroup="$3"
  local bg_yaml
  bg_yaml=$(ssh -o StrictHostKeyChecking=no -i "$key" "${VM_USER}@${vm_ip}" \
    "cat ~/.dune/${battlegroup}.yaml 2>/dev/null" 2>/dev/null || true)
  [ -z "$bg_yaml" ] && return 1

  # spec.database.template.spec.deployment.spec.{user,password}
  # Scan up to 20 lines after "deployment:" for the fields.
  DISCOVERED_DB_USER=$(printf '%s\n' "$bg_yaml" | awk '
    /deployment:/{d=1;n=0} d{n++}
    d && n<=20 && /^[[:space:]]+user:/{sub(/.*user:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}')
  DISCOVERED_DB_PASS=$(printf '%s\n' "$bg_yaml" | awk '
    /deployment:/{d=1;n=0} d{n++}
    d && n<=20 && /^[[:space:]]+password:/{sub(/.*password:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}')

  [ -z "$DISCOVERED_DB_PASS" ] && return 1
  export DISCOVERED_DB_USER="${DISCOVERED_DB_USER:-dune}"
  export DISCOVERED_DB_PASS
}

# ── Interactive setup wizard ──────────────────────────────────────────────────
run_setup() {
  local o="✓" x="✗"
  printf '\n=== deploy setup ===\n\n'

  # 1. SSH key
  printf 'Checking for SSH key...\n'
  local key_path="${SSH_KEY:-}"
  { [ -n "$key_path" ] && [ ! -f "$key_path" ]; } && key_path=""
  [ -z "$key_path" ] && key_path=$(resolve_ssh_key || true)
  if [ -z "$key_path" ]; then
    printf '  %s not found (checked ./sshKey, ~/.ssh/dune, ~/.ssh/id_ed25519, ~/.ssh/id_rsa)\n' "$x"
    printf '\n  Path to SSH private key: '
    read -r key_path
    [ -z "$key_path" ] && { printf 'SSH key is required.\n' >&2; exit 1; }
    [ -f "$key_path" ]  || { printf 'Key not found: %s\n' "$key_path" >&2; exit 1; }
  else
    printf '  %s SSH key: %s\n' "$o" "$key_path"
  fi
  save_config SSH_KEY "$key_path"
  export SSH_KEY="$key_path"
  printf '\n'

  # 2. VM IP
  printf 'VM connection:\n'
  local vm_ip="${DUNE_VM_IP:-}" prompt="  VM IP address"
  [ -n "$vm_ip" ] && prompt="${prompt} [${vm_ip}]"
  printf '%s: ' "$prompt"; read -r input
  [ -n "$input" ] && vm_ip="$input"
  [ -z "$vm_ip" ] && { printf 'VM IP is required.\n' >&2; exit 1; }
  save_config DUNE_VM_IP "$vm_ip"
  export DUNE_VM_IP="$vm_ip"
  printf '\n'

  # 3. Verify SSH
  printf 'Testing SSH connection to %s...\n' "$vm_ip"
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
       -i "$key_path" "${VM_USER}@${vm_ip}" "echo ok" &>/dev/null; then
    printf '  %s connected\n' "$o"
  else
    printf '  %s connection failed\n\n' "$x"
    printf '  Check: VM reachable at %s, key authorized for user %s, passwordless sudo for kubectl\n' \
      "$vm_ip" "$VM_USER"
    exit 1
  fi
  printf '\n'

  # 4. Discover DB
  printf 'Discovering database from cluster...\n'
  local db_svc_line
  db_svc_line=$(ssh -o StrictHostKeyChecking=no -i "$key_path" "${VM_USER}@${vm_ip}" \
    "sudo kubectl get svc -A --no-headers 2>/dev/null | awk '\$2 ~ /db-dbdepl-svc\$/ { print; exit }'" \
    2>/dev/null || true)

  if [ -n "$db_svc_line" ]; then
    local svc_ns svc_name db_host
    svc_ns=$(printf '%s' "$db_svc_line" | awk '{print $1}')
    svc_name=$(printf '%s' "$db_svc_line" | awk '{print $2}')
    db_host="${svc_name}.${svc_ns}.svc.cluster.local"
    printf '  %s DB host: %s\n' "$o" "$db_host"
    save_config DUNE_DB_HOST "$db_host"
    export DUNE_DB_HOST="$db_host"
  else
    printf '  %s DB service not found\n' "$x"
  fi

  local db_pod_line
  db_pod_line=$(ssh -o StrictHostKeyChecking=no -i "$key_path" "${VM_USER}@${vm_ip}" \
    "sudo kubectl get pods -A --no-headers 2>/dev/null | awk '\$2 ~ /db-dbdepl-sts-0\$/ { print; exit }'" \
    2>/dev/null || true)

  local db_user="" db_pass="" db_port=""

  if [ -n "$db_pod_line" ]; then
    local db_ns db_pod
    db_ns=$(printf '%s' "$db_pod_line" | awk '{print $1}')
    db_pod=$(printf '%s' "$db_pod_line" | awk '{print $2}')
    printf '  %s DB pod: %s\n' "$o" "$db_pod"

    # Build battlegroup list: try 'battlegroup list' command, fall back to pod name
    printf '  Listing battlegroups...\n'
    local bg_list_raw chosen_bg=""
    bg_list_raw=$(list_battlegroups_ssh "$key_path" "$vm_ip")

    local -a battlegroups=()
    while IFS= read -r bg; do
      [ -n "$bg" ] && battlegroups+=("$bg")
    done <<< "$bg_list_raw"

    if [ ${#battlegroups[@]} -eq 0 ]; then
      # Fall back: derive from pod name
      local pod_bg="${db_pod%-db-dbdepl-sts-*}"
      [ "$pod_bg" != "$db_pod" ] && battlegroups=("$pod_bg")
    fi

    if [ ${#battlegroups[@]} -eq 0 ]; then
      printf '  %s battlegroup list returned nothing — enter name manually\n' "$x"
      printf '  Battlegroup name: '; read -r manual_bg
      [ -n "$manual_bg" ] && battlegroups=("$manual_bg")
    fi

    if [ ${#battlegroups[@]} -eq 0 ]; then
      printf '  %s no battlegroups found, will prompt for credentials\n' "$x"
    elif [ ${#battlegroups[@]} -eq 1 ]; then
      chosen_bg="${battlegroups[0]}"
      printf '  %s battlegroup: %s\n' "$o" "$chosen_bg"
    else
      printf '  Available battlegroups:\n'
      local i=1
      for bg in "${battlegroups[@]}"; do
        printf '    [%d] %s\n' "$i" "$bg"
        i=$((i+1))
      done
      local choice
      printf '  Choose [1-%d]: ' "${#battlegroups[@]}"; read -r choice
      choice="${choice:-1}"
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#battlegroups[@]}" ]; then
        chosen_bg="${battlegroups[$((choice-1))]}"
      else
        chosen_bg="${battlegroups[0]}"
      fi
      printf '  %s battlegroup: %s\n' "$o" "$chosen_bg"
    fi

    # Read credentials from battlegroup YAML (only source — never use superuser from printenv)
    DISCOVERED_DB_USER="" DISCOVERED_DB_PASS=""
    if [ -n "$chosen_bg" ] && read_battlegroup_creds "$key_path" "$vm_ip" "$chosen_bg"; then
      db_user="$DISCOVERED_DB_USER"
      db_pass="$DISCOVERED_DB_PASS"
      printf '  %s credentials from ~/.dune/%s.yaml\n' "$o" "$chosen_bg"
    else
      [ -n "$chosen_bg" ] && printf '  %s battlegroup YAML not found or missing password\n' "$x"
    fi

    [ -n "$db_user" ] && { save_config DUNE_DB_USER "$db_user"; export DUNE_DB_USER="$db_user"; }
    [ -n "$db_pass" ] && { save_config DUNE_DB_PASS "$db_pass"; export DUNE_DB_PASS="$db_pass"; }
  else
    printf '  %s DB pod not found\n' "$x"
  fi

  # Prompt for anything still missing
  if [ -z "$db_user" ]; then
    printf '  DB user [dune]: '; read -r db_user; db_user="${db_user:-dune}"
    save_config DUNE_DB_USER "$db_user"; export DUNE_DB_USER="$db_user"
  fi
  if [ -z "$db_pass" ]; then
    printf '  DB password: '; read -rs db_pass; printf '\n'
    [ -z "$db_pass" ] && { printf 'DB password is required.\n' >&2; exit 1; }
    save_config DUNE_DB_PASS "$db_pass"; export DUNE_DB_PASS="$db_pass"
  fi

  printf '\n%s Setup complete — config saved to .deploy-config\n\n' "$o"
}

needs_setup() { [ -z "${DUNE_VM_IP:-}" ] || [ -z "${DUNE_DB_PASS:-}" ]; }

# ── Bootstrap ─────────────────────────────────────────────────────────────────
load_config

if [ "$SETUP_MODE" = "true" ]; then
  run_setup
  exit 0
elif needs_setup; then
  printf 'First run: launching setup wizard. Re-run with --setup to reconfigure.\n'
  run_setup
fi

SSH_KEY="${SSH_KEY:-$(resolve_ssh_key || true)}"
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
  printf 'error: SSH key not found. Run ./deploy.sh --setup\n' >&2; exit 1
fi

VM_IP="${DUNE_VM_IP:-}"
[ -z "$VM_IP" ] && { printf 'error: VM IP not set. Run ./deploy.sh --setup\n' >&2; exit 1; }

vm_ssh() { ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "${VM_USER}@${VM_IP}" "$@"; }
vm_scp() { scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$@"; }

manifest_value() {
  local key="$1"
  awk -v key="$key" '
    $1 == key ":" {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$MANIFEST_PATH"
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

shell_quote() {
  printf "'"
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

set_manifest_value() {
  local file="$1" key="$2" value
  value="$(yaml_quote "$3")"
  YAML_KEY="$key" YAML_VALUE="$value" perl -0pi -e '
    my $key = $ENV{YAML_KEY};
    my $value = $ENV{YAML_VALUE};
    my $count = s/^(\s*\Q$key\E:\s*).*$/$1$value/m;
    die "missing manifest key: $key\n" unless $count;
  ' "$file"
}

printf '==> Deploying to %s...\n' "$VM_IP"

# ── Cross-compile ─────────────────────────────────────────────────────────────
printf '==> Cross-compiling for Linux/amd64...\n'
cd "${SCRIPT_DIR}"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o market-bot-linux .
printf '    built: %s\n' "$(du -sh market-bot-linux | cut -f1)"

# ── Remote directories ────────────────────────────────────────────────────────
printf '==> Preparing remote directories...\n'
vm_ssh "sudo mkdir -p ${REMOTE_DIR}/{data,cache,bin} && sudo chown -R ${VM_USER}:${VM_USER} ${REMOTE_DIR}"

# ── Detect DB connection details ──────────────────────────────────────────────
printf '==> Detecting DB connection details from cluster...\n'
DB_SVC_LINE=$(vm_ssh "sudo kubectl get svc -A --no-headers 2>/dev/null | awk '\$2 ~ /db-dbdepl-svc$/ { print; exit }'" 2>/dev/null || true)
DB_POD_LINE=$(vm_ssh "sudo kubectl get pods -A --no-headers 2>/dev/null | awk '\$2 ~ /db-dbdepl-sts-0$/ { print; exit }'" 2>/dev/null || true)

DETECTED_DB_HOST="" DETECTED_DB_PORT=""
DB_NS="" DB_POD=""

if [ -n "$DB_SVC_LINE" ]; then
  DB_SVC_NS=$(printf '%s' "$DB_SVC_LINE" | awk '{print $1}')
  DB_SVC_NAME=$(printf '%s' "$DB_SVC_LINE" | awk '{print $2}')
  DETECTED_DB_HOST="${DB_SVC_NAME}.${DB_SVC_NS}.svc.cluster.local"
  printf '    host: %s\n' "$DETECTED_DB_HOST"
else
  printf '    warn: DB service not found, using DB_HOST from config\n'
fi

if [ -n "$DB_POD_LINE" ]; then
  DB_NS=$(printf '%s' "$DB_POD_LINE" | awk '{print $1}')
  DB_POD=$(printf '%s' "$DB_POD_LINE" | awk '{print $2}')
else
  printf '    warn: DB pod not found, skipping order cleanup\n'
fi

DB_HOST="${DUNE_DB_HOST:-${DETECTED_DB_HOST:-$(manifest_value DB_HOST)}}"
DB_PORT="${DUNE_DB_PORT:-${DETECTED_DB_PORT:-$(manifest_value DB_PORT)}}"
DB_USER="${DUNE_DB_USER:-$(manifest_value DB_USER)}"
DB_PASS="${DUNE_DB_PASS:-$(manifest_value DB_PASS)}"
DB_NAME="$(manifest_value DB_NAME)"

[ -n "$DB_PORT" ] || DB_PORT="15432"
[ -n "$DB_NAME" ] || DB_NAME="dune"

if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  printf 'error: could not detect complete DB credentials. Run ./deploy.sh --setup\n' >&2
  exit 1
fi

printf '    user: %s\n' "$DB_USER"
printf '    database: %s\n' "$DB_NAME"
printf '    port: %s\n' "$DB_PORT"
printf '    password: detected\n'

# ── Drop existing bot orders ──────────────────────────────────────────────────
printf '==> Dropping existing bot orders...\n'
if [ -n "$DB_NS" ] && [ -n "$DB_POD" ]; then
  DB_PASS_Q=$(shell_quote "$DB_PASS")
  DB_USER_Q=$(shell_quote "$DB_USER")
  DB_PORT_Q=$(shell_quote "$DB_PORT")
  DB_NAME_Q=$(shell_quote "$DB_NAME")
  printf '%s' "
WITH bot AS (SELECT id FROM dune.actors WHERE class = 'Revy' LIMIT 1),
del_orders AS (
  DELETE FROM dune.dune_exchange_orders
  WHERE owner_id = (SELECT id FROM bot) AND is_npc_order = TRUE
  RETURNING item_id
),
del_items AS (
  DELETE FROM dune.items
  WHERE id IN (SELECT item_id FROM del_orders WHERE item_id IS NOT NULL)
  RETURNING id
)
SELECT
  (SELECT COUNT(*) FROM del_orders) AS orders_deleted,
  (SELECT COUNT(*) FROM del_items)  AS items_deleted;
" | vm_ssh "sudo kubectl exec -n $DB_NS $DB_POD -i -- env PGPASSWORD=${DB_PASS_Q} psql -U ${DB_USER_Q} -h localhost -p ${DB_PORT_Q} -d ${DB_NAME_Q}"
else
  printf '    warn: DB pod not found, skipping order cleanup.\n'
fi

# ── Upload ────────────────────────────────────────────────────────────────────
printf '==> Uploading binary...\n'
vm_scp "${SCRIPT_DIR}/market-bot-linux" "${VM_USER}@${VM_IP}:/tmp/market-bot-new"
vm_ssh "sudo mv /tmp/market-bot-new ${REMOTE_DIR}/bin/market-bot && sudo chmod +x ${REMOTE_DIR}/bin/market-bot"

printf '==> Uploading item data...\n'
vm_scp "${SCRIPT_DIR}/item-data.json" "${VM_USER}@${VM_IP}:${REMOTE_DIR}/data/item-data.json"

# ── Apply k8s manifest ────────────────────────────────────────────────────────
printf '==> Applying k8s manifests...\n'
RENDERED_MANIFEST=$(mktemp)
trap 'rm -f "$RENDERED_MANIFEST"' EXIT
cp "$MANIFEST_PATH" "$RENDERED_MANIFEST"
set_manifest_value "$RENDERED_MANIFEST" DB_HOST "$DB_HOST"
set_manifest_value "$RENDERED_MANIFEST" DB_PORT "$DB_PORT"
set_manifest_value "$RENDERED_MANIFEST" DB_USER "$DB_USER"
set_manifest_value "$RENDERED_MANIFEST" DB_PASS "$DB_PASS"
set_manifest_value "$RENDERED_MANIFEST" DB_NAME "$DB_NAME"
vm_ssh "sudo kubectl apply -f -" < "$RENDERED_MANIFEST"

# ── Rollout ───────────────────────────────────────────────────────────────────
printf '==> Restarting deployment...\n'
vm_ssh "sudo kubectl rollout restart deployment/market-bot -n dune-market-bot"
vm_ssh "sudo kubectl rollout status deployment/market-bot -n dune-market-bot --timeout=90s" || true

printf '\n==> Logs:\n'
vm_ssh "sudo kubectl logs -n dune-market-bot -l app=market-bot --tail=40"
