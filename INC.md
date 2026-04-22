# Incremental Property-Based Testing in QCheck2

This document is the comprehensive reference for the **incremental PBT**
extension implemented on the `inc` branch of QCheck. It describes the
motivation, the design, the demonstration test suite, how to build and run,
and known limitations.

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
- **Backwards-compatible:** if no code raises `failwith "TODO:..."`, QCheck
  behaves exactly like upstream.

---

## 2. Repository Architecture

This is the full QCheck monorepo. The changes are split across the core
QCheck2 library, the Alcotest adapter, the thesis-experiment test files,
and a pair of out-of-band files that describe the patched alcotest
dependency:

| File                                 | Role                                                                                                                                                                            |
|--------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `src/core/QCheck2.ml`                | The core QCheck2 library — **modified** to support the third verdict via a `TODO:`-prefix convention over `failwith`.                                                           |
| `src/core/QCheck2.mli`               | The public interface — **modified** to expose `get_count_incomplete` and `get_todo_reasons`.                                                                                    |
| `src/alcotest/QCheck_alcotest.ml`    | The Alcotest adapter — **modified** to print incomplete counts and the per-reason TODO breakdown, and to raise `Alcotest.incomplete` on successful-but-incomplete runs so Alcotest renders the `[INCOMPLETE]` tag. |
| `src/alcotest/QCheck_alcotest.mli`   | The Alcotest public interface — **modified** to document the TODO-aware behaviour and the `[INCOMPLETE]` tag.                                                                   |
| `test/core/lambda_subst.ml`          | The thesis experiment: lambda calculus substitution tested with incremental PBT (direct runner).                                                                                |
| `test/core/lambda_subst_alco.ml`     | Alcotest variant of the thesis experiment: same four substitution implementations exercised via `QCheck_alcotest`.                                                              |
| `test/core/dune`                     | Added `lambda_subst` and `lambda_subst_alco` executable stanzas.                                                                                                                |
| `ALCOTEST.md`                        | End-to-end setup reference for the patched alcotest dependency (sibling clone at `../alcotest/` + `opam pin`).                                                                  |
| `patches/alcotest-incomplete.patch`  | The alcotest patch against tag `1.9.1`, shipped so the feature is reproducible from scratch without assuming any specific `../alcotest/` is already present.                    |

All other modules (ounit integration, PPX deriver, existing tests) are
**untouched**. Consumers that never raise `failwith "TODO:..."` observe
identical behavior to upstream QCheck2.

A runtime dependency of the Alcotest pipeline lives outside this repo:
a sibling clone of `mirage/alcotest` at `../alcotest/` on branch
`qcheck-inc-incomplete` (based on tag 1.9.1), consumed via
`opam pin add alcotest ../alcotest --kind=path`. See §11 and `ALCOTEST.md`
for setup details; see `_pablo/parallel-dev-of-qcheck-inc-and-alcotest.md`
for the rationale and a detailed trace of the opam-pin mechanics.

---

## 3. The `failwith "TODO:<reason>"` Convention

The signal is a plain `Failure` exception — the same exception raised by the
standard library's `failwith` — whose message starts with the five-character
literal prefix `TODO:`. No custom exception is declared by QCheck2 and the user
does not need to declare one either.

The convention is recognised by **two independent consumers**:

- **QCheck2** treats matching `Failure` values as incomplete iterations:
  increments `count_incomplete`, records the per-reason breakdown in
  `todo_reasons`, and never shrinks into them. Covered in §4.
- **Patched alcotest** treats matching `Failure` values as the `[INCOMPLETE]`
  outcome directly: `protect_test` in `../alcotest/src/alcotest-engine/core.ml`
  has a when-guarded arm `Failure s when String.is_prefix ~affix:"TODO:" s ->
  \`Incomplete s`. So any alcotest test — QCheck or not — that raises `Failure`
  whose message starts with `TODO:` is tagged `[INCOMPLETE]` rather than
  `[FAIL]`. See `ALCOTEST.md`.

The two consumers agree on the prefix verbatim. They do not share code.

The canonical reproduction of the alcotest-native path is the sibling
project `../alcotest-incomplete-demo/` (in `experimental/`, alongside
this repo and `../alcotest/`). It has its own opam switch, pins patched
alcotest and qcheck-inc, and ships a toy library
(`arith_stubs.{ml,mli}`) plus a plain alcotest test file
(`test_arith_stubs.ml`) that uses no special imports. Running
`dune runtest` there produces 2 × `[OK]` + 2 × `[INCOMPLETE]`, exit 0.
See `ALCOTEST.md` and the demo's own `README.md` for setup.

The user raises it in any not-yet-implemented branch of the SUT, providing a
descriptive reason after the colon:

```ocaml
let rec subst x s = function
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (a, b) -> App (subst x s a, subst x s b)
  | Abs _ -> failwith "TODO:Abs case not yet implemented"
```

The text following `TODO:` is the **reason** — a label identifying which
incomplete branch was hit. QCheck2 captures these reasons during a test run
and reports per-reason hit counts, giving the developer a breakdown of where
the incompletions are concentrated. An empty reason (`failwith "TODO:"`) is
accepted and recorded as the empty string.

### Why a Prefix Over `failwith` Instead of a Dedicated Exception

Routing the signal through the stdlib `Failure` exception rather than a
QCheck-owned constructor yields three properties:

- **Zero boilerplate at the call site.** The user writes `failwith "TODO:..."`
  and does not need to `open` QCheck2, reference a qualified constructor, or
  declare a local exception.
- **No cross-module exception coupling.** A SUT compiled without QCheck in its
  dependencies still raises a well-defined, standard exception. The SUT is
  testable with or without QCheck running it.
- **Precise, non-fragile detection.** A single helper `todo_reason` inside
  QCheck2 inspects the message for the literal `TODO:` prefix. Any other
  `Failure _` (e.g. `failwith "boom"`) is treated as a normal test error — no
  name matching on exception slots, no accidental capture of `failwith`
  messages that happen to mention "TODO" later in the text.

---

## 4. Internals in `QCheck2.ml`

The modifications are **surgical** — changes across two modules (`TestResult`
and `Test`), with no type-system redesign and no removal of existing behavior.

### 4.1. The `todo_reason` helper

**Location:** `module Test`, just before `shrink`.

```ocaml
(* Extract the reason from a [failwith "TODO:<reason>"] message.
   Returns [Some reason] if [msg] starts with "TODO:" (reason may be empty),
   else [None]. *)
let todo_reason (msg : string) : string option =
  let prefix = "TODO:" in
  let plen = String.length prefix in
  if String.length msg >= plen && String.sub msg 0 plen = prefix
  then Some (String.sub msg plen (String.length msg - plen))
  else None
```

The helper is the single source of truth for the prefix policy. It is used
three times in `module Test`: once in each of the two shrink guards (§4.4,
§4.5), and once in the runner arm (§4.6).

The prefix length check uses `>=` rather than `>`, so `failwith "TODO:"` is
accepted and produces an empty reason. `String.starts_with` is avoided because
the project's minimum OCaml version (4.08) predates it.

### 4.2. Fields in `TestResult.t`

**Location:** `module TestResult`, `type 'a t`.

Two fields support the third verdict:

```ocaml
type 'a t = {
  mutable state : 'a state;
  mutable count: int;
  mutable count_gen: int;
  mutable count_incomplete: int;                (* cases that raised failwith "TODO:..." *)
  todo_reasons: (string, int) Hashtbl.t;        (* TODO reason -> hit count *)
  collect_tbl: (string, int) Hashtbl.t lazy_t;
  stats_tbl: ('a stat * (int, int) Hashtbl.t) list;
  mutable warnings: string list;
}
```

- `count_incomplete` is a mutable integer counting total incomplete cases.
- `todo_reasons` is a `(string, int) Hashtbl.t` mapping each unique TODO
  reason string to the number of times it was encountered. This reuses the
  same hashtable pattern already used by `collect_tbl` in the same record.

**Rationale** for a counter + hashtable rather than a new constructor on the
`state` sum type:

- Preserves the existing `state` ADT (`Success | Failed _ | Error _ |
  Failed_other _`) so every downstream consumer (alcotest, ounit runners, PPX
  tests, the old pretty-printer) keeps compiling unchanged.
- Satisfies §5.6 "**backwards-compatible**": if no case raises a
  `TODO:`-prefixed `failwith`, `count_incomplete` stays `0`, `todo_reasons`
  stays empty, and everything behaves identically to upstream.
- Gives us the **effective coverage** metric from §5.5 almost for free:
  `Pass + Fail = count - count_incomplete`.
- The per-reason breakdown via `todo_reasons` lets users identify *which*
  incomplete branches are hit most often.

### 4.3. Accessors `get_count_incomplete` and `get_todo_reasons`

**Location:** `module TestResult`, after `get_count_gen`.

```ocaml
let get_count_incomplete {count_incomplete; _} = count_incomplete

let get_todo_reasons {todo_reasons; _} =
  Hashtbl.fold (fun reason count acc -> (reason, count) :: acc) todo_reasons []
```

`get_todo_reasons` returns a `(string * int) list` so the caller does not need
to deal with the mutable hashtable directly.

### 4.4. `shrink` — QCheck1 path: ignore incomplete candidates

**Location:** `module Test`, inside `shrink_`, the `Some f` branch (QCheck1-compat path).

A TODO-aware exception clause sits **between** the existing
`Failed_precondition | No_example_found _` clause and the `e when is_err`
clause:

```ocaml
with
| Failed_precondition | No_example_found _ -> None
| Failure msg when todo_reason msg <> None -> None   (* skip incomplete candidates *)
| e when is_err -> Some (Tree.pure x, Shrink_exn e, [])
```

The ordering is critical: the TODO guard must fire **before** `is_err`.
Without that ordering, when `is_err = true` (shrinking an error), a
TODO-raising candidate would be accepted as a valid reduced error — which is
incorrect. The guard discards only `Failure` values whose message carries the
TODO prefix; plain `failwith "boom"` falls through to `is_err`.

### 4.5. `shrink` — QCheck2 path: ignore incomplete candidates

**Location:** `module Test`, inside `shrink_`, the `None` branch (QCheck2 shrink-tree path).

Same clause as §4.4, applied to the QCheck2 shrink tree:

```ocaml
with
| Failed_precondition | No_example_found _ -> None
| Failure msg when todo_reason msg <> None -> None   (* skip incomplete candidates *)
| e when is_err -> Some (x_tree, Shrink_exn e, [])
```

### 4.6. `check_state_input` — intercept TODO-failures before `handle_exn`

**Location:** `check_state_input`, the `with` block.

This is the **critical interception**. A `Failure msg` handler sits between
the existing `Failed_precondition | No_example_found _` handler and the
catch-all `| e -> handle_exn ...`. It dispatches on `todo_reason msg`:

```ocaml
with
| Failed_precondition | No_example_found _ ->
  state.step state.test.name state.test input FalseAssumption;
  CR_continue
| Failure msg as e ->
  (match todo_reason msg with
   | Some reason ->
     (* incremental PBT: incomplete case, count and continue *)
     state.res.R.count_incomplete <- state.res.R.count_incomplete + 1;
     let tbl = state.res.R.todo_reasons in
     let prev = try Hashtbl.find tbl reason with Not_found -> 0 in
     Hashtbl.replace tbl reason (prev + 1);
     state.step state.test.name state.test input FalseAssumption;
     CR_continue
   | None ->
     let bt = Printexc.get_backtrace () in
     handle_exn state input_tree e bt)
| e ->
  let bt = Printexc.get_backtrace () in
  handle_exn state input_tree e bt
```

When `todo_reason msg = Some reason`, four things happen:

1. The counter `count_incomplete` is bumped — single source of truth for the
   new verdict.
2. The reason string is recorded in the `todo_reasons` hashtable with its
   count incremented.
3. `step` is called with `FalseAssumption` — reuses the existing "this input
   didn't count toward coverage" bookkeeping.
4. `CR_continue` is returned — **the campaign does not abort**, the outer
   loop moves to the next input.

When `todo_reason msg = None`, the original exception value (`e`) is handed
to `handle_exn` exactly as the catch-all `| e -> ...` arm would have — so a
plain `failwith "boom"` surfaces as a normal `Test_error`, unshrunk semantics
unchanged from upstream.

`handle_exn` is **never** called for a TODO-prefixed `failwith`. No backtrace
is captured, no shrink runs, no `R.Error` is written.

### 4.7. `check_if_assumptions` — guard against spurious warnings

**Location:** `check_if_assumptions`.

```ocaml
if R.is_success res && res.R.count_incomplete = 0
   && percentage_of_count < assm_frac then (
  (* emit the warning *)
)
```

If any incomplete case was seen during the run, the "too few tests passed
precondition" warning is suppressed — consistent with the thesis' position
that `Unimplemented` is expected during incremental development.

### 4.8. `check_cell` — initialize new fields

**Location:** Inside `check_cell`, the `res = { ... }` record literal.

```ocaml
res = {R.
        state=R.Success; count=0; count_gen=0; count_incomplete=0;
        todo_reasons=Hashtbl.create 8;
        collect_tbl=lazy (Hashtbl.create 10);
        warnings=[];
        stats_tbl= List.map (fun stat -> stat, Hashtbl.create 10) cell.stats;
      };
```

Since `check_cell` is the only site that constructs `TestResult.t`, this
single initialization covers every test run.

---

## 5. Public Interface in `QCheck2.mli`

Three additions are exposed to consumers of the library:

### 5.1. The `{1 Incremental PBT}` doc block

A free-standing documentation section (no value or type declaration) explains
the TODO convention, links to the TestResult accessors, and shows a usage
example:

```ocaml
(** {1 Incremental PBT}

    Raise [Failure] via [failwith] with a message starting with ["TODO:"]
    to signal not-yet-implemented code. Whatever follows ["TODO:"] is
    captured as the reason (possibly empty) and tracked per-reason in
    {!TestResult}.

    When a test input causes such a [Failure] to be raised, QCheck2 counts
    it as an incomplete case (neither pass nor fail), skips shrinking, and
    continues testing the remaining inputs. ...

    A [Failure] whose message does not start with ["TODO:"] is treated as
    a normal test error.

    Usage:
    {[
      let rec subst x s = function
        | Var y -> if x = y then s else Var y
        | Abs _ -> failwith "TODO:Abs case not yet implemented"
    ]}

    @see <#TestResult> {!TestResult.get_count_incomplete} ...
    @see <#TestResult> {!TestResult.get_todo_reasons} ...
*)
```

Nothing is exported at the value level from this section — the convention is
implemented entirely by interpretation of an existing stdlib exception.

### 5.2. `get_count_incomplete` in `TestResult`

```ocaml
val get_count_incomplete : _ t -> int
(** [get_count_incomplete t] returns the number of cases that raised
    [Failure] via [failwith "TODO:..."] and were skipped. *)
```

### 5.3. `get_todo_reasons` in `TestResult`

```ocaml
val get_todo_reasons : _ t -> (string * int) list
(** [get_todo_reasons t] returns a list of [(reason, count)] pairs, where each
    [reason] is a unique string that followed ["TODO:"] in a [failwith] message
    during the test run, and [count] is how many times that particular reason
    was encountered. *)
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

A TODO-prefixed `failwith` shouldn't even *enter* shrinking because of the
guard in §4.6, but shrinking is also invoked transitively when an
already-failing case is being minimized. During that recursive descent, some
children of the shrink tree may themselves raise `failwith "TODO:..."`. We
must discard them. The `| Failure msg when todo_reason msg <> None -> None`
clauses in §4.4 and §4.5 handle this: returning `None` signals "this shrink
candidate is not an improvement, move on". The shrinker will therefore never
settle on an incomplete-raising node as the minimal counterexample for a
*different* failure.

Both the QCheck1-compatible path (uses a user-supplied shrink function) and the
QCheck2 path (uses the shrink tree attached to the generator) need the clause,
which is why the check appears twice.

---

## 7. End-to-End Flow

Putting the pieces together, the lifecycle of a generated input is:

```
                     +-- law returns true  -> Pass  (count += 1)
                     |
  gen -> input -> law -+-- law returns false -> Fail  (enter shrinker, record counterex.)
                     |
                     +-- raise (Failure "TODO:reason")
                     |    -> count_incomplete += 1
                     |    -> todo_reasons[reason] += 1
                     |    -> step(..., FalseAssumption)
                     |    -> CR_continue  (skip shrinking, next input)
                     |
                     +-- raise any other exn  (including non-TODO Failure)
                          -> handle_exn -> shrinker -> Error verdict
```

The final `TestResult` carries these numbers that together describe the
campaign:

- `get_count`            — inputs that reached the law (`Pass + Fail`).
- `get_count_gen`        — inputs actually generated (includes discards).
- `get_count_incomplete` — inputs swallowed by a TODO-prefixed `failwith`.
- `get_todo_reasons`     — breakdown of which reasons were hit and how often.

Users wanting the §5.5 *Effective Coverage* metric compute it directly:

```
effective = count / (count + count_incomplete)
```

---

## 8. Before vs After: The Incremental Path

### Before (Upstream QCheck2)

Given `law input` raising an unimplemented-code exception (whatever its form):

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

Given `law input` raising `Failure "TODO:reason"`:

1. The `| Failure msg as e ->` arm fires.
2. `todo_reason msg` returns `Some reason`.
3. `count_incomplete` is bumped. The reason is recorded in `todo_reasons`.
4. `step` is called with `FalseAssumption`, and `CR_continue` is returned.
5. The outer loop generates the next input. `handle_exn` is **never** called.
6. No backtrace is captured. No shrink runs. No `R.Error` is written.
7. The result state remains `Success` unless a different real failure later
   demotes it.

**Net effect:** The campaign continues across incomplete cases. TODO never
surfaces as `Test_error`. The per-reason breakdown tells the developer exactly
which branches are still deferred. Any other `Failure` (non-TODO) message
follows the identical error path as before — no regression on unrelated
`failwith` calls.

### Summary Table

| Aspect | Before | After |
|--------|--------|-------|
| First incomplete raise | Campaign terminates | Campaign continues |
| Test result state | `R.Error { exn }` | `R.Success` (unless a real bug also occurs) |
| `check_exn` raises | `Test_error(name, instance, exn, bt)` | Nothing (or `Test_fail` if a real bug is found) |
| Shrinking | Runs on the exception, converges to minimal incomplete term | Never runs for TODO-failures |
| Candidate shrinking | May accept incomplete as valid reduced error | Incomplete candidates silently dropped |
| `count_incomplete` | Did not exist | Populated; readable via `get_count_incomplete` |
| `todo_reasons` | Did not exist | Per-reason breakdown via `get_todo_reasons` |
| Assumption warning | Fires if too many cases skipped | Suppressed when `count_incomplete > 0` |
| Non-TODO `failwith` | Treated as error | Treated as error (unchanged) |
| Real bugs | Unchanged | Unchanged |
| Backward compat (no TODO) | N/A | Identical to upstream |

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
under `Abs(y, ...)` incorrectly captures it. Fully implemented, no incomplete
branches.

#### 2. `subst_incom` — Correct but Deliberately Incomplete

Raises `failwith "TODO:subst_incom: Abs case"` on every `Abs` node where
`x <> y`. Models a function where the hard case (capture avoidance under
binders) has not been implemented yet.

#### 3. `subst_mixed` — Both a Real Bug AND Incomplete Branches

- `Abs(y, Abs _)` raises `failwith "TODO:subst_mixed: nested Abs"` (not yet
  implemented).
- `Abs(y, non-Abs body)` has a real capture bug (naive recursion).

This demonstrates the key thesis scenario: bugs and incompleteness coexisting
in the same function.

#### 4. `subst_2_incomplete` — Two Incomplete Branches with Distinct Reasons

- `Abs(y, Abs _)` raises `failwith "TODO:subst_2_incomplete: nested Abs"`.
- `Abs(y, App _)` raises `failwith "TODO:subst_2_incomplete: App in Abs body"`.

This demonstrates the per-reason tracking: the output shows two distinct TODO
reasons with separate hit counts. The file also keeps a global `ref`
`incomplete_counter` that each incomplete branch increments, to cross-check
the framework-reported total.

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
- `make_prop_subst_free_no_var_capture_open` — the main property factory.
  Checks the capture-avoidance identity:

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
  `get_count_incomplete` and `get_todo_reasons` to report pass/fail/incomplete
  counts and per-reason breakdown, prefixing each reason with `"  TODO: "`.

---

## 10. Using the Feature

Minimal usage from a user's point of view:

```ocaml
let rec subst x s = function
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (a, b) -> App (subst x s a, subst x s b)
  | Abs _ -> failwith "TODO:Abs case not yet implemented"

let prop = QCheck2.Test.make ~name:"capture avoidance" ~count:1000 gen check
```

When the user runs the test through a runner that reads
`QCheck2.TestResult.get_count_incomplete` and
`QCheck2.TestResult.get_todo_reasons`, they see:

```
=== capture avoidance ===
PASS (passed: 720, incomplete cases: 280)
  TODO: Abs case not yet implemented (280 times)
```

720 inputs validated the branches that *are* implemented; 280 hit the deferred
`Abs` case and were counted rather than aborting the run. The reason tells
the developer exactly which branch was hit.

---

## 11. Building, Running, and Developing

### 11.1 Prerequisites

- OCaml compiler (tested with 4.x and 5.x; minimum is 4.08).
- `dune` build system.
- A local opam switch in `_opam/` (the project ships with one).
- **A patched copy of alcotest** at `../alcotest/` (sibling of this repo),
  on branch `qcheck-inc-incomplete` based on tag `1.9.1`. The patch adds
  the `[INCOMPLETE]` outcome tag that the `QCheck_alcotest` bridge relies
  on. The patch is small (≈ 25 lines across 7 files under
  `src/alcotest-engine/`) and is shipped in this repo as a backup at
  `patches/alcotest-incomplete.patch`.

See `ALCOTEST.md` at the repo root for the end-to-end setup reference and
`_pablo/parallel-dev-of-qcheck-inc-and-alcotest.md` for the rationale and
a detailed trace of the opam-pin mechanics.

### 11.2 First-time setup

Activate the local switch:

```bash
eval $(opam env --switch=.)
```

If `../alcotest/` does not yet exist, clone and patch it:

```bash
git clone git@github.com:mirage/alcotest.git ../alcotest
git -C ../alcotest checkout 1.9.1
git -C ../alcotest switch -c qcheck-inc-incomplete
git -C ../alcotest am ./patches/alcotest-incomplete.patch
```

Pin the local opam switch at the sibling clone:

```bash
opam pin add alcotest ../alcotest --kind=path --yes
```

Verify the pin:

```bash
opam pin list | grep alcotest
# alcotest.1.9.1  rsync  file:///…/experimental/alcotest
```

Then build:

```bash
dune build
```

### 11.3 Running the Direct-Runner Experiment

This runner does not depend on alcotest — it uses QCheck2's own runner
plumbing. Useful as a sanity check that the `TODO:`-prefix machinery in
`src/core/QCheck2.ml` still works regardless of the alcotest pin.

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
  TODO: subst_incom: Abs case (K times)

=== Capture Avoidance (mixed: buggy + incomplete) ===
FAIL [...] (passed: N, failed: 1, incomplete cases: K):
...
  TODO: subst_mixed: nested Abs (K times)

=== Capture Avoidance (throws incomplete in 2 branches) ===
FAIL [...] (passed: N, failed: 1, incomplete cases: K):
...
  TODO: subst_2_incomplete: App in Abs body (K1 times)
  TODO: subst_2_incomplete: nested Abs (K2 times)
(global counter: TODO raised K times)
```

- **naive:** always finds the capture bug (FAIL, 0 incomplete).
- **incom:** never finds a bug because the correct path always passes; the
  incomplete path is counted (PASS with incomplete > 0).
- **mixed:** finds the capture bug on non-Abs bodies AND counts incomplete
  cases on nested Abs bodies (FAIL with incomplete > 0).
- **2_incomplete:** finds the capture bug in remaining branches; both Abs and
  App bodies raise TODO-failures with distinct reasons (FAIL with incomplete
  > 0, two separate TODO reasons reported).

### 11.4 Running the Alcotest Experiment

This runner depends on the patched alcotest being pinned (§11.1, §11.2).

```bash
dune exec test/core/lambda_subst_alco.exe
```

The same four substitution implementations (plus the generator/shrinker
validity tests) are fed through `QCheck_alcotest.to_alcotest`. Each test
case shows one of four status tags in the per-test status column:

```
  [OK]          generators            0   Generator Validity (Well-Scoped).
  [OK]          generators            1   Shrinker Validity.
> [FAIL]        substitution          0   Capture Avoidance (naive/buggy subst).
  [INCOMPLETE]  substitution          1   Capture Avoidance (correct subst bu...
  [FAIL]        substitution          2   Capture Avoidance (mixed: buggy + i...
  [FAIL]        substitution          3   Capture Avoidance (throws incomplet...
```

- `[OK]` (green) — no real failure, no incomplete cases.
- `[FAIL]` (red) — a real QCheck failure was found (takes priority over
  incomplete).
- `[INCOMPLETE]` (yellow) — no real failure, but at least one case raised
  `failwith "TODO:..."`. Does **not** count toward the nonzero exit code;
  does count toward the "N tests run" summary total.
- `[SKIP]` — inherited from upstream alcotest; not produced by this repo.

When `[FAIL]` or `[INCOMPLETE]` applies, the adapter additionally prints
`incomplete cases: <K>` and the per-reason TODO breakdown to stdout before
alcotest's verdict line. That extra output is captured into per-test log
files under `_build/_tests/.../substitution.NNN.output`.

### 11.5 Development workflow

Two sides can be edited independently: this repo for the QCheck2 and bridge
logic, and `../alcotest/` for the alcotest patch. The `opam pin` setup
(§11.2) means edits in `../alcotest/` are picked up on the next `dune build`
inside this repo without any commit dance — opam rsyncs the working tree
whenever it re-installs the pinned package.

#### 11.5.1 Iterating on this repo

Standard edit/build/run loop. No special handling beyond having `../alcotest/`
checked out to `qcheck-inc-incomplete`:

```bash
$EDITOR src/core/QCheck2.ml           # or any other file in this repo
dune build
dune exec test/core/lambda_subst_alco.exe
```

#### 11.5.2 Iterating on the alcotest patch

```bash
git -C ../alcotest branch --show-current     # must say qcheck-inc-incomplete
$EDITOR ../alcotest/src/alcotest-engine/pp.ml
cd qcheck-inc                                # already there, just for context
dune build                                   # opam rsyncs ../alcotest/ and rebuilds
dune exec test/core/lambda_subst_alco.exe
```

When the alcotest changes are ready, commit them inside `../alcotest/` and
refresh the backup patch so this repo stays self-contained:

```bash
git -C ../alcotest commit -am "<description>"
git -C ../alcotest format-patch 1.9.1..qcheck-inc-incomplete --stdout \
  > patches/alcotest-incomplete.patch
git add patches/alcotest-incomplete.patch
git commit -m "Refresh alcotest patch"
```

#### 11.5.3 The branch-guard gotcha

The opam pin reflects `../alcotest/`'s working tree, not a specific ref. If
`../alcotest/` is checked out to `main` (because you were pulling upstream),
`dune build` will link against unpatched alcotest and any use of
`Alcotest.incomplete` will fail to compile. Guard before building:

```bash
git -C ../alcotest branch --show-current      # expect qcheck-inc-incomplete
git -C ../alcotest switch qcheck-inc-incomplete   # if needed
```

#### 11.5.4 Reverting to stock alcotest

```bash
opam pin remove alcotest --yes
```

Restores the registry version. The `QCheck_alcotest` bridge then fails to
compile (it calls `Alcotest.incomplete`, which stock alcotest does not
export). Re-pin with `opam pin add alcotest ../alcotest --kind=path --yes`
to restore the `[INCOMPLETE]` tag support.

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
- **Convention over dedicated exception.** The incomplete-case signal is the
  stdlib `Failure` exception with the literal message prefix `TODO:`. No
  QCheck-owned exception is declared; the SUT does not need to `open` QCheck
  or reference any qualified constructor.
- **Prefix detection via `todo_reason`.** A single helper inside
  `module Test` inspects the message for the `"TODO:"` prefix and returns the
  trailing reason as `string option`. This is the sole pattern-matching
  strategy in the framework — no string-based name matching on exception
  slots, no reflection.
- **Empty reason permitted.** `failwith "TODO:"` matches with an empty
  reason. The framework treats the reason as opaque payload; an empty string
  is a valid key for the hashtable.
- **Non-TODO `failwith` stays an error.** The runner arm dispatches on
  `todo_reason msg`; if it returns `None`, the original `Failure` value is
  passed to `handle_exn` exactly as the catch-all arm would have. This
  preserves the behavior of unrelated `failwith` calls.
- **Counter + hashtable instead of a new state variant.** Adding
  `count_incomplete` and `todo_reasons` as record fields (rather than
  extending the `TestResult.state` sum type) preserves backward compatibility:
  every downstream consumer keeps compiling unchanged.

---

## 13. Limitations, Edge Cases, and Open Questions

1. **`count_incomplete` is not part of the termination logic.** The loop
   condition `is_done state = state.cur_count <= 0 || state.cur_max_gen <= 0`
   is unchanged. A run where most inputs are incomplete will exhaust
   `cur_max_gen` with `count` still very low, producing far fewer than the
   target number of real passes.

2. **The assumption check is suppressed entirely, not adjusted.** When
   `count_incomplete > 0`, `check_if_assumptions` never fires — even if the
   assumption-percentage problem is real. A more precise fix would compute
   an effective target.

3. **No richer step event.** Incomplete cases emit `FalseAssumption`, the
   same value used for `Failed_precondition`. A step-callback consumer cannot
   distinguish them from the event stream alone; it must read
   `count_incomplete` or `todo_reasons` post-hoc.

4. **A 100% incomplete run still reports `Success`.** If every input raises
   a TODO-prefixed `failwith`, the result state is `R.Success` (the initial
   state, never demoted). `is_success res` returns `true` even though the
   property never evaluated on a single complete input. Check `count` and
   `count_incomplete` to distinguish this from a genuine full pass.

5. **`find_example` silently inherits the new semantics.** `find_example`
   calls `Test.check_cell` internally, so a predicate that raises
   `failwith "TODO:..."` will silently skip those cases.

6. **Prefix is literal and case-sensitive.** The check is exactly the
   five-character string `"TODO:"`. Variants like `"todo:"`, `"TODO "`,
   `"TODO :"`, or `" TODO:"` do not match and fall through as normal errors.

---

## 14. Alcotest Backend Integration

This section documents how `src/alcotest/QCheck_alcotest.ml` and
`QCheck_alcotest.mli` make incomplete-case information visible when running
tests through the Alcotest runner.

### 14.1 The Problem

An earlier version of `to_alcotest` delegated entirely to `T.check_cell_exn`:

```ocaml
let run () =
  let call = Raw.callback ~colors ~verbose ~print_res:false ~print in
  T.check_cell_exn ~long ~call ~handler ~rand cell
```

`check_cell_exn` is a convenience wrapper that calls `check_cell` internally
and then immediately raises if the result state is not `R.Success`. Because
it never returns the `TestResult.t`, the `count_incomplete` counter and
`todo_reasons` hashtable accumulated during the run were silently discarded:
the Alcotest output gave no indication that any incomplete cases had been
encountered.

### 14.2 The Current Implementation: Print, Check, and Tag

The run body calls `check_cell` directly, inspects the result, prints the
incomplete-case information if present, delegates the verdict-raising to
`check_result`, and — when the run passed but at least one incomplete
case occurred — raises `Alcotest.incomplete` so the Alcotest runner tags
the case with `[INCOMPLETE]` instead of `[OK]`:

```ocaml
let run () =
  let call = Raw.callback ~colors ~verbose ~print_res:false ~print in
  let res = T.check_cell ~long ~call ~handler ~rand cell in
  let incomplete = Q.TestResult.get_count_incomplete res in
  if incomplete > 0 then begin
    let todo_reasons = Q.TestResult.get_todo_reasons res in
    Printf.printf "  incomplete cases: %d\n" incomplete;
    List.iter (fun (reason, count) ->
      Printf.printf "    TODO: %s (%d times)\n" reason count
    ) todo_reasons
  end;
  T.check_result cell res;
  if incomplete > 0 then
    Alcotest.incomplete (Printf.sprintf "%d incomplete case(s)" incomplete)
```

Five observations about the code:

1. **`check_cell` instead of `check_cell_exn`.** `check_cell` runs the
   campaign and returns the `TestResult.t` without raising. This gives the
   adapter a window to read `count_incomplete` and `todo_reasons` before
   control passes to the Alcotest framework.
2. **Conditional stdout output.** The TODO block is printed only when
   `incomplete > 0`, so runs with no incomplete cases produce no extra
   output — identical to the upstream behavior.
3. **`check_result` preserves the failure-raising contract.** `T.check_result
   cell res` inspects `res.state` and raises `Test_fail` or `Test_error`
   exactly as `check_cell_exn` would have. If the run contained a real
   QCheck failure, this raise fires first and Alcotest tags the test
   `[FAIL]` — the following `Alcotest.incomplete` call is unreachable.
4. **`Alcotest.incomplete` emits the `[INCOMPLETE]` tag.** Reached only
   when `check_result` returned successfully (no real failure) *and*
   `incomplete > 0`. The Alcotest runner catches the exception inside
   `protect_test` and records an `` `Incomplete _`` outcome, which is
   rendered in yellow as `[INCOMPLETE]`, does not count toward failures,
   and does not affect the exit code. Priority overall is FAIL > INCOMPLETE
   > OK.
5. **Requires the patched alcotest.** `Alcotest.incomplete` and the
   matching runtime machinery do not exist in stock alcotest; they are
   additions in the patch living at `../alcotest/` on branch
   `qcheck-inc-incomplete` (based on tag 1.9.1). With a stock-alcotest
   pin or no pin, this bridge fails to compile. See `ALCOTEST.md` for the
   setup and `patches/alcotest-incomplete.patch` for the reproducible
   patch against the 1.9.1 tag.
6. **Alcotest-native backstop, independent of this bridge.** Patched alcotest
   *also* recognises `Failure s when String.is_prefix ~affix:"TODO:" s` in
   `protect_test` and routes it to `` `Incomplete s `` directly — see §3 and
   `ALCOTEST.md`. That path is what makes plain alcotest tests of
   not-yet-implemented code (no QCheck in the loop) also render
   `[INCOMPLETE]`. For QCheck properties, the path is not normally reached:
   QCheck2 catches `Failure s when todo_reason s <> None` *inside* the
   runner at `src/core/QCheck2.ml:1944`, turns it into a counted incomplete
   iteration, and returns without re-raising. So the `TODO:` `Failure` never
   escapes to alcotest's `protect_test` — the bridge's explicit
   `Alcotest.incomplete` call above is the only way `[INCOMPLETE]` is
   reached for QCheck tests. If a refactor ever caused a stray `TODO:`
   failure to leak past QCheck, alcotest's native arm would catch it.

### 14.3 Documentation in `QCheck_alcotest.mli`

A paragraph in the `to_alcotest` docstring describes both the stdout output
and the tag:

```ocaml
(** ...
    When the tested property raises a [Failure] with a ["TODO:..."] message
    (via [failwith]), incomplete case counts and per-reason breakdowns are
    printed to stdout before the result is checked, and the test case is
    tagged [\[INCOMPLETE\]] in the alcotest output (provided the patched
    alcotest exposing {!Alcotest.incomplete} is available).
    ... *)
```

This makes both the behavior and the patched-alcotest requirement
discoverable from the interface file without requiring users to read the
implementation.

### 14.4 The Alcotest Test File: `test/core/lambda_subst_alco.ml`

This file is a self-contained Alcotest executable that exercises the same
four substitution implementations from `lambda_subst.ml` (§9) through the
modified `QCheck_alcotest.to_alcotest` adapter.

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

- No `incomplete_counter` global ref. The direct-runner file uses a manual
  counter as a cross-check; the alcotest file relies entirely on
  `QCheck2.TestResult.get_count_incomplete` and `get_todo_reasons` (read by
  the adapter).
- No `run_direct` / `run_direct_incomplete` custom runner functions. The
  runner is `QCheck_alcotest.to_alcotest` followed by `Alcotest.run`.
- Three `print_triple` variants (`print_triple`, `print_triple'`,
  `print_triple''`) for different display formats; only `print_triple` is
  wired into the test spec.

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

### 14.5 Before vs After: Alcotest Incomplete Visibility

| Aspect                           | Before                   | After                                                                 |
|----------------------------------|--------------------------|-----------------------------------------------------------------------|
| API called                       | `T.check_cell_exn`       | `T.check_cell` + `T.check_result` + conditional `Alcotest.incomplete` |
| `TestResult.t` accessible        | No (consumed internally) | Yes (inspected before raising)                                        |
| Incomplete count printed         | No                       | Yes, when `count_incomplete > 0`                                      |
| Per-reason breakdown printed     | No                       | Yes, one line per distinct TODO reason                                |
| Per-test status tag              | `[OK]` or `[FAIL]`       | `[OK]` / `[FAIL]` / `[INCOMPLETE]` (tri-valued)                       |
| Exit-code impact of incomplete   | 0                        | 0 (unchanged — `[INCOMPLETE]` is not a failure)                       |
| Summary "N tests run" counts     | Incomplete counted as OK | Incomplete counted in N, separate from failures                       |
| Alcotest verdict on real failure | `[FAIL]`                 | `[FAIL]` (priority FAIL > INCOMPLETE > OK)                            |
| Backward compat (no incomplete)  | N/A                      | Identical output — no extra lines, no tag change                      |
| Alcotest-side requirement        | Stock alcotest           | Patched alcotest (`../alcotest/`, branch `qcheck-inc-incomplete`)     |

---

## 15. Summary of Touched Locations

### 15.1 Inside this repo

| File                                 | Change                                                                                                                                                         |
|--------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `src/core/QCheck2.ml`                | `todo_reason` prefix-extraction helper in `module Test`                                                                                                        |
| `src/core/QCheck2.ml`                | `count_incomplete` field and `todo_reasons` hashtable in `TestResult.t`                                                                                        |
| `src/core/QCheck2.ml`                | `get_count_incomplete` and `get_todo_reasons` accessors                                                                                                        |
| `src/core/QCheck2.ml`                | Skip TODO-prefixed `Failure` candidates during shrinking (two locations)                                                                                       |
| `src/core/QCheck2.ml`                | Runner arm: catch `Failure msg`, dispatch on `todo_reason`, record count + reason, continue; fall through to `handle_exn` for non-TODO `Failure`               |
| `src/core/QCheck2.ml`                | Suppress "too many discards" warning when `count_incomplete > 0`                                                                                               |
| `src/core/QCheck2.ml`                | Initialize `count_incomplete = 0` and `todo_reasons` in `check_cell`                                                                                           |
| `src/core/QCheck2.mli`               | Doc-only `{1 Incremental PBT}` section describing the `failwith "TODO:..."` convention                                                                         |
| `src/core/QCheck2.mli`               | Expose `get_count_incomplete` and `get_todo_reasons` in `TestResult`                                                                                           |
| `src/alcotest/QCheck_alcotest.ml`    | `to_alcotest` uses `check_cell` + `check_result`; prints incomplete breakdown before raising; raises `Alcotest.incomplete` on successful-but-incomplete runs to emit the `[INCOMPLETE]` tag |
| `src/alcotest/QCheck_alcotest.mli`   | Document TODO-aware behaviour *and* the `[INCOMPLETE]` tag + patched-alcotest requirement in the `to_alcotest` docstring                                       |
| `test/core/dune`                     | `lambda_subst` and `lambda_subst_alco` executable stanzas                                                                                                      |
| `test/core/lambda_subst.ml`          | Thesis experiment: 4 substitutions, generators, property, direct runners                                                                                       |
| `test/core/lambda_subst_alco.ml`     | Alcotest variant of the thesis experiment (same 4 implementations via `QCheck_alcotest`)                                                                       |
| `ALCOTEST.md`                        | End-to-end setup reference for the external patched alcotest (sibling clone + `opam pin`)                                                                      |
| `patches/alcotest-incomplete.patch`  | Consolidated patch against alcotest `1.9.1`, shipped in-repo so the alcotest changes are reproducible from scratch                                             |

### 15.2 Outside this repo (runtime dependency)

| Location                               | Role                                                                                                             |
|----------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `../alcotest/` (sibling clone)         | Working tree consumed via `opam pin add alcotest ../alcotest --kind=path`; must be on branch `qcheck-inc-incomplete` at build time |
| `../alcotest/src/alcotest-engine/…`    | 7 files, ≈ 25 lines added: new `Incomplete` exception, `` `Incomplete _`` variant, printer branches, helper      |

All other modules in this repo are untouched; consumers that never raise
`failwith "TODO:..."` observe identical behavior to upstream QCheck2, and
(as long as they don't call `Alcotest.incomplete` directly) observe
identical behavior to upstream alcotest.
