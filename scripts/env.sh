# Sourced by the other scripts: loads .env (KEY=value lines, # comments) without executing it.
# A variable already set in the environment wins over the file (handy for CI).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  local file="${1:-$ROOT/.env}" line k v
  if [ ! -f "$file" ]; then
    echo "No .env yet: cp .env.example .env and fill it in (see the comments there)." >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      echo ".env: not a KEY=value line: ${line%%=*}…" >&2
      return 1
    fi
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
    [ -z "${!k+x}" ] && export "$k=$v"
  done < "$file"
  return 0
}

# need KEY…: every one must be set (in .env or the environment).
need() {
  local k missing=()
  for k; do [ -n "${!k:-}" ] || missing+=("$k"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "Set in .env: ${missing[*]}" >&2
  return 1
}
