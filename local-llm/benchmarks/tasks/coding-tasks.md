## Task: Reverse a Linked List

**Category:** coding  
**Difficulty:** easy  
**Expected time:** 30s

### Prompt

> Write a function in Python that reverses a singly linked list in place.  Include a ListNode class and a test with at least 5 elements.

### Expected Outcome

A correct iterative or recursive implementation with O(n) time and O(1) space (iterative) or O(n) stack (recursive).  Test should construct a list, reverse it, and verify the output order.

### Scoring

- **Pass:** Correct implementation, runs without errors, test passes
- **Partial:** Correct logic but missing test or minor syntax error
- **Fail:** Incorrect reversal or does not run

---

## Task: Multi-file Refactor

**Category:** coding  
**Difficulty:** hard  
**Expected time:** 180s

### Prompt

> Given a Python Flask app with routes in `app.py`, models in `models.py`, and utils in `utils.py`, refactor the authentication logic from `app.py` into a new `auth.py` module.  Move the `hash_password` function from utils to auth.  Update all imports.  Provide complete file contents for all four files.

### Expected Outcome

All four files compile, imports are correct, no circular dependencies, authentication endpoints still work.  `hash_password` moved cleanly.

### Scoring

- **Pass:** All files correct, no broken imports, logic preserved
- **Partial:** Refactoring correct but one import path wrong or minor omission
- **Fail:** Circular import, missing function, or logic change

---

## Task: Debug a Race Condition

**Category:** coding  
**Difficulty:** hard  
**Expected time:** 120s

### Prompt

> The following Go code has a race condition.  Find the bug, explain it, and fix it:
> ```go
> var counter int
> func increment(wg *sync.WaitGroup) { defer wg.Done(); for i := 0; i < 1000; i++ { counter++ } }
> func main() { var wg sync.WaitGroup; for i := 0; i < 10; i++ { wg.Add(1); go increment(&wg) }; wg.Wait(); fmt.Println(counter) }
> ```

### Expected Outcome

Identifies unsynchronized access to `counter`, explains the data race, and fixes with either `sync.Mutex`, `sync/atomic`, or channel-based approach.

### Scoring

- **Pass:** Correct diagnosis, clear explanation, working fix
- **Partial:** Correct fix but weak explanation
- **Fail:** Wrong diagnosis or fix that doesn't resolve the race

---

## Task: Implement a CLI Tool

**Category:** coding  
**Difficulty:** medium  
**Expected time:** 120s

### Prompt

> Write a PowerShell function `Get-LargeFiles` that accepts `-Path` (default: current dir), `-MinSizeMB` (default: 100), and `-Recurse` switch.  It should output objects with Name, FullPath, SizeMB (rounded to 1 decimal), and LastModified.  Include comment-based help.

### Expected Outcome

Valid PowerShell with proper parameter attributes, pipeline-friendly output, handles non-existent path gracefully.

### Scoring

- **Pass:** Runs correctly, parameters work, help is complete
- **Partial:** Works but missing parameter validation or help
- **Fail:** Syntax errors or incorrect behavior

---

## Task: TypeScript Generic Utility

**Category:** coding  
**Difficulty:** medium  
**Expected time:** 60s

### Prompt

> Write a TypeScript generic function `groupBy<T, K extends keyof T>(items: T[], key: K): Map<T[K], T[]>` that groups an array of objects by a given key.  Include type tests that verify the return type.

### Expected Outcome

Correct generic constraints, proper Map usage, type-safe return.  Compiles with `tsc --strict`.

### Scoring

- **Pass:** Compiles strict, correct behavior, types inferred correctly
- **Partial:** Correct logic but type assertions used as workaround
- **Fail:** Does not compile or incorrect grouping
