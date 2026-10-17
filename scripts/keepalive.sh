#!/bin/bash
# Free Supabase projects pause after about a week without database activity. Before launch (when no real users
# generate lookups), run this once a day from any machine: cron, launchd or a CI schedule:
#   0 9 * * * /path/to/Priva/scripts/keepalive.sh
# It looks up a random username commitment (matches nothing, stores nothing).
set -eu
source "$(dirname "$0")/env.sh"
load_env
need PRIVA_SUPABASE_HOST PRIVA_SUPABASE_PUBLISHABLE_KEY
url="https://$PRIVA_SUPABASE_HOST"
key=$PRIVA_SUPABASE_PUBLISHABLE_KEY
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/rest/v1/rpc/lookup_directory" \
  -H "apikey: $key" -H 'Content-Type: application/json' -d "{\"p_commit\":\"$(openssl rand -hex 32)\"}")
[ "$code" = "200" ] && echo "ok" || { echo "lookup answered $code"; exit 1; }
