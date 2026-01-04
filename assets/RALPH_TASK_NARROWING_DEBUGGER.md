---
task: Build "ts-narrow" - A TypeScript Type Narrowing Debugger
test_command: "npm test"
completion_criteria:
  - CLI parses TypeScript files
  - Tracks type of a variable through control flow
  - Explains narrowing at each step
  - Handles if/else, typeof, instanceof, truthiness
  - Outputs human-readable explanation
  - Works on real-world examples
max_iterations: 30
---

# Task: Build "ts-narrow" - TypeScript Type Narrowing Debugger

Build a CLI tool that explains how TypeScript narrows types through control flow. When developers ask "why is this type X here?", this tool shows them step-by-step.

## The Problem

TypeScript's type narrowing is powerful but opaque. When narrowing doesn't work as expected, developers have no way to understand why. Error messages like "Type 'string | null' is not assignable to type 'string'" don't explain what went wrong.

## The Solution

A CLI that traces a variable through code and explains each narrowing step:

```bash
$ npx ts-node src/index.ts analyze test/truthiness.ts --variable x --line 4
```

Output:
```
Tracing `x` in test/truthiness.ts

Line 1:  function example(x: string | null) {
         → Type: string | null (function parameter)

Line 2:  if (x) {
         → Narrowed by: truthiness check
         → Type: string
         → Eliminated: null

Final type at line 4: string
```

## Technical Approach

Use the TypeScript Compiler API to:
1. Parse the source file into an AST
2. Create a type checker instance
3. Walk the AST tracking control flow
4. At each narrowing point, record what happened
5. Generate human-readable explanations

## Success Criteria

### Phase 1: Basic Parsing & Type Extraction
1. [ ] CLI accepts a TypeScript file path
2. [ ] Parses file using TypeScript Compiler API
3. [ ] Can find a variable declaration by name
4. [ ] Can get the type of a variable at declaration

### Phase 2: Control Flow Tracking
5. [ ] Tracks variable through if/else blocks
6. [ ] Identifies narrowing points (if conditions)
7. [ ] Records type before and after each narrowing
8. [ ] Handles nested if/else correctly

### Phase 3: Narrowing Detection
9. [ ] Detects truthiness narrowing (`if (x)`)
10. [ ] Detects typeof narrowing (`if (typeof x === 'string')`)
11. [ ] Detects instanceof narrowing (`if (x instanceof Error)`)
12. [ ] Detects equality narrowing (`if (x === null)`)
13. [ ] Detects discriminated union narrowing (`if (x.kind === 'a')`)

### Phase 4: Output & Explanation
14. [ ] Generates step-by-step trace output
15. [ ] Explains what caused each narrowing
16. [ ] Shows what types were eliminated
17. [ ] Highlights the final type at target line (MUST reflect narrowed scope)
18. [ ] Handles "type not narrowed" cases with explanation

### Phase 5: Edge Cases & Polish
19. [ ] Works with type aliases and interfaces
20. [ ] Handles function parameters
21. [ ] Works with optional chaining (`x?.foo`)
22. [ ] Provides helpful error for invalid inputs
23. [ ] Has --json output option for tooling

## Test Cases (npm test must pass ALL)

Create `test/` directory with these files and a test runner.

### test/truthiness.ts
```typescript
function example(x: string | null) {
  if (x) {
    console.log(x.toUpperCase()) // x is string here, line 4
  }
}
```

**Expected:** `ts-narrow analyze test/truthiness.ts --variable x --line 4` outputs `Final type at line 4: string`

### test/typeof.ts
```typescript
function process(value: string | number) {
  if (typeof value === 'string') {
    return value.toUpperCase() // value is string here, line 4
  }
  return value.toFixed(2) // value is number here, line 6
}
```

**Expected:** Line 4 → `string`, Line 6 → `number`

### test/discriminated.ts
```typescript
type Result = 
  | { ok: true; data: string }
  | { ok: false; error: Error }

function handle(result: Result) {
  if (result.ok) {
    console.log(result.data) // line 8
  } else {
    console.log(result.error) // line 10
  }
}
```

**Expected:** Line 8 → `{ ok: true; data: string }`, Line 10 → `{ ok: false; error: Error }`

### test/no-narrow.ts
```typescript
function broken(x: string | null) {
  const y = x
  if (x) {
    console.log(y.toUpperCase()) // y is still string | null, line 5
  }
}
```

**Expected:** Line 5 → `string | null` (y was not narrowed, only x was)

## Test Runner (package.json)

```json
{
  "scripts": {
    "test": "node test/run-tests.js"
  }
}
```

Create `test/run-tests.js` that:
1. Runs ts-narrow on each test file
2. Verifies output matches expected
3. Exits 0 if all pass, 1 if any fail

## File Structure

```
ts-narrow/
├── src/
│   ├── index.ts          # CLI entry point
│   ├── parser.ts         # TypeScript parsing utilities
│   ├── analyzer.ts       # Control flow analysis
│   ├── narrowing.ts      # Narrowing detection logic
│   ├── formatter.ts      # Output formatting
│   └── types.ts          # Internal type definitions
├── test/
│   ├── truthiness.ts
│   ├── typeof.ts
│   ├── discriminated.ts
│   ├── no-narrow.ts
│   └── run-tests.js      # Test runner
├── package.json
├── tsconfig.json
└── README.md
```

## Dependencies

- `typescript` (for Compiler API) - this is the ONLY external dependency
- Node.js built-ins only otherwise

## Constraints

- Must use TypeScript Compiler API (not regex/string parsing)
- No external dependencies except `typescript` itself
- Must handle real-world TypeScript (not toy examples only)
- Output must be human-readable, not just type dumps
- **Tests must pass - checking boxes is not enough**

---

## Ralph Instructions

1. Work through phases in order - don't skip ahead
2. **Run `npm test` after each change** - this is mandatory
3. A criterion is only complete when tests verify it
4. Commit after completing each criterion
5. If stuck on TypeScript Compiler API, read:
   https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API
6. When ALL criteria are [x] AND `npm test` passes: `RALPH_COMPLETE`
7. If stuck on same issue 3+ times: `RALPH_GUTTER`
