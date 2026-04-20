# Incremental Property-Based Testing in QCheck2

This document is the comprehensive reference for the **incremental PBT**
extension implemented on the `inc` branch of QCheck. It describes the
motivation, all code changes, the demonstration test suite, how to build and
run, and known limitations.

---

## 1. Motivation

Traditional PBT assumes the system under test (SUT) is fully implemented. In
real incremental development workflows, programmers leave branches stubbed with
`raise NotImplemented` or similar placeholders, commit, and keep iterating. A
stock QCheck run over such a program breaks in two ways:

1. **Early abort.** The first input that reaches an unimplemented branch raises
   an exception. QCheck records an *error*, shrinks it, and stops. Every
   already-implemented branch remains unvalidated.
2. **Semantic ambiguity.** The same verdict (*error*) is produced by real logic
   bugs and by explicitly-deferred code. The developer cannot distinguish them
   without reading the stack trace.

### The Solution: Trivalued Semantics

The thesis remedy is a third verdict, orthogonal to `Pass` and `Fail` and to
the pre-existing precondition-driven `Discard`:

| Verdict         | Meaning                                                  |
|-----------------|----------------------------------------------------------|
| `Pass`          | Property held on a valid input.                          |
| `Fail`          | Property violated (or uncontrolled exception).           |
| `Discard`       | Input failed a precondition — not a result.              |
| `Unimplemented` | Input hit an explicitly-deferred branch — not a failure. |

Design constraints carried over from the thesis (§5.3):

- **Non-intrusive:** no change to SUT signatures.
- **Automatic propagation:** the signal bubbles through intermediate layers
  without manual instrumentation — exceptions are the natural fit in OCaml.
- **Backwards-compatible:** if no code raises `TBD`, QCheck behaves exactly
  like upstream.

---

## 2. Repository Architecture

This is the full QCheck monorepo. The changes live entirely in two source files
and one test file:

| File | Role |
|------|------|
| `src/core/QCheck2.ml` | The core QCheck2 library — **modified** to support the third verdict. |
| `src/core/QCheck2.mli` | The public interface — **modified** to expose `TBD`, `get_count_incomplete`, and `get_tbd_reasons`. |
| `src/alcotest/QCheck_alcotest.ml` | The Alcotest adapter — **modified** to print TBD counts and per-reason breakdown before delegating to `check_result`. |
| `src/alcotest/QCheck_alcotest.mli` | The Alcotest public interface — **modified** to document TBD-aware behaviour of `to_alcotest`. |
| `test/core/lambda_subst.ml` | The thesis experiment: lambda calculus substitution tested with incremental PBT (direct runner). |
| `test/core/lambda_subst_alco.ml` | Alcotest variant of the thesis experiment: same four substitution implementations exercised via `QCheck_alcotest`. |
| `test/core/dune` | Added `lambda_subst` and `lambda_subst_alco` executable stanzas. |

All other modules (ounit integration, PPX deriver, existing tests) are
**untouched**. Consumers that never raise `TBD` observe identical behavior to
upstream QCheck2.

---

## 3. The `TBD` Exception

The signal is the exception `TBD of string`, declared in `QCheck2.ml` and
exported through `QCheck2.mli`:

```ocaml
exception TBD of string
```

The user raises it in any not-yet-implemented branch of the SUT, providing a
descriptive reason:

```ocaml
let rec subst x s = function
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (a, b) -> App (subst x s a, subst x s b)
  | Abs _ -> raise (QCheck2.TBD "Abs case not yet implemented")
```

The string parameter serves as a label that identifies **which** incomplete
branch was hit. QCheck2 collects these labels during a test run and reports
per-reason hit counts, giving the developer a breakdown of where the
incompletions are concentrated.

### Why the Framework Owns the Exception

The exception is declared inside `QCheck2.ml` rather than left for the user to
define. This means:

- **No boilerplate:** the user does not need to write `exception IncompleteCode`
  at the top of every file.
- **Type-safe detection:** QCheck2 catches the exception with a direct pattern
  match (`| TBD reason -> ...`) instead of fragile string-based name matching.
- **Payload support:** the `string` parameter carries information about what is
  incomplete, which was impossible with a nullary user-defined exception.

The exception is placed next to the existing `Failed_precondition` and
`No_example_found` exceptions in `QCheck2.ml` (line ~76), following the same
pattern for control-flow exceptions used by the framework.

---

## 4. Changes to `QCheck2.ml`

The modifications are **surgical** — changes across three modules
(`TestResult`, `Test_exceptions`, `Test`), with no type-system redesign and no
removal of existing code.

### 4.1. `exception TBD of string`

**Location:** top level, after `exception No_example_found of string`.

```ocaml
exception TBD of string
(* raised by user to signal not-yet-implemented code in incremental PBT *)
```

### 4.2. New fields in `TestResult.t`

**Location:** `module TestResult`, `type 'a t`.

Two new fields were added to the result record:

```ocaml
type 'a t = {
  mutable state : 'a state;
  mutable count: int;
  mutable count_gen: int;
  mutable count_incomplete: int;                (* cases that raised TBD *)
  tbd_reasons: (string, int) Hashtbl.t;         (* TBD reason -> hit count *)
  collect_tbl: (string, int) Hashtbl.t lazy_t;
  stats_tbl: ('a stat * (int, int) Hashtbl.t) list;
  mutable warnings: string list;
}
```

- `count_incomplete` is a mutable integer counting total TBD cases.
- `tbd_reasons` is a `(string, int) Hashtbl.t` mapping each unique TBD reason
  string to the number of times it was encountered. This reuses the same
  hashtable pattern already used by `collect_tbl` in the same record.

**Rationale** for a counter + hashtable rather than a new constructor on the
`state` sum type:

- Preserves the existing `state` ADT (`Success | Failed _ | Error _ |
  Failed_other _`) so every downstream consumer (alcotest, ounit runners, PPX
  tests, the old pretty-printer) keeps compiling unchanged.
- Satisfies §5.6 "**backwards-compatible**": if no case raises `TBD`,
  `count_incomplete` stays `0`, `tbd_reasons` stays empty, and everything
  behaves identically to upstream.
- Gives us the **effective coverage** metric from §5.5 almost for free:
  `Pass + Fail = count - count_incomplete`.
- The per-reason breakdown via `tbd_reasons` lets users identify *which*
  incomplete branches are hit most often.

### 4.3. Accessors `get_count_incomplete` and `get_tbd_reasons`

**Location:** `module TestResult`, after `get_count_gen`.

```ocaml
let get_count_incomplete {count_incomplete; _} = count_incomplete

let get_tbd_reasons {tbd_reasons; _} =
  Hashtbl.fold (fun reason count acc -> (reason, count) :: acc) tbd_reasons []
```

`get_tbd_reasons` returns a `(string * int) list` so the caller does not need
to deal with the mutable hashtable directly.

### 4.4. `shrink` — QCheck1 path: ignore TBD candidates

**Location:** `module Test`, inside `shrink_`, the `Some f` branch (QCheck1-compat path).

A new exception clause was inserted **between** the existing
`Failed_precondition | No_example_found _` clause and the `e when is_err`
clause:

```ocaml
with
| Failed_precondition | No_example_found _ -> None
| TBD _ -> None   (* skip incomplete candidates *)
| e when is_err -> Some (Tree.pure x, Shrink_exn e, [])
```

The ordering is critical: `TBD _` must fire **before** `is_err`. Without that
ordering, when `is_err = true` (shrinking an error), `TBD` would be accepted as
a valid reduced error — which is incorrect.

### 4.5. `shrink` — QCheck2 path: ignore TBD candidates

**Location:** `module Test`, inside `shrink_`, the `None` branch (QCheck2 shrink-tree path).

Same clause as 4.4, applied to the QCheck2 shrink tree:

```ocaml
with
| Failed_precondition | No_example_found _ -> None
| TBD _ -> None   (* skip incomplete candidates *)
| e when is_err -> Some (x_tree, Shrink_exn e, [])
```

### 4.6. `check_state_input` — intercept `TBD` before `handle_exn`

**Location:** `check_state_input`, the `with` block.

This is the **critical interception**. A new exception handler was inserted
between the existing `Failed_precondition | No_example_found _` handler and the
catch-all `| e -> handle_exn ...`:

```ocaml
with
| Failed_precondition | No_example_found _ ->
  state.step state.test.name state.test input FalseAssumption;
  CR_continue
| TBD reason ->
  (* incremental PBT: incomplete case, count and continue *)
  state.res.R.count_incomplete <- state.res.R.count_incomplete + 1;
  let tbl = state.res.R.tbd_reasons in
  let prev = try Hashtbl.find tbl reason with Not_found -> 0 in
  Hashtbl.replace tbl reason (prev + 1);
  state.step state.test.name state.test input FalseAssumption;
  CR_continue
| e ->
  let bt = Printexc.get_backtrace () in
  handle_exn state input_tree e bt
```

Four things happen when `TBD reason` is caught:

1. The counter `count_incomplete` is bumped — single source of truth for the new
   verdict.
2. The reason string is recorded in the `tbd_reasons` hashtable with its count
   incremented.
3. `step` is called with `FalseAssumption` — reuses the existing "this input
   didn't count toward coverage" bookkeeping.
4. `CR_continue` is returned — **the campaign does not abort**, the outer loop
   moves to the next input.

`handle_exn` is **never** called for `TBD`. No backtrace is captured, no shrink
runs, no `R.Error` is written.

### 4.7. `check_if_assumptions` — guard against spurious warnings

**Location:** `check_if_assumptions`.

```ocaml
if R.is_success res && res.R.count_incomplete = 0
   && percentage_of_count < assm_frac then (
  (* emit the warning *)
)
```

If any `TBD` was seen during the run, the "too few tests passed precondition"
warning is suppressed — consistent with the thesis' position that
`Unimplemented` is expected during incremental development.

### 4.8. `check_cell` — initialize new fields

**Location:** Inside `check_cell`, the `res = { ... }` record literal.

```ocaml
res = {R.
        state=R.Success; count=0; count_gen=0; count_incomplete=0;
        tbd_reasons=Hashtbl.create 8;
        collect_tbl=lazy (Hashtbl.create 10);
        warnings=[];
        stats_tbl= List.map (fun stat -> stat, Hashtbl.create 10) cell.stats;
      };
```

Since `check_cell` is the only site that constructs `TestResult.t`, this single
initialization covers every test run.

---

## 5. Changes to `QCheck2.mli`

Three additions to the public interface:

### 5.1. `exception TBD of string`

Declared after the `{1 Assumptions}` section, under a new `{1 Incremental PBT}`
section heading. Full ocamldoc describes the purpose, usage example, and
cross-references to `get_count_incomplete` and `get_tbd_reasons`.

### 5.2. `get_count_incomplete` in `TestResult`

```ocaml
val get_count_incomplete : _ t -> int
(** [get_count_incomplete t] returns the number of cases that raised
    {!TBD} and were skipped. *)
```

### 5.3. `get_tbd_reasons` in `TestResult`

```ocaml
val get_tbd_reasons : _ t -> (string * int) list
(** [get_tbd_reasons t] returns a list of [(reason, count)] pairs, where each
    [reason] is a unique string passed to {!TBD} during the test run, and
    [count] is how many times that particular reason was encountered. *)
```

---

## 6. Shrinking Policy: Never Shrink into `Unimplemented`

The thesis §5.4 is explicit:

> **No contraer Unimplemented.** Si un caso cae en codigo incompleto, no se
> intenta minimizar. [...] El estado `Unimplemented` se considera un
> "callejon sin salida" informativo, no un error a depurar.

There are two reasons:

- A smaller input could accidentally *dodge* the unimplemented branch and cross
  the boundary into a passing case, producing a false "minimal counterexample"
  that is really just a minimal green case.
- A smaller input could hit a *different* unimplemented branch, giving the
  developer no information about the real defect.

`TBD` shouldn't even *enter* shrinking because of the guard in §4.6, but
shrinking is also invoked transitively when an already-failing case is being
minimized. During that recursive descent, some children of the shrink tree may
themselves raise `TBD`. We must discard them. The `| TBD _ -> None` clauses in
§4.4 and §4.5 handle this: returning `None` signals "this shrink candidate is
not an improvement, move on". The shrinker will therefore never settle on a
`TBD`-raising node as the minimal counterexample for a *different* failure.

Both the QCheck1-compatible path (uses a user-supplied shrink function) and the
QCheck2 path (uses the shrink tree attached to the generator) need the clause,
which is why the change appears twice.

---

## 7. End-to-End Flow

Putting the pieces together, the lifecycle of a generated input is:

```
                     +-- law returns true  -> Pass  (count += 1)
                     |
  gen -> input -> law -+-- law returns false -> Fail  (enter shrinker, record counterex.)
                     |
                     +-- raise (TBD reason)
                     |    -> count_incomplete += 1
                     |    -> tbd_reasons[reason] += 1
                     |    -> step(..., FalseAssumption)
                     |    -> CR_continue  (skip shrinking, next input)
                     |
                     +-- raise any other exn
                          -> handle_exn -> shrinker -> Error verdict
```

The final `TestResult` carries these numbers that together describe the
campaign:

- `get_count`            — inputs that reached the law (`Pass + Fail`).
- `get_count_gen`        — inputs actually generated (includes discards).
- `get_count_incomplete` — inputs swallowed by `TBD`.
- `get_tbd_reasons`      — breakdown of which `TBD` reasons were hit and how often.

Users wanting the §5.5 *Effective Coverage* metric compute it directly:

```
effective = count / (count + count_incomplete)
```

---

## 8. Before vs After: The `TBD` Path

### Before (Upstream QCheck2)

Given `law input` raising an unimplemented-code exception:

1. The exception does not match `Failed_precondition | No_example_found _`, so
   the catch-all `| e -> handle_exn ...` fires.
2. `Printexc.get_backtrace ()` is called.
3. `handle_exn` invokes `shrink` with `is_err = true`.
4. Shrink candidates that also raise the exception are accepted as "smaller"
   errors. Shrinking converges on a minimal incomplete term — meaningless.
5. `R.error` writes `state.res.state <- R.Error { exn; ... }`.
6. `CR_yield state.res` is returned, **terminating the campaign**.
7. `check_result` raises `Test_error(name, instance, exn, backtrace)`.

**Net effect:** Indistinguishable from a genuine runtime error. The campaign
aborts, the exception is shrunk wastefully, and it's reported as an error.

### After (Modified QCheck2)

Given `law input` raising `TBD reason`:

1. The `| TBD reason ->` arm fires (direct pattern match).
2. `count_incomplete` is bumped. The reason is recorded in `tbd_reasons`.
3. `step` is called with `FalseAssumption`, and `CR_continue` is returned.
4. The outer loop generates the next input. `handle_exn` is **never** called.
5. No backtrace is captured. No shrink runs. No `R.Error` is written.
6. The result state remains `Success` unless a different real failure later
   demotes it.

**Net effect:** The campaign continues across incomplete cases. `TBD` never
surfaces as `Test_error`. The per-reason breakdown tells the developer exactly
which branches are still deferred.

### Summary Table

| Aspect | Before | After |
|--------|--------|-------|
| First TBD raise | Campaign terminates | Campaign continues |
| Test result state | `R.Error { exn }` | `R.Success` (unless a real bug also occurs) |
| `check_exn` raises | `Test_error(name, instance, exn, bt)` | Nothing (or `Test_fail` if a real bug is found) |
| Shrinking | Runs on the exception, converges to minimal incomplete term | Never runs for `TBD` |
| Candidate shrinking | May accept incomplete as valid reduced error | Incomplete candidates silently dropped |
| `count_incomplete` | Did not exist | Populated; readable via `get_count_incomplete` |
| `tbd_reasons` | Did not exist | Per-reason breakdown via `get_tbd_reasons` |
| Assumption warning | Fires if too many cases skipped | Suppressed when `count_incomplete > 0` |
| Real bugs | Unchanged | Unchanged |
| Backward compat (no `TBD`) | N/A | Identical to upstream |

---

## 9. The Test File: `test/core/lambda_subst.ml`

This file is the complete thesis experiment in one file. It tests lambda
calculus variable substitution implementations against a capture-avoidance
property.

### Section 1: Syntax & Formatting

The lambda term type with four constructors:

```ocaml
type term =
  | Var of int        (* variable *)
  | Abs of int * term (* lambda abstraction *)
  | App of term * term(* application *)
  | Con of int        (* constant *)
```

Variable identifiers are plain `int`s. A pretty-printer `pp_term` renders terms
in standard lambda notation (e.g., `(lv0.v0)`).

### Section 2: Logic & Helpers

- `free_vars : term -> int list` — collects free variables of a term.
- `max_id : term -> int` — finds the largest variable identifier.
- Set utilities: `normalize`, `set_equal`, `set_union`, `set_remove`.
- `subst_dummy : int -> term -> term` — replaces a bound variable with `Con 0`
  (used only by the shrinker to remove a binder).
- `is_well_scoped : term -> bool` — checks that every `Var` is bound by an
  enclosing `Abs`.

### Section 3: Substitution Implementations

Four substitution functions `[x := s]t` with varying degrees of correctness and
completeness:

#### 1. `subst_naive` — Intentionally Buggy

Does **not** avoid variable capture. When `y` appears free in `s`, substituting
under `Abs(y, ...)` incorrectly captures it. Fully implemented, no `TBD`.

#### 2. `subst_incom` — Correct but Deliberately Incomplete

Raises `QCheck2.TBD "subst_incom: Abs case"` on every `Abs` node where
`x <> y`. Models a function where the hard case (capture avoidance under
binders) has not been implemented yet.

#### 3. `subst_mixed` — Both a Real Bug AND Incomplete Branches

- `Abs(y, Abs _)` raises `QCheck2.TBD "subst_mixed: nested Abs"` (not yet
  implemented).
- `Abs(y, non-Abs body)` has a real capture bug (naive recursion).

This demonstrates the key thesis scenario: bugs and incompleteness coexisting in
the same function.

#### 4. `subst_2_incomplete` — Two Incomplete Branches with Distinct Reasons

- `Abs(y, Abs _)` raises `QCheck2.TBD "subst_2_incomplete: nested Abs"`.
- `Abs(y, App _)` raises `QCheck2.TBD "subst_2_incomplete: App in Abs body"`.

This demonstrates the per-reason tracking: the output shows two distinct TBD
reasons with separate hit counts.

### Section 4: Generators & Shrinkers

**Shrinkers:**
- `shrink_term` — always tries `Con 0` first (smallest term), then structurally
  smaller terms.
- `shrink_term_beta` — like `shrink_term` but also attempts beta-reduction on
  `App(Abs _, _)` redexes.

**Generators:**
- `term_gen` — generates **closed** (well-scoped) terms. Uses `G.fix` with a
  threading `next_id` that increments at each `Abs` node to guarantee unique
  binder names. Starts with `env = []` and `next_id = 0`.
- `term_gen_open` — generates **open** terms (with free variables from pool
  `[0..9]`). Starts with `free_var_pool = [0;1;...;9]` and `start_id = 0`, so
  bound variables intentionally collide with free variables to expose capture
  bugs.
- `gen_subst_triple_open` — generates triples `(x, s, t)` for substitution
  testing. Biased 9:1 toward choosing `x` from `free_vars(t)` so most tests
  exercise a meaningful substitution.

### Section 5: Tests

- `test_validity` — validates the generator produces well-scoped closed terms
  (10,000 tests).
- `test_shrinker` — validates the shrinker preserves well-scopedness (1,000
  tests).
- `make_prop_subst_free_no_var_capture_open` — the main property factory. Checks
  the capture-avoidance identity:

  ```
  FV([x := s]t) = (FV(t) \ {x}) U FV(s)    (when x in FV(t))
  ```

  Four test instances are created from this factory, one per substitution
  implementation.

### Section 6: Runners

Two runner functions:

- `run_direct` — Standard runner. Uses `QCheck2.Test.check_cell` +
  `QCheck2.Test.check_result`. Does not read `count_incomplete`.
- `run_direct_incomplete` — Incremental PBT runner. Additionally reads
  `get_count_incomplete` and `get_tbd_reasons` to report pass/fail/incomplete
  counts and per-reason breakdown.

---

## 10. Using the Feature

Minimal usage from a user's point of view:

```ocaml
let rec subst x s = function
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (a, b) -> App (subst x s a, subst x s b)
  | Abs _ -> raise (QCheck2.TBD "Abs case not yet implemented")

let prop = QCheck2.Test.make ~name:"capture avoidance" ~count:1000 gen check
```

When the user runs the test through a runner that reads
`QCheck2.TestResult.get_count_incomplete` and
`QCheck2.TestResult.get_tbd_reasons`, they see:

```
=== capture avoidance ===
PASS (passed: 720, incomplete cases: 280)
  TBD: Abs case not yet implemented (280 times)
```

720 inputs validated the branches that *are* implemented; 280 hit the deferred
`Abs` case and were counted rather than aborting the run. The TBD reason tells
the developer exactly which branch was hit.

---

## 11. How to Build and Run

### Prerequisites

- OCaml compiler (tested with 4.x and 5.x)
- `dune` build system
- The project uses a local opam switch in `_opam/`. Activate it before building:

```bash
eval $(opam env --switch=.)
```

### Running the Direct-Runner Experiment

```bash
dune exec test/core/lambda_subst.exe
```

Expected output (example):

```
=== Generator Validity (Well-Scoped) ===
PASS (passed: 10000)

=== Shrinker Validity ===
PASS (passed: 1000)

=== Capture Avoidance (naive/buggy subst) ===
FAIL [...] (passed: N, failed: 1, incomplete cases: 0):
...

=== Capture Avoidance (correct subst but incomplete) ===
PASS (passed: M, incomplete cases: K)
  TBD: subst_incom: Abs case (K times)

=== Capture Avoidance (mixed: buggy + incomplete) ===
FAIL [...] (passed: N, failed: 1, incomplete cases: K):
...
  TBD: subst_mixed: nested Abs (K times)

=== Capture Avoidance (throws incomplete in 2 branches) ===
FAIL [...] (passed: N, failed: 1, incomplete cases: K):
...
  TBD: subst_2_incomplete: App in Abs body (K1 times)
  TBD: subst_2_incomplete: nested Abs (K2 times)
(global counter: TBD raised K times)
```

- **naive:** always finds the capture bug (FAIL, 0 incomplete).
- **incom:** never finds a bug because the correct path always passes; the
  incomplete path is counted (PASS with incomplete > 0).
- **mixed:** finds the capture bug on non-Abs bodies AND counts incomplete cases
  on nested Abs bodies (FAIL with incomplete > 0).
- **2_incomplete:** finds the capture bug in remaining branches; both Abs and
  App bodies raise TBD with distinct reasons (FAIL with incomplete > 0, two
  separate TBD reasons reported).

### Running the Alcotest Experiment

```bash
dune exec test/core/lambda_subst_alco.exe
```

This passes the same four substitution implementations (and the generator/shrinker
validity tests) through the `QCheck_alcotest.to_alcotest` adapter. Alcotest
formats each test case as a pass/fail entry; when any TBD cases were recorded
the adapter prints them to stdout **before** Alcotest prints its verdict line:

```
  incomplete cases: <K>
    TBD: <reason> (<count> times)
    ...
[FAIL] Capture Avoidance (correct subst but incomplete)
```

`FAIL` here is the Alcotest result for the test case that contained the bug or
was entirely incomplete; a purely-incomplete run where no real failure occurred
passes Alcotest (the underlying QCheck2 state is `R.Success`).

---

## 12. Key Design Decisions

- **Variable identifiers are plain `int`s.** `next_id` is threaded through
  generators and incremented at each `Abs` node to guarantee unique binder
  names.
- **`term_gen_open` starts with `free_var_pool = [0..9]` and `start_id = 0`.**
  Bound variables intentionally collide with free variables to expose capture
  bugs.
- **`prop_subst_free_no_var_capture_open` skips the check when `x` is not in
  `FV(t)`.** Substitution is a no-op in that case, so testing it provides no
  signal.
- **Framework-owned exception.** `exception TBD of string` is declared in
  `QCheck2.ml` itself. This eliminates user-side boilerplate and enables
  type-safe detection via direct pattern matching (no string-based name matching
  needed).
- **String payload.** The `string` parameter on `TBD` lets users describe
  *which* branch is incomplete. The framework records per-reason counts in
  `tbd_reasons`, giving a breakdown in the test output.
- **Counter + hashtable instead of a new state variant.** Adding
  `count_incomplete` and `tbd_reasons` as record fields (rather than extending
  the `TestResult.state` sum type) preserves backward compatibility: every
  downstream consumer keeps compiling unchanged.

---

## 13. Limitations, Edge Cases, and Open Questions

1. **`count_incomplete` is not part of the termination logic.** The loop
   condition `is_done state = state.cur_count <= 0 || state.cur_max_gen <= 0` is
   unchanged. A run where most inputs are incomplete will exhaust `cur_max_gen`
   with `count` still very low, producing far fewer than the target number of
   real passes.

2. **The assumption check is suppressed entirely, not adjusted.** When
   `count_incomplete > 0`, `check_if_assumptions` never fires — even if the
   assumption-percentage problem is real. A more precise fix would compute an
   effective target.

3. **No richer step event.** Incomplete cases emit `FalseAssumption`, the same
   value used for `Failed_precondition`. A step-callback consumer cannot
   distinguish them from the event stream alone; it must read
   `count_incomplete` or `tbd_reasons` post-hoc.

4. **A 100% incomplete run still reports `Success`.** If every input raises
   `TBD`, the result state is `R.Success` (the initial state, never demoted).
   `is_success res` returns `true` even though the property never evaluated on a
   single complete input. Check `count` and `count_incomplete` to distinguish
   this from a genuine full pass.

5. **`find_example` silently inherits the new semantics.** `find_example` calls
   `Test.check_cell` internally, so a predicate that raises `TBD` will silently
   skip those cases.

---

## 14. Alcotest Backend Integration

This section documents the changes to `src/alcotest/QCheck_alcotest.ml` and
`QCheck_alcotest.mli` that make TBD information visible when running tests
through the Alcotest runner.

### 14.1 The Problem

`to_alcotest` previously delegated entirely to `T.check_cell_exn`:

```ocaml
let run () =
  let call = Raw.callback ~colors ~verbose ~print_res:false ~print in
  T.check_cell_exn ~long ~call ~handler ~rand cell
```

`check_cell_exn` is a convenience wrapper that calls `check_cell` internally and
then immediately raises if the result state is not `R.Success`. Because it never
returns the `TestResult.t`, the `count_incomplete` counter and `tbd_reasons`
hashtable accumulated during the run were silently discarded: the Alcotest
output gave no indication that any `TBD` cases had been encountered.

### 14.2 The Fix: Two-Phase Result Handling

The run body was rewritten to call `check_cell` directly, inspect the result,
print TBD information if present, and only then raise via `check_result`:

```ocaml
let run () =
  let call = Raw.callback ~colors ~verbose ~print_res:false ~print in
  let res = T.check_cell ~long ~call ~handler ~rand cell in
  let incomplete = Q.TestResult.get_count_incomplete res in
  if incomplete > 0 then begin
    let tbd_reasons = Q.TestResult.get_tbd_reasons res in
    Printf.printf "  incomplete cases: %d\n" incomplete;
    List.iter (fun (reason, count) ->
      Printf.printf "    TBD: %s (%d times)\n" reason count
    ) tbd_reasons
  end;
  T.check_result cell res
```

Four observations about the new code:

1. **`check_cell` instead of `check_cell_exn`.** `check_cell` runs the campaign
   and returns the `TestResult.t` without raising. This gives the adapter a
   window to read `count_incomplete` and `tbd_reasons` before control passes to
   the Alcotest framework.
2. **Conditional output.** The TBD block is printed only when `incomplete > 0`,
   so runs with no incomplete cases produce no extra output — identical to the
   upstream behavior.
3. **`check_result` reproduces the raising contract.** `T.check_result cell res`
   inspects `res.state` and raises `Test_fail` or `Test_error` exactly as
   `check_cell_exn` would have. The visible Alcotest verdict is unchanged;
   the only addition is the extra stdout lines printed beforehand.
4. **Output ordering.** Because `Printf.printf` flushes to stdout and Alcotest's
   own verdict line goes to the same stream, the TBD lines appear immediately
   before the `[FAIL]` / `[OK]` line for that test case.

### 14.3 Documentation Update in `QCheck_alcotest.mli`

A paragraph was added to the `to_alcotest` docstring:

```ocaml
(** ...
    When the tested property raises {!QCheck2.TBD}, incomplete case counts and
    per-reason breakdowns are printed to stdout before the result is checked.
    ... *)
```

This makes the behavior discoverable from the interface file without requiring
users to read the implementation.

### 14.4 The Alcotest Test File: `test/core/lambda_subst_alco.ml`

This file is a self-contained Alcotest executable that exercises the same four
substitution implementations from `lambda_subst.ml` (§9) through the modified
`QCheck_alcotest.to_alcotest` adapter.

**Structure.** The file is organized in six sections mirroring `lambda_subst.ml`:

| Section | Content |
|---------|---------|
| 1 | `term` type and `pp_term` / `print_term` formatters |
| 2 | `free_vars`, `max_id`, set utilities, `is_well_scoped` |
| 3 | Four substitution implementations: `subst_naive`, `subst_incom`, `subst_mixed`, `subst_2_incomplete` |
| 4 | Shrinkers (`shrink_term`, `shrink_term_beta`) and generators (`term_gen`, `term_gen_open`, `gen_subst_triple_open`) |
| 5 | Tests: `test_validity`, `test_shrinker`, `make_prop_subst_free_no_var_capture_open` factory + four instances |
| 6 | Alcotest entry point: two suites (`"generators"`, `"substitution"`) passed to `Alcotest.run` |

**Key differences from `lambda_subst.ml`:**

- No `incomplete_counter` global ref. The direct-runner file used a manual
  counter as a cross-check; the alcotest file relies entirely on
  `QCheck2.TestResult.get_count_incomplete` and `get_tbd_reasons` (read by the
  adapter).
- No `run_direct` / `run_direct_incomplete` custom runner functions. The runner
  is `QCheck_alcotest.to_alcotest` followed by `Alcotest.run`.
- Three `print_triple` variants (`print_triple`, `print_triple'`,
  `print_triple''`) for different display formats; only `print_triple` is wired
  into the test spec.

**Entry point:**

```ocaml
let () =
  let suite_basic =
    List.map QCheck_alcotest.to_alcotest
      [ test_validity; test_shrinker ]
  in
  let suite_subst =
    List.map QCheck_alcotest.to_alcotest
      [ prop_subst_free_no_var_capture_open_subst_naive;
        prop_subst_free_no_var_capture_open_subst_incom;
        prop_subst_free_no_var_capture_open_subst_mixed;
        prop_subst_free_no_var_capture_open_subst_2_incomplete ]
  in
  Alcotest.run "Lambda Substitution (Incremental PBT)"
    [ "generators", suite_basic;
      "substitution", suite_subst ]
```

The test binary is registered in `test/core/dune` as:

```
(executable
  (name lambda_subst_alco)
  (modules lambda_subst_alco)
  (libraries qcheck-core qcheck-alcotest alcotest))
```

### 14.5 Before vs After: Alcotest TBD Visibility

| Aspect | Before | After |
|--------|--------|-------|
| API called | `T.check_cell_exn` | `T.check_cell` + `T.check_result` |
| `TestResult.t` accessible | No (consumed internally) | Yes (inspected before raising) |
| TBD count printed | No | Yes, when `count_incomplete > 0` |
| Per-reason breakdown printed | No | Yes, one line per distinct TBD reason |
| Alcotest verdict | Unchanged | Unchanged |
| Backward compat (no TBD) | N/A | Identical output — no extra lines |

---

## 15. Summary of Touched Locations

| File | Change |
|------|--------|
| `src/core/QCheck2.ml` | `exception TBD of string` declaration |
| `src/core/QCheck2.ml` | `count_incomplete` field and `tbd_reasons` hashtable in `TestResult.t` |
| `src/core/QCheck2.ml` | `get_count_incomplete` and `get_tbd_reasons` accessors |
| `src/core/QCheck2.ml` | Skip `TBD _` candidates during shrinking (two locations) |
| `src/core/QCheck2.ml` | Runner arm: catch `TBD reason`, record count + reason, continue |
| `src/core/QCheck2.ml` | Suppress "too many discards" warning when `count_incomplete > 0` |
| `src/core/QCheck2.ml` | Initialize `count_incomplete = 0` and `tbd_reasons` in `check_cell` |
| `src/core/QCheck2.mli` | Expose `exception TBD of string` with documentation |
| `src/core/QCheck2.mli` | Expose `get_count_incomplete` and `get_tbd_reasons` in `TestResult` |
| `src/alcotest/QCheck_alcotest.ml` | Switch `to_alcotest` from `check_cell_exn` to `check_cell`; print TBD breakdown before `check_result` |
| `src/alcotest/QCheck_alcotest.mli` | Document TBD-aware behaviour in the `to_alcotest` docstring |
| `test/core/dune` | `lambda_subst` and `lambda_subst_alco` executable stanzas |
| `test/core/lambda_subst.ml` | Thesis experiment: 4 substitutions, generators, property, direct runners |
| `test/core/lambda_subst_alco.ml` | Alcotest variant of the thesis experiment (same 4 implementations via `QCheck_alcotest`) |

All other modules are untouched; consumers that never raise `TBD` observe
identical behavior to upstream QCheck2.
