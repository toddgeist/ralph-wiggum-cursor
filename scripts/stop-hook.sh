#!/bin/bash
# Ralph Wiggum: Stop Hook
# - ENFORCES test execution before allowing completion
# - Manages iteration lifecycle
# - Triggers Cloud Agent handoff if configured
#
# Core Ralph principle: Tests determine completion, not the agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Extract workspace root
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')
RALPH_DIR="$WORKSPACE_ROOT/.ralph"
STATE_FILE="$RALPH_DIR/state.md"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"
PROGRESS_FILE="$RALPH_DIR/progress.md"
FAILURES_FILE="$RALPH_DIR/failures.md"
GUARDRAILS_FILE="$RALPH_DIR/guardrails.md"
CONTEXT_LOG="$RALPH_DIR/context-log.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"

# If Ralph isn't active, allow exit
if [[ ! -f "$TASK_FILE" ]] || [[ ! -d "$RALPH_DIR" ]]; then
  echo '{"decision": "stop"}'
  exit 0
fi

# =============================================================================
# EXTRACT TASK CONFIGURATION
# =============================================================================

# Get test command from YAML frontmatter
TEST_COMMAND=""
if grep -q "^test_command:" "$TASK_FILE" 2>/dev/null; then
  TEST_COMMAND=$(grep "^test_command:" "$TASK_FILE" | sed 's/test_command: *//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | xargs)
fi

# Get max iterations
MAX_ITERATIONS=$(grep '^max_iterations:' "$TASK_FILE" 2>/dev/null | sed 's/max_iterations: *//' || echo "0")

# Get current state
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")

# Count unchecked criteria
UNCHECKED_CRITERIA=$(grep -c '\- \[ \]' "$TASK_FILE" 2>/dev/null || echo "0")

# =============================================================================
# CLOUD MODE CHECK
# =============================================================================

is_cloud_enabled() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    return 0
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$KEY" ]]; then
      return 0
    fi
  fi
  GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null)
    if [[ -n "$KEY" ]]; then
      return 0
    fi
  fi
  return 1
}

# =============================================================================
# RUN TESTS (THE CORE OF RALPH)
# =============================================================================

run_tests() {
  local test_cmd="$1"
  local workspace="$2"
  
  if [[ -z "$test_cmd" ]]; then
    echo "NO_TEST_COMMAND"
    return 0
  fi
  
  cd "$workspace"
  
  # Run test command and capture output
  set +e
  TEST_OUTPUT=$(eval "$test_cmd" 2>&1)
  TEST_EXIT_CODE=$?
  set -e
  
  if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "PASS"
    echo "$TEST_OUTPUT" > "$RALPH_DIR/.last_test_output"
  else
    echo "FAIL:$TEST_EXIT_CODE"
    echo "$TEST_OUTPUT" > "$RALPH_DIR/.last_test_output"
  fi
}

# =============================================================================
# CHECK CONTEXT HEALTH
# =============================================================================

CONTEXT_CRITICAL=false
GUTTER_RISK_HIGH=false

if [[ -f "$CONTEXT_LOG" ]]; then
  CONTEXT_STATUS=$(grep 'Status:' "$CONTEXT_LOG" | head -1 || echo "")
  if echo "$CONTEXT_STATUS" | grep -q "Critical"; then
    CONTEXT_CRITICAL=true
  fi
fi

if [[ -f "$FAILURES_FILE" ]]; then
  GUTTER_RISK=$(grep 'Gutter risk:' "$FAILURES_FILE" | sed 's/.*Gutter risk: //' || echo "Low")
  if [[ "$GUTTER_RISK" == "HIGH" ]]; then
    GUTTER_RISK_HIGH=true
  fi
fi

ALLOCATED_TOKENS=$(grep 'Allocated:' "$CONTEXT_LOG" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
if [[ -z "$ALLOCATED_TOKENS" ]]; then
  ALLOCATED_TOKENS=0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# =============================================================================
# DECISION LOGIC
# =============================================================================

# Case 1: All criteria appear checked - RUN TESTS TO VERIFY
if [[ "$UNCHECKED_CRITERIA" -eq 0 ]]; then
  
  if [[ -n "$TEST_COMMAND" ]]; then
    TEST_RESULT=$(run_tests "$TEST_COMMAND" "$WORKSPACE_ROOT")
    TEST_OUTPUT=$(cat "$RALPH_DIR/.last_test_output" 2>/dev/null || echo "")
    
    if [[ "$TEST_RESULT" == "PASS" ]]; then
      # Tests passed - ACTUALLY complete
      cat >> "$PROGRESS_FILE" <<EOF

---

## 🎉 RALPH COMPLETE (Tests Verified)
- Iteration: $CURRENT_ITERATION
- Time: $TIMESTAMP
- Test command: $TEST_COMMAND
- Result: ✅ PASSED

\`\`\`
$TEST_OUTPUT
\`\`\`

EOF
      
      cat > "$STATE_FILE" <<EOF
---
iteration: $CURRENT_ITERATION
status: complete
completed_at: $TIMESTAMP
---

# Ralph State

✅ Task completed - verified by tests.
EOF
      
      echo '{"decision": "stop"}'
      exit 0
      
    else
      # Tests FAILED - agent lied or made a mistake
      EXIT_CODE=$(echo "$TEST_RESULT" | sed 's/FAIL://')
      
      cat >> "$PROGRESS_FILE" <<EOF

---

### ❌ Tests FAILED (Iteration $CURRENT_ITERATION)
- Time: $TIMESTAMP
- Test command: $TEST_COMMAND
- Exit code: $EXIT_CODE

\`\`\`
$TEST_OUTPUT
\`\`\`

**Criteria are checked but tests fail. The task is NOT complete.**

EOF
      
      # Log failure
      cat >> "$FAILURES_FILE" <<EOF

## Test Failure at $TIMESTAMP
- Command: $TEST_COMMAND
- Exit code: $EXIT_CODE
- Note: Agent marked criteria complete but tests fail

EOF
      
      # Force continue - agent must fix
      NEXT_ITERATION=$((CURRENT_ITERATION + 1))
      
      cat > "$STATE_FILE" <<EOF
---
iteration: $NEXT_ITERATION
status: active
started_at: $TIMESTAMP
---

# Ralph State

Iteration $NEXT_ITERATION - Fixing test failures...
EOF
      
      # Truncate test output for message if too long
      SHORT_OUTPUT=$(echo "$TEST_OUTPUT" | head -50)
      if [[ ${#TEST_OUTPUT} -gt ${#SHORT_OUTPUT} ]]; then
        SHORT_OUTPUT="$SHORT_OUTPUT\n\n... (truncated, see .ralph/.last_test_output for full output)"
      fi
      
      jq -n \
        --arg output "$SHORT_OUTPUT" \
        --arg cmd "$TEST_COMMAND" \
        '{
          "decision": "block",
          "userMessage": "⚠️ Tests failed. Ralph is continuing to fix.",
          "agentMessage": "🚨 TESTS FAILED - TASK IS NOT COMPLETE\n\nYou checked all criteria but the tests do not pass.\nTest command: " + $cmd + "\n\nOutput:\n" + $output + "\n\n**You must fix the code until tests pass. Run the test command after each fix to verify.**"
        }'
      exit 0
    fi
    
  else
    # No test command - trust the checkboxes (not ideal)
    cat >> "$PROGRESS_FILE" <<EOF

---

## 🎉 RALPH COMPLETE (No Test Verification)
- Iteration: $CURRENT_ITERATION
- Time: $TIMESTAMP
- Warning: No test_command defined - completion not verified

EOF
    
    cat > "$STATE_FILE" <<EOF
---
iteration: $CURRENT_ITERATION
status: complete
completed_at: $TIMESTAMP
---

# Ralph State

✅ Task completed (unverified - no test command).
EOF
    
    echo '{"decision": "stop"}'
    exit 0
  fi
fi

# Case 2: Max iterations reached
if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$CURRENT_ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  cat >> "$PROGRESS_FILE" <<EOF

---

## 🛑 Max Iterations Reached
- Iteration: $CURRENT_ITERATION
- Max allowed: $MAX_ITERATIONS
- Criteria remaining: $UNCHECKED_CRITERIA

EOF
  
  sedi "s/^status: .*/status: max_iterations_reached/" "$STATE_FILE"
  
  echo '{"decision": "stop"}'
  exit 0
fi

# Case 3: Context critical or gutter risk - need fresh context
if [[ "$CONTEXT_CRITICAL" == "true" ]] || [[ "$GUTTER_RISK_HIGH" == "true" ]]; then
  
  cat >> "$PROGRESS_FILE" <<EOF

---

## ⚠️ Context Limit (Iteration $CURRENT_ITERATION)
- Time: $TIMESTAMP
- Context: $ALLOCATED_TOKENS tokens
- Gutter risk: $(grep 'Gutter risk:' "$FAILURES_FILE" 2>/dev/null | sed 's/.*Gutter risk: //' || echo "Low")
- Criteria remaining: $UNCHECKED_CRITERIA

EOF

  # Try Cloud Mode
  if is_cloud_enabled; then
    if "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT" 2>/dev/null; then
      jq -n '{
        "decision": "stop",
        "userMessage": "🌩️ Context full. Cloud Agent spawned to continue."
      }'
      exit 0
    fi
  fi
  
  # Local Mode - human must start new conversation
  jq -n \
    --argjson iter "$CURRENT_ITERATION" \
    '{
      "decision": "stop",
      "userMessage": "⚠️ Context full. Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\""
    }'
  exit 0
fi

# Case 4: Normal continue - still work to do
NEXT_ITERATION=$((CURRENT_ITERATION + 1))

cat >> "$PROGRESS_FILE" <<EOF

---

## Iteration $CURRENT_ITERATION Summary
- Ended: $TIMESTAMP
- Context: $ALLOCATED_TOKENS tokens (healthy)
- Criteria remaining: $UNCHECKED_CRITERIA
- Status: Continuing...

EOF

cat > "$STATE_FILE" <<EOF
---
iteration: $NEXT_ITERATION
status: active
started_at: $TIMESTAMP
---

# Ralph State

Iteration $NEXT_ITERATION - Active
EOF

# Build continuation message
CONTINUE_MSG="🔄 Iteration $NEXT_ITERATION

$UNCHECKED_CRITERIA criteria remaining. Continue working on the next unchecked item in RALPH_TASK.md."

if [[ -n "$TEST_COMMAND" ]]; then
  CONTINUE_MSG="$CONTINUE_MSG

**Run tests after changes:** \`$TEST_COMMAND\`
Tests must pass for the task to be complete."
fi

jq -n \
  --arg msg "$CONTINUE_MSG" \
  '{
    "decision": "block",
    "agentMessage": $msg
  }'

exit 0
