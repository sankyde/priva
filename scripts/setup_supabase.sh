#!/bin/bash
# Sets Priva up on Supabase from .env, the database (supabase/migrations), the four edge functions and Priva's
# settings, then checks the result and prints anything .env still needs (the key ids the app pins, the relay-pass
# key the relay needs). Safe to run again: migrations apply once, functions redeploy.
#
#   scripts/setup_supabase.sh           check the account, set up, check the result
#   scripts/setup_supabase.sh --check   only check (account, project, functions, keys, settings); changes nothing
#
# Needs: the Supabase CLI signed in (npx supabase login), psql for the settings (brew install libpq), and in .env:
# SUPABASE_PROJECT_REF, SUPABASE_DB_URL, PRIVA_SUPABASE_HOST, PRIVA_SUPABASE_PUBLISHABLE_KEY.
set -u
source "$(dirname "$0")/env.sh"
load_env || exit 1
need SUPABASE_PROJECT_REF PRIVA_SUPABASE_HOST PRIVA_SUPABASE_PUBLISHABLE_KEY || exit 1
cd "$ROOT"
check_only=false; [ "${1:-}" = "--check" ] && check_only=true
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; }
sb() { if command -v supabase >/dev/null; then supabase "$@"; else npx --yes supabase "$@"; fi; }
ref=$SUPABASE_PROJECT_REF
api="https://$PRIVA_SUPABASE_HOST"
functions=(directory issue-token register relay-pass)
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1', ''))" 2>/dev/null; }

echo "Account"
projects=$(sb projects list -o json 2>/dev/null)
if [ -z "$projects" ]; then echo "  ✗ the Supabase CLI isn't signed in: npx supabase login"; exit 1; fi
project=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1]); d=d.get('projects', d) if isinstance(d, dict) else d
p=[p for p in d if p.get('ref', p.get('id')) == sys.argv[2]]
print(f\"{p[0].get('name')} ({p[0].get('status')})\" if p else '')" "$projects" "$ref")
if [ -z "$project" ]; then
  echo "  ✗ this Supabase login can't see project $ref: sign in to the account that owns it (npx supabase login)"
  exit 1
fi
ok "signed in; project $ref is \"$project\""
[ "$PRIVA_SUPABASE_HOST" = "$ref.supabase.co" ] && ok "the app is configured for this project" \
  || bad "PRIVA_SUPABASE_HOST is $PRIVA_SUPABASE_HOST, not $ref.supabase.co: the app would talk to another project"

if ! $check_only; then
  need SUPABASE_DB_URL || exit 1
  echo "Database"
  sb db push --db-url "$SUPABASE_DB_URL" --include-all || { echo "  ✗ migrations failed"; exit 1; }
  ok "migrations applied"
  echo "Secrets"
  if [ -n "${PRIVA_DEV_PURCHASE_KEY:-}" ]; then
    dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
    echo "PRIVA_DEV_PURCHASE_KEY=$PRIVA_DEV_PURCHASE_KEY" > "$dir/secrets.env"; chmod 600 "$dir/secrets.env"
    sb secrets set --env-file "$dir/secrets.env" --project-ref "$ref" >/dev/null && ok "development-purchase key set" \
      || bad "couldn't set PRIVA_DEV_PURCHASE_KEY"
  else
    note "no PRIVA_DEV_PURCHASE_KEY in .env: the server will refuse every development purchase"
  fi
  echo "Functions"
  # The app calls them with the publishable key, which isn't a JWT: JWT verification stays off.
  sb functions deploy "${functions[@]}" --project-ref "$ref" --no-verify-jwt --use-api || { echo "  ✗ deploy failed"; exit 1; }
  ok "deployed: ${functions[*]}"
  echo "Settings"
  if command -v psql >/dev/null; then
    dev=${PRIVA_ALLOW_DEV_PURCHASES:-false}
    [ "$dev" = "true" ] || dev=false
    psql "$SUPABASE_DB_URL" -Atqc "update priva.app_config set value = '$dev'::jsonb where key = 'allow_dev_purchases'" >/dev/null \
      && ok "allow_dev_purchases = $dev" || bad "couldn't change allow_dev_purchases"
  else
    note "psql isn't installed: set allow_dev_purchases in the SQL editor (see PRIVA_ALLOW_DEV_PURCHASES in .env)"
  fi
fi

echo "Check"
live=$(sb functions list --project-ref "$ref" -o json 2>/dev/null)
slugs=" $(python3 -c "
import json,sys
fs=json.loads(sys.argv[1]); fs=fs if isinstance(fs, list) else fs.get('functions', [])
print(' '.join(f.get('slug', '') for f in fs if f.get('status') == 'ACTIVE'))" "$live" 2>/dev/null) "
for f in "${functions[@]}"; do
  [[ "$slugs" == *" $f "* ]] && ok "function $f is deployed" || bad "function $f is missing"
done
python3 -c "
import json,sys
fs=json.loads(sys.argv[1]); fs=fs if isinstance(fs, list) else fs.get('functions', [])
sys.exit(0 if any(f.get('verify_jwt') for f in fs if f.get('slug') in sys.argv[2:]) else 1)" "$live" "${functions[@]}" 2>/dev/null \
  && bad "a function verifies JWTs: the app's publishable key would be refused (redeploy with --no-verify-jwt)"
if [[ "$slugs" == *" turn "* ]]; then
  relay=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://${PRIVA_RELAY_HOST:-none}/turn")
  if [ "$relay" = 401 ]; then
    note "the old open turn function is still deployed (anyone can mint TURN credentials), and the relay now serves /turn"
    if ! $check_only && [ -t 0 ]; then
      read -r -p "    Delete functions/v1/turn now? [y/N] " yes
      [ "$yes" = y ] && sb functions delete turn --project-ref "$ref" && ok "turn deleted"
    else
      note "delete it: npx supabase functions delete turn --project-ref $ref"
    fi
  else
    note "the old turn function is still deployed: delete it once scripts/setup_cloudflare.sh has deployed the relay"
  fi
fi
secrets=$(sb secrets list --project-ref "$ref" -o json 2>/dev/null)
if [[ "$secrets" == *'"PRIVA_DEV_PURCHASE_KEY"'* ]]; then
  ok "the server has the development-purchase key"
else
  note "the server has no PRIVA_DEV_PURCHASE_KEY: development purchases are refused (or, before this version, open to anyone)"
fi
lookup=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$api/rest/v1/rpc/lookup_directory" -H "apikey: $PRIVA_SUPABASE_PUBLISHABLE_KEY" \
  -H 'Content-Type: application/json' -d "{\"p_commit\":\"$(openssl rand -hex 32)\"}")
[ "$lookup" = 200 ] && ok "the publishable key works (directory lookup)" || bad "a directory lookup with the publishable key answered $lookup"

token=$(curl -s -H "apikey: $PRIVA_SUPABASE_PUBLISHABLE_KEY" "$api/functions/v1/issue-token")
pass=$(curl -s -H "apikey: $PRIVA_SUPABASE_PUBLISHABLE_KEY" "$api/functions/v1/relay-pass")
token_id=$(field key_id <<<"$token"); pass_id=$(field key_id <<<"$pass"); pass_spki=$(field public_key <<<"$pass")
if [ -z "$token_id" ] || [ -z "$pass_id" ]; then
  bad "the functions don't answer with their keys yet"
else
  # Each may list the standby after the active one (scripts/standby_keys.sh): the server's key must be among them.
  inlist() { [[ ",$2," == *",$1,"* ]]; }
  inlist "$token_id" "${PRIVA_TOKEN_KEY_ID:-}" && ok "the app trusts issue-token's key" \
    || bad "the app doesn't trust issue-token's key: PRIVA_TOKEN_KEY_ID=$token_id in .env, then scripts/configure.sh"
  inlist "$pass_id" "${PRIVA_PASS_KEY_ID:-}" && ok "the app trusts relay-pass's key" \
    || bad "the app doesn't trust relay-pass's key: PRIVA_PASS_KEY_ID=$pass_id in .env, then scripts/configure.sh"
  inlist "$pass_spki" "${RELAY_PASS_SPKI:-}" && ok "the relay is set for relay-pass's key" \
    || bad "RELAY_PASS_SPKI doesn't include relay-pass's key ($pass_spki): fix .env, then scripts/setup_cloudflare.sh"
  [[ "${PRIVA_TOKEN_KEY_ID:-}" == *,* ]] && [[ "${PRIVA_PASS_KEY_ID:-}" == *,* ]] && ok "standby keys are pinned" \
    || note "no standby signing keys yet: scripts/standby_keys.sh (else losing or leaking a key needs an app update)"
fi
if [ -n "${SUPABASE_DB_URL:-}" ] && command -v psql >/dev/null; then
  dev=$(psql "$SUPABASE_DB_URL" -Atqc "select value from priva.app_config where key = 'allow_dev_purchases'" 2>/dev/null)
  bundle=$(psql "$SUPABASE_DB_URL" -Atqc "select value #>> '{}' from priva.app_config where key = 'bundle_id'" 2>/dev/null)
  [ "$dev" = false ] && ok "allow_dev_purchases is off" \
    || note "allow_dev_purchases is '$dev': development builds get usernames without buying. Off before release."
  [ -n "$bundle" ] && ok "purchases are checked against $bundle" || bad "no bundle_id setting"
else
  note "set SUPABASE_DB_URL and install psql to check allow_dev_purchases"
fi

echo
[ $fail -eq 0 ] && echo "Supabase is set up." || { echo "$fail problem(s) above."; exit 1; }
