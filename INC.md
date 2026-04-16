# Incremental PBT — QCheck2 modifications

This document describes the surgical changes made to `src/core/QCheck2.ml` (and
its interface `src/core/QCheck2.mli`) that upgrade QCheck's binary `Pass/Fail`
model into the **trivalued semantics** `Pass / Fail / Unimplemented` proposed
in the *Incremental Property-Based Testing* thesis. It is intended as a
developer reference: what changed, where, and why it works.

---

## 1. Motivation

Traditional PBT assumes the system under test is fully implemented. In real
incremental workflows that assumption breaks: programmers leave branches
stubbed with `raise NotImplemented` / `raise IncompleteCode`, commit, and keep
iterating. A stock QCheck run over such a program collapses in two ways:

1. **Early abort.** The first input that reaches an unimplemented branch
   raises an exception → QCheck records an *error*, shrinks it, and stops.
   Every already-implemented branch remains unvalidated.
2. **Semantic ambiguity.** The same verdict (*error*) is produced by real
   logic bugs and by explicitly-deferred code. The developer cannot tell them
   apart without reading the stack trace.

The thesis' remedy is a third verdict, orthogonal to `Pass` and `Fail` and to
the pre-existing precondition-driven `Discard`:

| Verdict         | Meaning                                                  |
|-----------------|----------------------------------------------------------|
| `Pass`          | Property held on a valid input.                          |
| `Fail`          | Property violated (or uncontrolled exception).           |
| `Discard`       | Input failed a precondition — not a result.              |
| `Unimplemented` | Input hit an explicitly-deferred branch — not a failure. |

Design constraints carried over from the thesis (§5.3):

- **Non-intrusive:** no change to SUT signatures, no new import required.
- **Automatic propagation:** the signal bubbles through intermediate layers
  without manual instrumentation — exceptions are the natural fit in OCaml.
- **Backwards-compatible:** if no code raises `IncompleteCode`, QCheck behaves
  exactly like upstream.

---

## 2. The `IncompleteCode` exception

The signal is a **user-defined** exception named `IncompleteCode`. The user
writes, at the top of their test file:

```ocaml
exception IncompleteCode
```

and raises it in any not-yet-implemented branch of the SUT.

QCheck does **not** declare this exception itself. It identifies it by name at
runtime via `Printexc.exn_slot_name`, which accepts any of:

- `IncompleteCode` (raised from the toplevel);
- `Lambda_subst.IncompleteCode` (module-qualified);
- `Dune__exe__Lambda_subst.IncompleteCode` (dune-mangled executable name).

This keeps the framework decoupled from user code: the user doesn't need to
open a QCheck module, and every pre-existing `IncompleteCode` in the ecosystem
becomes usable as-is.

The detector lives in `src/core/QCheck2.ml:1803-1814`:

```ocaml
let is_incomplete_code (e : exn) : bool =
  let name = Printexc.exn_slot_name e in
  let target = "IncompleteCode" in
  let n = String.length name in
  let t = String.length target in
  n >= t
  && String.sub name (n - t) t = target
  && (n = t || name.[n - t - 1] = '.')
```

The final `n = t || name.[n - t - 1] = '.'` guard is what prevents
`MyIncompleteCode` or `IncompleteCodeXYZ` from masquerading as the real
signal: the name must either equal `IncompleteCode` exactly, or be prefixed by
a dotted qualifier.

---

## 3. Tracking the new verdict in `TestResult`

A new integer counter records how many generated cases were classified as
`Unimplemented`. It is added as a mutable field of the `TestResult.t` record
(`src/core/QCheck2.ml:1504`):

```ocaml
type 'a t = {
  mutable state : 'a state;
  mutable count : int;
  mutable count_gen : int;
  mutable count_incomplete : int;   (* ← NEW *)
  ...
}
```

An accessor is exposed (`src/core/QCheck2.ml:1516`):

```ocaml
let get_count_incomplete {count_incomplete; _} = count_incomplete
```

and published in the interface (`src/core/QCheck2.mli:1698-1700`) so that
custom runners can read it:

```ocaml
val get_count_incomplete : _ t -> int
(** [get_count_incomplete t] returns the number of cases that raised
    [IncompleteCode] and were skipped. *)
```

Rationale for a counter rather than a new constructor on the `state` sum type:
- Preserves the existing `state` ADT (`Success | Failed _ | Error _ |
  Failed_other _`) so every downstream consumer (alcotest, ounit runners, PPX
  tests, the old pretty-printer) keeps compiling unchanged.
- Satisfies §5.6 "**backwards-compatible**": if no case raises
  `IncompleteCode`, `count_incomplete` stays `0` and everything behaves
  identically to upstream.
- Gives us the **effective coverage** metric from §5.5 almost for free:
  `Pass + Fail  =  count - count_incomplete`.

The counter is initialized in `check_cell` (`src/core/QCheck2.ml:1999`) and
lives for the duration of a single test run.

---

## 4. The runner: catch, count, continue

The thesis (§5.3.2) describes the runner modification as a discriminating
`try/except` around the property evaluation:

```python
def run_property_safe(prop, input):
    try:
        if prop(input): return Success     # Pass (green)
        else:           return Failure     # Fail (red)
    except NotYetImplemented:
        return Unimplemented               # Unimplemented (yellow, NEW)
    except Exception as e:
        return Failure(e)                  # Fail by crash
```

In QCheck2 this maps to a new match arm inside the exception handler of the
main per-input step. `src/core/QCheck2.ml:1939-1946`:

```ocaml
| Failed_precondition | No_example_found _ ->
  state.step state.test.name state.test input FalseAssumption;
  CR_continue
| e when is_incomplete_code e ->
  (* incremental PBT: incomplete case, count and continue *)
  state.res.R.count_incomplete <- state.res.R.count_incomplete + 1;
  state.step state.test.name state.test input FalseAssumption;
  CR_continue
| e ->
  let bt = Printexc.get_backtrace () in
  handle_exn state input_tree e bt
```

Three things happen, in order:

1. The counter is bumped. This is the single source of truth for the new
   verdict — no state transition on `res.state`, no counterexample recorded.
2. `step` is called with `FalseAssumption`, which reuses the existing "this
   input didn't count toward coverage" bookkeeping machinery. Stats and
   collectors will treat an unimplemented case exactly like a discarded one
   (which is the right behavior: neither confirms nor refutes the property).
3. `CR_continue` is returned, so the outer generation loop moves to the next
   input. **The campaign does not abort.** This is the central change.

Crucially this arm lives *before* the catch-all `| e -> handle_exn ...`, so
`IncompleteCode` is caught before the shrinking machinery is invoked. That
matters because, per §5.4, we never want to shrink an unimplemented case.

---

## 5. Shrinking policy: never shrink into `Unimplemented`

The thesis §5.4 is explicit:

> **No contraer Unimplemented.** Si un caso cae en código incompleto, no se
> intenta minimizar. [...] El estado `Unimplemented` se considera un
> "callejón sin salida" informativo, no un error a depurar.

There are two reasons:

- A smaller input could accidentally *dodge* the unimplemented branch and
  cross the boundary into a passing case, producing a false "minimal
  counterexample" that is really just a minimal green case.
- A smaller input could hit a *different* unimplemented branch, giving the
  developer no information about the real defect.

`IncompleteCode` shouldn't even *enter* shrinking because of the guard in §4,
but shrinking is also invoked transitively when an already-failing case is
being minimized. During that recursive descent, some children of the shrink
tree may themselves raise `IncompleteCode`. We must discard them. Two symmetric
changes do this (`src/core/QCheck2.ml:1840` and `:1856`):

```ocaml
with
| Failed_precondition | No_example_found _ -> None
| e when is_incomplete_code e -> None   (* ← NEW: skip incomplete candidates *)
| e when is_err -> Some (x_tree, Shrink_exn e, [])
```

Returning `None` signals "this shrink candidate is not an improvement, move
on". The shrinker will therefore never settle on an `IncompleteCode`-raising
node as the minimal counterexample for a *different* failure.

Both the QCheck1-compatible path (uses a user-supplied shrink function) and
the QCheck2 path (uses the shrink tree attached to the generator) need the
clause, which is why the change appears twice.

---

## 6. Guarding the "too many discards" warning

QCheck emits a warning when more than a configurable fraction of inputs were
rejected by `==>`-style preconditions — a signal that the generator is
producing garbage. Unimplemented cases trigger the same bookkeeping
(`FalseAssumption`), so without a guard, a test that legitimately skips many
inputs because they hit deferred code would be flagged as having a broken
generator.

The fix is a one-liner in `check_if_assumptions`
(`src/core/QCheck2.ml:1964`):

```ocaml
if R.is_success res && res.R.count_incomplete = 0
   && percentage_of_count < assm_frac then (
  (* emit the warning *)
)
```

If any unimplemented case was counted, the warning is suppressed — consistent
with the thesis' position that `Unimplemented` is *expected* during
incremental development and is not evidence of a misconfigured generator.

---

## 7. End-to-end flow

Putting the pieces together, the lifecycle of a generated input is:

```
                     ┌─ law returns true  → Pass  (count += 1)
                     │
  gen → input → law ─┼─ law returns false → Fail  (enter shrinker, record counterex.)
                     │
                     ├─ raise IncompleteCode
                     │    → count_incomplete += 1
                     │    → step(…, FalseAssumption)
                     │    → CR_continue  (skip shrinking, next input)
                     │
                     └─ raise any other exn
                          → handle_exn → shrinker → Error verdict
```

and the final `TestResult` carries three numbers that together describe the
campaign:

- `get_count`            — inputs that reached the law (`Pass + Fail`).
- `get_count_gen`        — inputs actually generated (includes discards).
- `get_count_incomplete` — inputs swallowed by `IncompleteCode`.

Users wanting the §5.5 *Effective Coverage* metric compute it directly:

```
effective = count / (count + count_incomplete)
```

---

## 8. Using the feature

Minimal usage from a user's point of view:

```ocaml
exception IncompleteCode

let rec subst x s = function
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (a, b) -> App (subst x s a, subst x s b)
  | Abs _ -> raise IncompleteCode    (* deferred case *)

let prop = QCheck2.Test.make ~name:"capture avoidance" ~count:1000 gen check
```

When the user then runs the test through a custom runner that reads
`QCheck2.TestResult.get_count_incomplete`, they see, for example:

```
=== capture avoidance ===
PASS (passed: 720, incomplete cases: 280)
```

720 inputs validated the branches that *are* implemented; 280 hit the
deferred `Abs` case and were counted rather than aborting the run. The
working example in `test/core/lambda_subst.ml` exercises four increasingly
partial `subst` implementations against the same property to demonstrate
`Pass`, `Fail`, and `Unimplemented` coexisting in a single campaign.

---

## 9. Summary of touched locations

| File                      | Line(s)       | Change                                                   |
|---------------------------|---------------|----------------------------------------------------------|
| `src/core/QCheck2.ml`     | 1504          | `count_incomplete` field in `TestResult.t`               |
| `src/core/QCheck2.ml`     | 1516          | `get_count_incomplete` accessor                          |
| `src/core/QCheck2.ml`     | 1803–1814     | `is_incomplete_code` name-based detector                 |
| `src/core/QCheck2.ml`     | 1840, 1856    | Skip `IncompleteCode` children during shrinking          |
| `src/core/QCheck2.ml`     | 1942–1946     | Runner arm: count `IncompleteCode` and continue          |
| `src/core/QCheck2.ml`     | 1964          | Suppress "too many discards" warning when incomplete > 0 |
| `src/core/QCheck2.ml`     | 1999          | Initialize `count_incomplete = 0` in `check_cell`        |
| `src/core/QCheck2.mli`    | 1698–1700     | Expose `get_count_incomplete` in `TestResult`            |

All other modules are untouched; consumers that never raise `IncompleteCode`
observe identical behavior to upstream QCheck2.
