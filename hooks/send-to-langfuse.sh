#!/usr/bin/env bash
# Claude Code Stop hook -> Langfuse ingestion.
# bash + curl + jq only. fail-open. DRY_RUN=1 prints payload to stderr without sending.
# All stderr lines prefixed with [langfuse-hook] for easy grep.

set -euo pipefail

log() { echo "[langfuse-hook] $*" >&2; }

# Dependencies. Missing deps are non-fatal (fail-open).
command -v jq   >/dev/null 2>&1 || { log "jq not found; skipping.";   exit 0; }
command -v curl >/dev/null 2>&1 || { log "curl not found; skipping."; exit 0; }

# Load .env from repo root (one level up from hooks/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

LANGFUSE_URL="${LANGFUSE_BASE_URL:-http://127.0.0.1:3050}"
PUBLIC_KEY="${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:-}"
SECRET_KEY="${LANGFUSE_INIT_PROJECT_SECRET_KEY:-}"
if [ -z "$PUBLIC_KEY" ] || [ -z "$SECRET_KEY" ]; then
  log "LANGFUSE_INIT_PROJECT_*_KEY not set; run ./setup.sh first."
  exit 0
fi

# Read Claude Code stdin JSON.
STDIN="$(cat)"
[ -z "$STDIN" ] && exit 0

SESSION_ID="$(printf '%s' "$STDIN" | jq -r '.session_id // empty' 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$STDIN" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
CWD="$(printf       '%s' "$STDIN" | jq -r '.cwd // empty'            2>/dev/null || true)"
STOP_ACTIVE="$(printf '%s' "$STDIN" | jq -r '.stop_hook_active // false' 2>/dev/null || true)"

# Prevent infinite loop if Claude Code re-triggers Stop after our action.
[ "$STOP_ACTIVE" = "true" ] && exit 0

if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  log "missing session_id or transcript; skipping."
  exit 0
fi

# Extract last user text + last assistant text from transcript JSONL.
# Transcript events look like: {"type":"user","message":{"content":"..."}} or content:[{type:"text",text:"..."}]
USER_INPUT="$(jq -r -s '
  [ .[] | select(.type == "user")
    | (.message.content // "") as $c
    | if ($c | type) == "string" then $c
      elif ($c | type) == "array" then ($c | [.[] | select(.type=="text") | .text] | join("\n"))
      else "" end
  ] | map(select(. != "" and . != null)) | last // ""
' "$TRANSCRIPT" 2>/dev/null || true)"

ASSISTANT_OUTPUT="$(jq -r -s '
  [ .[] | select(.type == "assistant")
    | (.message.content // []) as $c
    | if ($c | type) == "array" then ($c | [.[] | select(.type=="text") | .text] | join("\n"))
      elif ($c | type) == "string" then $c
      else "" end
  ] | map(select(. != "" and . != null)) | last // ""
' "$TRANSCRIPT" 2>/dev/null || true)"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EVENT_ID="$(openssl rand -hex 16)"
TRACE_ID="$(openssl rand -hex 16)"

PAYLOAD="$(jq -n \
  --arg eid    "$EVENT_ID" \
  --arg ts     "$TS" \
  --arg tid    "$TRACE_ID" \
  --arg sid    "$SESSION_ID" \
  --arg cwd    "$CWD" \
  --arg input  "$USER_INPUT" \
  --arg output "$ASSISTANT_OUTPUT" \
  '{batch:[{id:$eid,timestamp:$ts,type:"trace-create",body:{
      id:$tid,name:"claude-code-session",sessionId:$sid,
      input:$input,output:$output,
      metadata:{cwd:$cwd,source:"glass-box-hook"}
  }}]}'
)"

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN=1 — payload follows (not sent):"
  printf '%s\n' "$PAYLOAD" | jq . >&2
  exit 0
fi

HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  --max-time 5 \
  -u "${PUBLIC_KEY}:${SECRET_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST --data "$PAYLOAD" \
  "${LANGFUSE_URL}/api/public/ingestion" 2>/dev/null || echo "000")"

case "$HTTP_CODE" in
  200|201|207) log "sent trace for session ${SESSION_ID} (HTTP ${HTTP_CODE})" ;;
  *)           log "send failed (HTTP ${HTTP_CODE}); ignoring (fail-open)." ;;
esac

exit 0
