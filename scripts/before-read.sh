#!/bin/bash
# Ralph Wiggum: Before Read File Hook
# Tracks context allocations to prevent redlining

set -euo pipefail

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract file info - Cursor may send different field names
# Try multiple possible field names
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // .path // ""')
CONTENT=$(echo "$HOOK_INPUT" | jq -r '.content // .file_content // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
CONTEXT_LOG="$RALPH_DIR/context-log.md"

# If Ralph isn't active, pass through
if [[ ! -d "$RALPH_DIR" ]]; then
  echo '{"continue": true, "permission": "allow"}'
  exit 0
fi

# Estimate token count
# If content is provided, use it; otherwise estimate from file size
if [[ -n "$CONTENT" ]]; then
  CONTENT_LENGTH=${#CONTENT}
  ESTIMATED_TOKENS=$((CONTENT_LENGTH / 4))
elif [[ -f "$FILE_PATH" ]]; then
  # Fall back to reading file size
  FILE_SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null || echo "0")
  ESTIMATED_TOKENS=$((FILE_SIZE / 4))
else
  ESTIMATED_TOKENS=100  # Default estimate
fi

# Log the file read
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Append to context log (in the table)
if [[ -f "$CONTEXT_LOG" ]]; then
  # Read current allocated tokens (cross-platform grep)
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
  NEW_ALLOCATED=$((CURRENT_ALLOCATED + ESTIMATED_TOKENS))
  
  # Update the allocated count
  sedi "s/Allocated: [0-9]* tokens/Allocated: $NEW_ALLOCATED tokens/" "$CONTEXT_LOG"
  
  # Determine status
  THRESHOLD=80000
  WARN_THRESHOLD=$((THRESHOLD * 80 / 100))
  CRITICAL_THRESHOLD=$((THRESHOLD * 95 / 100))
  
  if [[ "$NEW_ALLOCATED" -gt "$CRITICAL_THRESHOLD" ]]; then
    STATUS="🔴 Critical - Start fresh!"
    sedi "s/Status: .*/Status: $STATUS/" "$CONTEXT_LOG"
  elif [[ "$NEW_ALLOCATED" -gt "$WARN_THRESHOLD" ]]; then
    STATUS="🟡 Warning - Approaching limit"
    sedi "s/Status: .*/Status: $STATUS/" "$CONTEXT_LOG"
  fi
  
  # Log this file (append before the Estimated Context Usage section)
  TEMP_FILE=$(mktemp)
  awk -v file="$FILE_PATH" -v tokens="$ESTIMATED_TOKENS" -v ts="$TIMESTAMP" '
    /^## Estimated Context Usage/ {
      print "| " file " | " tokens " | " ts " |"
      print ""
    }
    { print }
  ' "$CONTEXT_LOG" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$CONTEXT_LOG"
fi

# Check if we should warn about context
THRESHOLD=80000
CRITICAL_THRESHOLD=$((THRESHOLD * 95 / 100))

if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
  
  if [[ "$CURRENT_ALLOCATED" -gt "$CRITICAL_THRESHOLD" ]]; then
    # Context is critically full - warn but allow
    jq -n \
      --arg file "$FILE_PATH" \
      '{
        "continue": true,
        "permission": "allow",
        "userMessage": "⚠️ Ralph: Context is critically full. Consider starting a fresh conversation.",
        "agentMessage": "CONTEXT CRITICAL: You are approaching context limits. Wrap up current work, commit, and suggest starting fresh."
      }'
    exit 0
  fi
fi

# Normal case - allow the read
echo '{"continue": true, "permission": "allow"}'
exit 0
