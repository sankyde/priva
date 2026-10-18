#!/bin/bash
# Puts values into .env without opening it. Asks for each one; what you paste isn't shown or saved anywhere else.
#
#   scripts/set_env.sh CF_TURN_KEY_ID CF_TURN_KEY_API_TOKEN SUPABASE_DB_URL
set -euo pipefail
source "$(dirname "$0")/env.sh"
[ $# -gt 0 ] || { echo "Usage: scripts/set_env.sh KEY [KEY…]"; exit 1; }
[ -f "$ROOT/.env" ] || { echo "No .env yet: cp .env.example .env"; exit 1; }

for key in "$@"; do
  grep -q "^$key=" "$ROOT/.env" || { echo "  ✗ $key isn't in .env (check the spelling against .env.example)"; exit 1; }
  read -r -s -p "Paste $key, then Return: " value; echo
  value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || { echo "  ✗ nothing pasted: $key left as it was"; continue; }
  PRIVA_VALUE="$value" python3 - "$ROOT/.env" "$key" <<'PY'
import os, re, sys
path, key = sys.argv[1:]
s = open(path).read()
s, n = re.subn(rf'^{re.escape(key)}=.*$', lambda m: f'{key}={os.environ["PRIVA_VALUE"]}', s, flags=re.M)
if n != 1: sys.exit(f"{key} not found once in .env")
open(path, 'w').write(s)
PY
  echo "  ✓ $key saved (${#value} characters)"
done
chmod 600 "$ROOT/.env"
