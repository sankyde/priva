#!/bin/bash
# Pre-submission check for Priva (docs/LAUNCH_CHECKLIST.md). Exits non-zero while anything blocks an App Store
# submission. Server checks need the database URL (Supabase → Project Settings → Database → connection string):
#
#   SUPABASE_DB_URL='postgresql://…' scripts/launch_check.sh      (or set it in .env)
#
# It only reads; nothing is changed.
set -u
source "$(dirname "$0")/env.sh"
load_env || exit 1
cd "$ROOT"
fail=0; warn=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; warn=$((warn + 1)); }

echo "App"
email=$(sed -n 's/^ *PrivaSupportEmail: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)
[[ "$email" == *@*.* ]] && ok "support email: $email" || bad "PrivaSupportEmail is empty in project.yml (reports and support go nowhere)"
for f in Terms Privacy; do [ -s "Priva/Resources/Legal/$f.md" ] && ok "$f.md bundled" || bad "Priva/Resources/Legal/$f.md missing"; done
[ -s Priva/Resources/PrivacyInfo.xcprivacy ] && ok "privacy manifest" || bad "PrivacyInfo.xcprivacy missing"
# Apple refuses builds that use a "required reason" API without declaring why (ITMS-91053).
declared=$(plutil -extract NSPrivacyAccessedAPITypes json -o - Priva/Resources/PrivacyInfo.xcprivacy 2>/dev/null)
reason() {   # category, grep pattern, what it is
  if grep -rqE "$2" Priva --include='*.swift'; then
    [[ "$declared" == *"$1"* ]] && ok "privacy manifest declares $3" || bad "the code uses $3 but PrivacyInfo.xcprivacy doesn't declare $1"
  fi
}
reason NSPrivacyAccessedAPICategoryUserDefaults 'UserDefaults' "UserDefaults"
reason NSPrivacyAccessedAPICategoryFileTimestamp 'attributesOfItem|creationDate|modificationDate' "file timestamps"
reason NSPrivacyAccessedAPICategorySystemBootTime 'systemUptime|mach_absolute_time' "the system uptime"
reason NSPrivacyAccessedAPICategoryDiskSpace 'volumeAvailableCapacity|systemFreeSize' "free disk space"
[ -s Priva/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png ] && ok "app icon" || bad "app icon missing"
url="https://${PRIVA_SUPABASE_HOST:-}"
key=${PRIVA_SUPABASE_PUBLISHABLE_KEY:-}
# TURN credentials come from the relay Worker, behind a relay pass (audit SEC-05); the old open function must be gone.
old=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "apikey: $key" -H 'Content-Type: application/json' -d '{}' "$url/functions/v1/turn")
[ "$old" = 404 ] && ok "no open TURN function on Supabase" || bad "functions/v1/turn still answers $old: anyone can mint TURN credentials, scripts/setup_supabase.sh offers to delete it once the relay serves /turn"
relay_url="https://${PRIVA_RELAY_HOST:-}"
turn=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$relay_url/turn")
case "$turn" in
  401) ok "relay /turn needs a pass (RelayTests.testTheProjectRelayHandsOutExpiringCredentials checks it's configured)" ;;
  404) bad "the relay Worker has no /turn yet: scripts/setup_cloudflare.sh" ;;
  *)   bad "relay /turn answered $turn without a pass" ;;
esac
grep -q 'ITSAppUsesNonExemptEncryption: true' project.yml && note "uses non-exempt encryption: answer export compliance in App Store Connect and file the annual US self-classification report (docs/LAUNCH_CHECKLIST.md)"

bin=build/release/Build/Products/Release-iphoneos/Priva.app/Priva
if [ -f "$bin" ]; then
  hooks=$(strings "$bin" | grep -E 'PrivaReset|PrivaAutofill|PrivaIgnoreCapture|PrivaKeepPurchase|debugSet|SyntheticCapturer|priva\.debug\.pw|WireTap' | head -3)
  [ -z "$hooks" ] && ok "Release binary has no debug hooks" || bad "Release binary contains debug hooks: $hooks"
  devkey=$(plutil -extract PrivaDevPurchaseKey raw "$(dirname "$bin")/Info.plist" 2>/dev/null)
  [ -z "$devkey" ] && ok "Release build carries no development-purchase key" || bad "the Release Info.plist has PrivaDevPurchaseKey: anyone with the app could mint purchases"
else
  note "no Release device build yet: xcodebuild -workspace Priva.xcworkspace -scheme Priva -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/release CODE_SIGNING_ALLOWED=NO build"
fi

echo "Server"
if [ -n "${SUPABASE_DB_URL:-}" ] && command -v psql >/dev/null; then
  q() { psql "$SUPABASE_DB_URL" -Atqc "$1" 2>/dev/null; }
  dev=$(q "select value from priva.app_config where key = 'allow_dev_purchases'")
  [ "$dev" = "false" ] && ok "allow_dev_purchases is off" || bad "allow_dev_purchases is '$dev': anyone can mint free usernames (update priva.app_config set value = 'false' where key = 'allow_dev_purchases')"
  n=$(q "select count(*) from priva.purchases where environment <> 'Production'")
  [ "${n:-1}" = "0" ] && ok "no test purchases" || note "$n test purchases (Dev/Sandbox) still in priva.purchases: see LAUNCH_CHECKLIST 'Clean the test data'"
else
  note "set SUPABASE_DB_URL (and install psql) to check allow_dev_purchases and leftover test data"
fi

echo
if [ $fail -gt 0 ]; then echo "$fail blocker(s), $warn note(s): not ready to submit."; exit 1; fi
echo "No blockers ($warn note(s) to review)."
