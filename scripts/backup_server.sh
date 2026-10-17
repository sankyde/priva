#!/bin/bash
# An encrypted copy of Priva's server data (docs/OPERATIONS.md § Backups): every table of the `priva` schema,
# signing keys and the purchase-hash secret (server_secrets), settings, the username directory, purchases, spent
# tokens, retired names, as JSON, encrypted with a passphrase you choose, into ~/Priva-server-backups/.
#
# The free Supabase plan keeps no backups. Lose the database and its signing keys go with it: new ones would be
# made, every installed app would refuse them, and sign-ups and relay passes would stop until an app update.
# Run this after setting up and then regularly (weekly; daily once there are users). Keep a copy offline.
#
#   scripts/backup_server.sh            needs SUPABASE_DB_URL in .env and psql (brew install libpq)
set -euo pipefail
source "$(dirname "$0")/env.sh"
load_env
need SUPABASE_DB_URL
command -v psql >/dev/null || { echo "Needs psql: brew install libpq"; exit 1; }
out_dir=${PRIVA_BACKUP_DIR:-$HOME/Priva-server-backups}
mkdir -p "$out_dir"; chmod 700 "$out_dir"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

tables=$(psql "$SUPABASE_DB_URL" -Atqc "select tablename from pg_tables where schemaname = 'priva' order by 1")
[ -n "$tables" ] || { echo "No priva tables found: wrong database?"; exit 1; }
for t in $tables; do
  psql "$SUPABASE_DB_URL" -Atqc "select coalesce(json_agg(x), '[]'::json) from priva.$t x" > "$tmp/$t.json"
  echo "  $t: $(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$tmp/$t.json") rows"
done
psql "$SUPABASE_DB_URL" -Atqc "select version from supabase_migrations.schema_migrations order by 1" > "$tmp/migrations.txt" 2>/dev/null || true
date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp/made.txt"

file="$out_dir/priva-server-$(date +%Y%m%d-%H%M%S).tar.gz.enc"
echo "▸ encrypting: choose a passphrase (keep it with your other Priva secrets)"
tar -C "$tmp" -czf - . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -out "$file"
chmod 600 "$file"
echo "Backup: $file"
echo "Open it with: openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in \"$file\" | tar -xzf - -C <folder>"
