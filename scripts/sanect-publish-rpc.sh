#!/bin/bash
# sanect-publish-rpc — interactive wizard to expose a sanect node's RPC publicly.
#
# What it does:
#   1. Asks: own domain OR free community subdomain
#   2. Own domain path:
#      - Prompts for domain
#      - Shows the A record to add
#      - Waits for DNS to propagate (polls dig)
#      - Installs Caddy if missing, configures reverse proxy + auto-TLS
#      - Updates /etc/sanect/node.env with PUBLIC_RPC_URL
#      - Restarts the container with port 8080 publicly exposed
#      - Pings the explorer to register the heartbeat
#   3. Free subdomain path:
#      - Asks for desired subdomain
#      - Checks availability via explorer API
#      - Uses the server's public IP as PUBLIC_RPC_URL
#      - Restarts container, waits for heartbeat verification
#      - Submits subdomain claim to the explorer
#   4. Prints the final URL to share with users.
#
# Re-runnable: if a previous run already configured something, the script
# detects the existing state and prompts to update vs keep.
#
# Requirements: bash, curl, jq, dig (dnsutils), docker, ufw (optional).

set -euo pipefail

# ---------- config ----------
ENV_FILE="${ENV_FILE:-/etc/sanect/node.env}"
EXPLORER_URL="${EXPLORER_URL:-https://scan.testnet.sanect.com}"
CONTAINER_NAME="${CONTAINER_NAME:-sanect-node}"
NODE_RPC_PORT="${NODE_RPC_PORT:-8080}"
CADDY_FILE="${CADDY_FILE:-/etc/caddy/Caddyfile}"

# Colours (skip if NO_COLOR set or non-tty).
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_RESET=""
fi

say()  { printf "%s\n" "$*"; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf "%sERROR:%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
title(){ printf "\n%s── %s ──%s\n" "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

# ---------- preflight ----------
title "Sanect public RPC setup wizard"

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root (needed for env file, Caddy install, ufw, docker restart)"
fi

for tool in curl jq docker; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

if [ ! -f "$ENV_FILE" ]; then
  die "no env file at $ENV_FILE — set ENV_FILE or follow the Ubuntu setup guide first"
fi

# Public IP detection (used for own-domain DNS hint + subdomain fallback URL).
PUBLIC_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -sf --max-time 5 https://ipinfo.io/ip 2>/dev/null || \
            curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
if [ -z "$PUBLIC_IP" ]; then
  warn "Couldn't auto-detect public IP — you'll have to enter it manually."
else
  ok "Detected public IP: $PUBLIC_IP"
fi

# Get the node's CometBFT id (needed for explorer registration).
NODE_ID=""
get_node_id() {
  NODE_ID=$(docker exec "$CONTAINER_NAME" sanectd cometbft show-node-id \
    --home /data/.sanectd 2>/dev/null || echo "")
}
get_node_id
if [ -z "$NODE_ID" ]; then
  warn "Couldn't fetch node_id (container may be down). Trying RPC..."
  NODE_ID=$(curl -sf --max-time 3 "localhost:$NODE_RPC_PORT/rpc/status" 2>/dev/null \
            | jq -r '.result.node_info.id // ""')
fi
[ -z "$NODE_ID" ] && die "Couldn't get this node's id — make sure container '$CONTAINER_NAME' is running"
ok "Node id: $NODE_ID"

# ---------- helpers ----------
update_env_var() {
  local key="$1" value="$2"
  # Remove existing line if present.
  sed -i "/^${key}=/d" "$ENV_FILE"
  echo "${key}=${value}" >> "$ENV_FILE"
}

reload_container() {
  say "Restarting $CONTAINER_NAME so new env takes effect..."
  docker restart "$CONTAINER_NAME" >/dev/null
  ok "Container restarted"
}

ensure_caddy() {
  if command -v caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
    ok "Caddy already running"
    return
  fi
  say "Installing Caddy (handles TLS via Let's Encrypt automatically)..."
  apt-get update -qq
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
  systemctl enable --now caddy
  ok "Caddy installed"
}

ensure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then return; fi
  say "Opening firewall ports..."
  ufw allow 80/tcp  >/dev/null 2>&1 || true   # ACME HTTP-01 challenge
  ufw allow 443/tcp >/dev/null 2>&1 || true   # HTTPS
  ufw allow "$NODE_RPC_PORT/tcp" >/dev/null 2>&1 || true
  ok "Ports 80, 443, $NODE_RPC_PORT open"
}

verify_explorer_sees_us() {
  local want_url="$1"
  say "Waiting for explorer to verify the heartbeat (this takes up to 90s)..."
  for i in 1 2 3 4 5 6; do
    sleep 15
    local STATUS
    STATUS=$(curl -sf --max-time 10 "$EXPLORER_URL/api/network/nodes" 2>/dev/null \
             | jq -r ".nodes[] | select(.url == \"$want_url\") | .reachable" | head -1)
    if [ "$STATUS" = "true" ]; then
      ok "Explorer verified your node — listing publicly"
      return 0
    fi
    say "  attempt $i/6: not yet visible, retrying..."
  done
  warn "Explorer didn't verify within 90s. Heartbeat may still land — check $EXPLORER_URL/network/nodes in a few minutes."
  return 1
}

# ---------- main menu ----------
title "How do you want to publish?"
say "  1) Use your own domain (e.g., rpc.myvalidator.com)"
say "     — You set the DNS, this script handles Caddy + TLS for you."
say ""
say "  2) Get a free community subdomain"
say "     — Pick a name. Get https://YOUR-NAME.testnet.sanect.org."
say "       No DNS or TLS setup needed; the explorer proxies the traffic."
say ""
read -r -p "Choice (1/2): " CHOICE
case "$CHOICE" in
  1|2) ;;
  *) die "invalid choice" ;;
esac

# Always set the explorer heartbeat (used in both branches).
update_env_var "EXPLORER_HEARTBEAT_URL" "$EXPLORER_URL/api/network/heartbeat"

# ===================================================================
#                          BRANCH 1: own domain
# ===================================================================
if [ "$CHOICE" = "1" ]; then
  title "Configure your own domain"
  read -r -p "Enter the full domain (e.g., rpc.myvalidator.com): " DOMAIN
  [ -z "$DOMAIN" ] && die "domain required"

  title "Step 1 of 4: DNS"
  if [ -n "$PUBLIC_IP" ]; then
    say "Add this DNS record at your registrar (or Cloudflare, Namecheap, etc.):"
    say ""
    say "  ${C_BOLD}Type:${C_RESET}  A"
    say "  ${C_BOLD}Name:${C_RESET}  $DOMAIN     (or just the subdomain part)"
    say "  ${C_BOLD}Value:${C_RESET} $PUBLIC_IP"
    say "  ${C_BOLD}TTL:${C_RESET}   Auto (or 300)"
  fi
  say ""
  say "If you're using Cloudflare with the orange-cloud proxy, set the proxy"
  say "to DNS-only (grey cloud) so Caddy can issue a real cert via ACME."
  say ""
  read -r -p "Press ENTER once the DNS record is added, then we'll verify..." _

  title "Step 2 of 4: verify DNS"
  if ! command -v dig >/dev/null 2>&1; then
    apt-get install -y -qq dnsutils
  fi
  ATTEMPTS=0
  while true; do
    ATTEMPTS=$((ATTEMPTS + 1))
    RESOLVED=$(dig +short "$DOMAIN" A | head -1)
    if [ "$RESOLVED" = "$PUBLIC_IP" ]; then
      ok "DNS resolves correctly: $DOMAIN → $RESOLVED"
      break
    fi
    if [ "$ATTEMPTS" -ge 30 ]; then
      die "DNS still not resolving to $PUBLIC_IP after 30 attempts (got '$RESOLVED'). Wait 5-30 min for propagation, then re-run this script."
    fi
    say "  $DOMAIN → '$RESOLVED' (want $PUBLIC_IP) — waiting 10s..."
    sleep 10
  done

  title "Step 3 of 4: Caddy + TLS"
  ensure_firewall
  ensure_caddy
  # Atomic Caddyfile rewrite — preserve existing blocks for other sites.
  TMP=$(mktemp)
  # Strip any existing block for this exact domain (idempotent).
  awk -v dom="$DOMAIN" '
    BEGIN { skip = 0 }
    $0 ~ "^"dom" " || $0 == dom" {" { skip = 1; next }
    skip && /^}/ { skip = 0; next }
    !skip { print }
  ' "$CADDY_FILE" 2>/dev/null > "$TMP" || true
  cat >> "$TMP" <<EOF

$DOMAIN {
    reverse_proxy localhost:$NODE_RPC_PORT
    encode gzip
    log {
        output file /var/log/caddy/$DOMAIN.log
    }
}
EOF
  mv "$TMP" "$CADDY_FILE"
  systemctl reload caddy || die "Caddy reload failed — check /var/log/caddy/"
  ok "Caddy serving https://$DOMAIN → localhost:$NODE_RPC_PORT"
  say ""
  say "Caddy is fetching a Let's Encrypt cert in the background. First request"
  say "after this might take 5-15 seconds while ACME completes."

  title "Step 4 of 4: tell the explorer"
  PUBLIC_RPC="https://$DOMAIN"
  update_env_var "PUBLIC_RPC_URL" "$PUBLIC_RPC"
  reload_container

  if verify_explorer_sees_us "$PUBLIC_RPC"; then :; else true; fi

  title "Done"
  ok "Your public RPC URL is ${C_BOLD}$PUBLIC_RPC${C_RESET}"
  say ""
  say "Test it from your laptop:"
  say "  ${C_DIM}curl -s $PUBLIC_RPC/rpc/status | jq .result.sync_info${C_RESET}"
  say ""
  say "View on the explorer dashboard:"
  say "  ${C_DIM}$EXPLORER_URL/network/nodes${C_RESET}"
  exit 0
fi

# ===================================================================
#                       BRANCH 2: free subdomain
# ===================================================================
title "Get a free community subdomain"

# Fetch the configured subdomain base.
SUB_BASE=$(curl -sf --max-time 5 "$EXPLORER_URL/api/network/config" 2>/dev/null \
           | jq -r '.subdomainBase // "community-rpc.sanect.org"')
ok "Subdomain base: .$SUB_BASE"

while true; do
  read -r -p "Choose a subdomain (3-32 chars, a-z 0-9 -): " SUB
  if [[ ! "$SUB" =~ ^[a-z0-9]([a-z0-9-]{1,30}[a-z0-9])?$ ]]; then
    warn "Invalid format. Must be 3-32 lowercase chars, alphanumeric + hyphens, no leading/trailing hyphen."
    continue
  fi
  EXISTS=$(curl -sf --max-time 5 "$EXPLORER_URL/api/network/subdomains" 2>/dev/null \
           | jq -r ".items[] | select(.subdomain == \"$SUB\") | .nodeId")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "$NODE_ID" ]; then
    warn "'$SUB' is already taken by another node. Try a different name."
    continue
  fi
  ok "'$SUB.$SUB_BASE' is available"
  break
done

# Determine the URL the heartbeat advertises. Default: server's public IP
# on port 8080. Operator can override (e.g., they already have their own
# proxy on a different port).
title "Step 1 of 3: how should the explorer's proxy reach your node?"
DEFAULT_RPC="http://$PUBLIC_IP:$NODE_RPC_PORT"
say "Default: $DEFAULT_RPC"
say "(Press ENTER to accept, or type a different URL if you already have a reverse proxy.)"
read -r -p "URL: " OPERATOR_RPC
OPERATOR_RPC="${OPERATOR_RPC:-$DEFAULT_RPC}"
update_env_var "PUBLIC_RPC_URL" "$OPERATOR_RPC"

title "Step 2 of 3: firewall + restart"
ensure_firewall
reload_container

# Wait for the heartbeat to land and verify.
verify_explorer_sees_us "$OPERATOR_RPC" || \
  die "Couldn't verify your URL is publicly reachable. Check that port $NODE_RPC_PORT is open and your VPS firewall allows inbound traffic."

title "Step 3 of 3: claim the subdomain"
# Read the claim_token (generated by the entrypoint on first boot,
# chmod 600). Authenticates this claim — backend rejects with 401
# without it.
#
# Try the in-container path first via docker exec — works regardless
# of whether the operator uses a bind mount or a Docker-managed named
# volume. Fall back to the host path for setups that bind-mount /data.
CLAIM_TOKEN=""
if docker exec "$CONTAINER_NAME" test -f /data/.sanectd/config/claim-token 2>/dev/null; then
  CLAIM_TOKEN=$(docker exec "$CONTAINER_NAME" cat /data/.sanectd/config/claim-token 2>/dev/null || echo "")
elif [ -f "/data/.sanectd/config/claim-token" ]; then
  CLAIM_TOKEN=$(cat "/data/.sanectd/config/claim-token")
fi
if [ -z "$CLAIM_TOKEN" ]; then
  say "claim_token not found. Possible causes:"
  say "  - Your node is running an older image without the claim_token feature."
  say "    Pull the latest sanect image and recreate the container."
  say "  - The entrypoint hasn't finished first-boot yet. Wait 30s, re-run."
  say ""
  say "To inspect manually:"
  say "  ${C_DIM}docker exec $CONTAINER_NAME ls -la /data/.sanectd/config/claim-token${C_RESET}"
  die "claim_token missing"
fi
RESP=$(curl -sf --max-time 10 -X POST "$EXPLORER_URL/api/network/claim-subdomain" \
  -H 'content-type: application/json' \
  -d "{\"subdomain\":\"$SUB\",\"node_id\":\"$NODE_ID\",\"claim_token\":\"$CLAIM_TOKEN\"}")
if [ -z "$RESP" ]; then
  die "claim request failed — check $EXPLORER_URL connectivity"
fi
OK=$(echo "$RESP" | jq -r '.ok // false')
if [ "$OK" != "true" ]; then
  ERR=$(echo "$RESP" | jq -r '.error // "unknown error"')
  die "claim failed: $ERR"
fi

PATH_URL=$(echo "$RESP" | jq -r '.pathUrl')
SUB_URL=$(echo "$RESP" | jq -r '.subdomainUrl')

title "Done"
ok "Your public RPC URLs:"
say ""
say "  ${C_BOLD}Subdomain URL (recommended):${C_RESET}"
say "    ${C_GREEN}$SUB_URL${C_RESET}"
say ""
say "  ${C_BOLD}Path URL (always works, no DNS dependency):${C_RESET}"
say "    ${C_GREEN}$PATH_URL${C_RESET}"
say ""
say "Test it from your laptop:"
say "  ${C_DIM}curl -s $PATH_URL/rpc/status | jq .result.sync_info${C_RESET}"
say ""
say "View on the explorer dashboard:"
say "  ${C_DIM}$EXPLORER_URL/network/nodes${C_RESET}"
