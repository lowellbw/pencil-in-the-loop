#!/usr/bin/env bash
#
# Deploy the relay to Railway.
#
#   ./deploy-railway.sh
#
# Idempotent: run it again after a code change and it redeploys without
# touching the volume, the tokens or the project. Everything it needs that it
# cannot infer, it generates once and prints once.
#
# Requires `railway login` first — the CLI opens a browser, so it is the one
# step that cannot be scripted.

set -euo pipefail

cd "$(dirname "$0")"

PROJECT_NAME="${PENCIL_RAILWAY_PROJECT:-pencil-loop-relay}"
TOKEN_FILE="${PENCIL_TOKEN_FILE:-$HOME/.pencil-loop-relay-tokens}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v railway >/dev/null 2>&1 || {
  echo "railway CLI not found:  brew install railway"
  exit 1
}
railway whoami >/dev/null 2>&1 || {
  echo "Not logged in. Run:  railway login"
  exit 1
}

# ── tokens ──────────────────────────────────────────────────────────────────
# Generated once and kept outside the repo. The device token goes into the
# iPad's Settings; the MCP token goes into the Claude clients. Two of them so
# revoking one does not revoke the other.
if [ ! -f "$TOKEN_FILE" ]; then
  say "Generating tokens → $TOKEN_FILE"
  umask 077
  {
    echo "PENCIL_DEVICE_TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
    echo "PENCIL_MCP_TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  } > "$TOKEN_FILE"
fi
# shellcheck disable=SC1090
. "$TOKEN_FILE"

# ── project ─────────────────────────────────────────────────────────────────
if ! railway status >/dev/null 2>&1; then
  say "Creating the project"
  railway init --name "$PROJECT_NAME"
fi

say "Linked project"
railway status | sed 's/^/  /'

# ── volume ──────────────────────────────────────────────────────────────────
# The sync root. Everything the relay is holding for you lives here, and it is
# the one thing a redeploy must never disturb.
if ! railway volume list 2>/dev/null | grep -q '/data'; then
  say "Adding the volume at /data"
  railway volume add --mount-path /data || {
    echo "  Could not add the volume automatically."
    echo "  Add one in the dashboard, mounted at /data, then run this again."
  }
fi

# ── configuration ───────────────────────────────────────────────────────────
say "Setting variables"
railway variables \
  --set "PENCIL_SYNC_ROOT=/data" \
  --set "PENCIL_DEVICE_TOKEN=$PENCIL_DEVICE_TOKEN" \
  --set "PENCIL_MCP_TOKEN=$PENCIL_MCP_TOKEN" \
  --skip-deploys >/dev/null
echo "  ok"

# ── deploy ──────────────────────────────────────────────────────────────────
say "Deploying"
railway up --detach

say "Waiting for the health check"
DOMAIN="$(railway domain 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$DOMAIN" ]; then
  echo "  No public domain yet. Generating one."
  DOMAIN="$(railway domain 2>&1 | tr -d '[:space:]' || true)"
fi
DOMAIN="${DOMAIN#https://}"

for _ in $(seq 1 40); do
  if curl -fsS "https://$DOMAIN/healthz" >/dev/null 2>&1; then
    say "Live"
    curl -sS "https://$DOMAIN/healthz" | sed 's/^/  /'
    echo
    cat <<INFO

  Relay      https://$DOMAIN

  iPad       Settings → Sync → Server
             URL      https://$DOMAIN
             Token    $PENCIL_DEVICE_TOKEN

  Claude Code
             claude mcp add --transport http pencil-loop \\
               https://$DOMAIN/mcp/ \\
               --header "Authorization: Bearer $PENCIL_MCP_TOKEN"

  Claude Desktop — add a custom connector with this URL, which carries the
  token in its path because the connector UI takes a URL and not a header:
             https://$DOMAIN/mcp/$PENCIL_MCP_TOKEN/

  Tokens are in $TOKEN_FILE. They are not in the repo and must not be.
INFO
    exit 0
  fi
  sleep 5
done

echo "  Health check did not come up. Logs:"
railway logs --lines 40 || true
exit 1
