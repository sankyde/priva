#!/bin/bash
# Makes Priva's standby signing keys (docs/OPERATIONS.md § Switching signing keys) and pins them, so the server can
# switch keys, one lost with the database, or leaked, without an app update:
#   1. makes a registration-token key and a relay-pass key, as the server makes its own;
#   2. encrypts their private halves with a passphrase you choose into ~/Priva-server-backups/ (keep a copy offline:
#      a password manager or a USB stick; never in the repository);
#   3. adds their public ids to .env after the active ones (PRIVA_TOKEN_KEY_ID, PRIVA_PASS_KEY_ID, RELAY_PASS_SPKI).
# Then: scripts/configure.sh, a new app build, and scripts/setup_cloudflare.sh (the relay accepts both).
# Run once. Running it again makes another pair (the previous standby is then dropped from .env).
set -euo pipefail
source "$(dirname "$0")/env.sh"
load_env
need PRIVA_TOKEN_KEY_ID PRIVA_PASS_KEY_ID RELAY_PASS_SPKI
command -v deno >/dev/null || { echo "Needs Deno: brew install deno"; exit 1; }
out_dir=${PRIVA_BACKUP_DIR:-$HOME/Priva-server-backups}
mkdir -p "$out_dir"; chmod 700 "$out_dir"
file="$out_dir/standby-keys-$(date +%Y%m%d-%H%M%S).json.enc"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "▸ making the standby keys (a few seconds)"
deno run --quiet "$ROOT/scripts/standby_keys.ts" > "$tmp/keys.json" 2> "$tmp/public.txt"
echo "▸ encrypting the private halves: choose a passphrase (you'll need it to switch keys)"
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$tmp/keys.json" -out "$file"
chmod 600 "$file"

token_id=$(awk '$1=="TOKEN_KEY_ID"{print $2}' "$tmp/public.txt")
pass_id=$(awk '$1=="PASS_KEY_ID"{print $2}' "$tmp/public.txt")
pass_spki=$(awk '$1=="PASS_SPKI"{print $2}' "$tmp/public.txt")
active_token=${PRIVA_TOKEN_KEY_ID%%,*}; active_pass=${PRIVA_PASS_KEY_ID%%,*}; active_spki=${RELAY_PASS_SPKI%%,*}
set_env() {   # KEY value: replaces the line in .env
  python3 - "$ROOT/.env" "$1" "$2" <<'PY'
import sys, re
path, key, value = sys.argv[1:]
s = open(path).read()
s, n = re.subn(rf'^{re.escape(key)}=.*$', f'{key}={value}', s, flags=re.M)
if n != 1: sys.exit(f"{key} not found once in .env")
open(path, 'w').write(s)
PY
}
set_env PRIVA_TOKEN_KEY_ID "$active_token,$token_id"
set_env PRIVA_PASS_KEY_ID "$active_pass,$pass_id"
set_env RELAY_PASS_SPKI "$active_spki,$pass_spki"
echo
echo "Standby keys made."
echo "  private halves (encrypted): $file, keep a copy offline"
echo "  pinned in .env: token $token_id"
echo "                  pass  $pass_id"
echo "Next: scripts/configure.sh, a new build of the app, and scripts/setup_cloudflare.sh."
