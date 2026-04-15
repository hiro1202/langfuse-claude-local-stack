#!/usr/bin/env bash
# setup.sh — one-shot local setup for Langfuse + Claude Code glass-box stack.
# Idempotent: re-running is safe.

set -euo pipefail

log()  { echo "[setup] $*"; }
err()  { echo "[setup] error: $*" >&2; }
need() {
  command -v "$1" >/dev/null 2>&1 || { err "'$1' is required. Install: $2"; exit 1; }
}

need jq      "brew install jq / apt-get install jq"
need openssl "usually preinstalled; install via your package manager if missing"
need docker  "see https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || { err "'docker compose' (v2) is required."; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_DIR}/.env"
CRED_FILE="${REPO_DIR}/credentials.txt"
HOOK_CMD="${REPO_DIR}/hooks/send-to-langfuse.sh"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# --- 1. Generate .env ---
if [ -f "$ENV_FILE" ]; then
  log ".env already exists; keeping it."
else
  log "generating .env from .env.example"
  cp "${REPO_DIR}/.env.example" "$ENV_FILE"

  # Replace placeholders with random hex of matching length.
  gen_hex() { openssl rand -hex "$1"; }
  # macOS sed needs '' after -i; use a portable approach via awk.
  tmp="$(mktemp)"
  while IFS= read -r line; do
    while [[ "$line" == *"REPLACE_ME_HEX8"*  ]]; do line="${line/REPLACE_ME_HEX8/$(gen_hex 8)}";  done
    while [[ "$line" == *"REPLACE_ME_HEX16"* ]]; do line="${line/REPLACE_ME_HEX16/$(gen_hex 16)}"; done
    while [[ "$line" == *"REPLACE_ME_HEX32"* ]]; do line="${line/REPLACE_ME_HEX32/$(gen_hex 32)}"; done
    printf '%s\n' "$line" >> "$tmp"
  done < "$ENV_FILE"
  mv "$tmp" "$ENV_FILE"
fi

# --- 2. Write credentials.txt (re-derived from .env) ---
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

umask 077
cat > "$CRED_FILE" <<EOF
# Langfuse login & API keys — keep this file private (chmod 600, gitignored).
# Regenerate by deleting .env and credentials.txt, then re-running ./setup.sh.

Langfuse UI:        http://localhost:3050
Admin email:        ${LANGFUSE_INIT_USER_EMAIL}
Admin password:     ${LANGFUSE_INIT_USER_PASSWORD}

Langfuse API keys (used by the Claude Code hook):
  Public key: ${LANGFUSE_INIT_PROJECT_PUBLIC_KEY}
  Secret key: ${LANGFUSE_INIT_PROJECT_SECRET_KEY}

MinIO console:      http://localhost:9091  (user: minio / pass: ${MINIO_ROOT_PASSWORD})
EOF
chmod 600 "$CRED_FILE"
log "wrote ${CRED_FILE} (chmod 600)"

# --- 3. Make hook executable ---
chmod +x "$HOOK_CMD"

# --- 4. Register Stop hook in ~/.claude/settings.json (idempotent) ---
mkdir -p "$(dirname "$SETTINGS_FILE")"
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Back up before modifying, then merge using jq.
cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"

updated="$(jq --arg cmd "$HOOK_CMD" '
  # Ensure structure exists.
  .hooks //= {}
  | .hooks.Stop //= []
  # Remove any existing hook entry that points to this exact command.
  | .hooks.Stop |= map(
      .hooks = ((.hooks // []) | map(select(.command != $cmd)))
    )
  # Drop matcher groups that are now empty.
  | .hooks.Stop |= map(select((.hooks | length) > 0))
  # Append our entry.
  | .hooks.Stop += [{"matcher":"","hooks":[{"type":"command","command":$cmd}]}]
' "$SETTINGS_FILE")"

printf '%s\n' "$updated" > "$SETTINGS_FILE"
log "registered Stop hook in ${SETTINGS_FILE}"

# --- 5. Done ---
cat <<EOF

Setup complete.

Next steps:
  1. Start Langfuse:       docker compose up -d
  2. View login info:      cat ${CRED_FILE}
  3. Open Langfuse UI:     http://localhost:3050
  4. (Optional) verify:    DRY_RUN=1 claude   # prints hook payload to stderr, no send
  5. Normal use:           claude             # hook sends traces automatically

To uninstall, see README.md.
EOF
