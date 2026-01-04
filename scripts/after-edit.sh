#!/bin/bash
# Ralph Wiggum: After File Edit Hook
# Tracks progress and detects failure patterns

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

# Extract file info - using correct Cursor field names
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

# Cursor sends edits as an array with old_string/new_string
# Calculate total change from all edits
OLD_TOTAL=$(echo "$HOOK_INPUT" | jq -r '[.edits[].old_string // ""] | map(length) | add // 0')
NEW_TOTAL=$(echo "$HOOK_INPUT" | jq -r '[.edits[].new_string // ""] | map(length) | add // 0')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
PROGRESS_FILE="$RALPH_DIR/progress.md"
STATE_FILE="$RALPH_DIR/state.md"

# If Ralph isn't active, pass through
if [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Get current iteration
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")

# Calculate change size
CHANGE_SIZE=$((NEW_TOTAL - OLD_TOTAL))

if [[ $CHANGE_SIZE -lt 0 ]]; then
  CHANGE_SIZE=$((-CHANGE_SIZE))
  CHANGE_TYPE="removed"
elif [[ $CHANGE_SIZE -eq 0 ]]; then
  # Could be a replacement of same length
  if [[ $NEW_TOTAL -gt 0 ]]; then
    CHANGE_SIZE=$NEW_TOTAL
    CHANGE_TYPE="modified"
  else
    CHANGE_TYPE="no change"
  fi
else
  CHANGE_TYPE="added"
fi

# Log the edit to progress
TIMESTAMP=$(date -u +%H:%M:%S)

# Get just the filename for cleaner logs
FILENAME=$(basename "$FILE_PATH")

# Append to progress file
cat >> "$PROGRESS_FILE" <<EOF

### Edit: $FILENAME
- Time: $TIMESTAMP
- Change: $CHANGE_SIZE chars $CHANGE_TYPE
- Path: $FILE_PATH
EOF

# Check for potential failure patterns
# Check if this file has been edited multiple times in this session
EDIT_COUNT=$(grep -c "Path: $FILE_PATH" "$PROGRESS_FILE" 2>/dev/null || echo "0")

if [[ "$EDIT_COUNT" -gt 5 ]]; then
  # Possible thrashing on this file
  FAILURES_FILE="$RALPH_DIR/failures.md"
  
  cat >> "$FAILURES_FILE" <<EOF

## Potential Thrashing Detected
- File: $FILE_PATH
- Edits in session: $EDIT_COUNT
- Iteration: $CURRENT_ITERATION
- Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Consider: Is this file being repeatedly modified without progress?

EOF

  # Update pattern detection
  REPEATED_FAILURES=$(grep -c "Potential Thrashing" "$FAILURES_FILE" 2>/dev/null || echo "0")
  sedi "s/Repeated failures: [0-9]*/Repeated failures: $REPEATED_FAILURES/" "$FAILURES_FILE"
  
  if [[ "$REPEATED_FAILURES" -gt 2 ]]; then
    sedi "s/Gutter risk: .*/Gutter risk: HIGH/" "$FAILURES_FILE"
  fi
fi

# Return empty object (hook doesn't need to return anything specific)
echo '{}'
exit 0
