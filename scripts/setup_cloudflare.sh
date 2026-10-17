#!/bin/bash
# Deploys the rendezvous relay (rendezvous/) to Cloudflare Workers from .env, with its secrets, then checks it.
# Before anything it makes sure wrangler is signed in to CLOUDFLARE_ACCOUNT_ID, never another account.
#
#   scripts/setup_cloudflare.sh             check the account, deploy, check the live relay
#   scripts/setup_cloudflare.sh --check     only the account and the live relay; changes nothing
#   scripts/setup_cloudflare.sh --no-turn   deploy without TURN on purpose (phones then connect directly only)
#
# .env: CLOUDFLARE_ACCOUNT_ID, PRIVA_RELAY_HOST, RELAY_PASS_SPKI (scripts/setup_supabase.sh prints it) and,
# optionally, CF_TURN_KEY_ID and CF_TURN_KEY_API_TOKEN.
set -u
source "$(dirname "$0")/env.sh"
load_env || exit 1
need CLOUDFLARE_ACCOUNT_ID PRIVA_RELAY_HOST RELAY_PASS_SPKI || exit 1
export CLOUDFLARE_ACCOUNT_ID
cd "$ROOT/rendezvous"
check_only=false; [ "${1:-}" = "--check" ] && check_only=true
no_turn=false; [ "${1:-}" = "--no-turn" ] && no_turn=true
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "Account"
who=$(npx --yes wrangler whoami 2>&1)
if ! grep -qi "logged in" <<<"$who"; then echo "  ✗ wrangler isn't signed in: npx wrangler login"; exit 1; fi
email=$(grep -oE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]+" <<<"$who" | head -1)
if ! grep -q "$CLOUDFLARE_ACCOUNT_ID" <<<"$who"; then
  echo "  ✗ wrangler is signed in as ${email:-?}, which can't use account $CLOUDFLARE_ACCOUNT_ID."
  echo "    npx wrangler logout && npx wrangler login, with the account that owns the relay."
  exit 1
fi
ok "signed in as ${email:-?}; deploying to account $CLOUDFLARE_ACCOUNT_ID"

if ! $check_only; then
  echo "Deploy"
  if [ -z "${CF_TURN_KEY_ID:-}" ] || [ -z "${CF_TURN_KEY_API_TOKEN:-}" ]; then
    # The app asks the relay for TURN once it has /turn and stops using the old Supabase function: deploying
    # without the keys would leave phones behind strict NATs (many carriers) unable to connect at all.
    if ! $no_turn; then
      echo "  ✗ CF_TURN_KEY_ID and CF_TURN_KEY_API_TOKEN aren't in .env (Cloudflare › Realtime › TURN)."
      echo "    Without them phones on strict carrier networks can't connect. Add them, or pass --no-turn on purpose."
      exit 1
    fi
    note "deploying without TURN (--no-turn): phones connect directly only"
  fi
  dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
  # Uploaded with the new version, so the relay is never without its key. Secrets left out are kept.
  {
    echo "RELAY_PASS_SPKI=$RELAY_PASS_SPKI"
    [ -n "${CF_TURN_KEY_ID:-}" ] && echo "CF_TURN_KEY_ID=$CF_TURN_KEY_ID"
    [ -n "${CF_TURN_KEY_API_TOKEN:-}" ] && echo "CF_TURN_KEY_API_TOKEN=$CF_TURN_KEY_API_TOKEN"
  } > "$dir/secrets.env"
  chmod 600 "$dir/secrets.env"
  npx wrangler deploy --secrets-file "$dir/secrets.env" || { echo "  ✗ deploy failed"; exit 1; }
  ok "deployed"
  sleep 3
fi

echo "Live relay (https://$PRIVA_RELAY_HOST)"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
send=$(code -X POST -H 'Content-Type: application/json' -d '{"messages":[]}' "https://$PRIVA_RELAY_HOST/send")
[ "$send" = 401 ] && ok "/send refuses a phone without a relay pass" || bad "/send without a pass answered $send (expected 401)"
connect=$(code --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" "https://$PRIVA_RELAY_HOST/connect?topic=i-$(openssl rand -hex 16)")
[ "$connect" = 401 ] && ok "/connect refuses a phone without a relay pass" || bad "/connect without a pass answered $connect (expected 401)"
turn=$(code -X POST "https://$PRIVA_RELAY_HOST/turn")
case "$turn" in
  401) ok "/turn needs a pass (RelayTests checks a real pass gets expiring credentials)" ;;
  404) bad "/turn is missing: this is the old Worker, run without --check to deploy" ;;
  *)   bad "/turn without a pass answered $turn" ;;
esac
[ "$(code "https://$PRIVA_RELAY_HOST/nothing")" = 404 ] && ok "nothing else is served" || bad "unexpected route answers"

echo
[ $fail -eq 0 ] && echo "The relay is set up." || { echo "$fail problem(s) above."; exit 1; }
