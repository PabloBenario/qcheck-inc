# Patched alcotest — external sibling clone

This repo depends on a **patched copy of alcotest** that lives as a separate
clone at `../alcotest/` (sibling of `qcheck-inc/`). The patch adds a fourth
verdict tag, `[INCOMPLETE]` (yellow), so the alcotest runner can flag tests
that hit `failwith "TODO:..."` cases without a real failure.

Upstream alcotest has only `[OK]` / `[FAIL]` / `[SKIP]`. Our patch adds
`[INCOMPLETE]` as a fourth outcome that is **not** counted as a failure,
**not** counted toward the nonzero exit code, but **is** counted toward the
summary's "N tests run" total.

`[INCOMPLETE]` is produced by **one convention only**: any alcotest test
(QCheck or not) that raises `Failure` whose message starts with `"TODO:"`.
Typically via `failwith "TODO: not implemented yet"` inside the code under
test. Patched alcotest's `protect_test` matches the prefix and routes to
`` `Incomplete ``. No custom alcotest API, no new exception; `failwith` is
`Stdlib`, always in scope.

If nothing in the test suite raises `Failure "TODO:..."`, the patched
alcotest behaves identically to upstream — the added code paths are
simply unreachable.

## Two variants

Two branch pairs exist, one in each repo, exploring different ways to surface
the per-test stats in the alcotest output:

| Branch (both repos) | How stats appear | `Alcotest.set_test_suffix` |
|---------------------|-----------------|---------------------------|
| `with_set_suffix` | On the verdict line: `[FAIL] … 48 passed, 11 incomplete, 1 failed` | Yes — added to alcotest's public API |
| `without_set_suffix` | In the failure exception message body | No — no new public API |

Both branches produce `[INCOMPLETE]` for pure-incomplete tests. The
`without_set_suffix` variant also works against stock (unpatched) alcotest,
but `[INCOMPLETE]` will then display as `[FAIL]`.

Use `run-inc-variants.zsh` (in `experimental/`) to switch and run both
automatically:

```sh
../run-inc-variants.zsh with     # with_set_suffix
../run-inc-variants.zsh without  # without_set_suffix
../run-inc-variants.zsh          # both in sequence
```

### Why `without_set_suffix` cannot show stats on the verdict line

The verdict line format is entirely controlled by alcotest:

```
  [TAG]  group_name  index  test_doc
```

`test_doc` is a string passed at **test registration time** and is fixed before
the test runs. There is no mechanism in stock alcotest to update the verdict line
after execution. The only hooks available to `QCheck_alcotest.ml` at runtime are
the exception message (visible in the error box body, not the verdict line) and
stdout (which alcotest's `\r`-overwrite stomps over).

`set_test_suffix` is the minimal possible alcotest change that enables verdict-line
annotations — a single mutable ref (`current_test_suffix : string option ref`) read
and cleared when `pp.ml` renders the verdict. There is no smaller hook.

As a result, `without_set_suffix` is genuinely less informative: stats only appear
in the error box body (and only when there are incomplete cases), never on the
verdict line. Tests with no incomplete cases (pure pass or pure fail) show no stats
at all. `with_set_suffix` always shows counts for every test at a glance.

The only reason to prefer `without_set_suffix` is compatibility with stock alcotest:
it compiles and runs unchanged, with `[INCOMPLETE]` degrading silently to `[FAIL]`.

## Layout

```
experimental/
├── alcotest/                   # git clone of mirage/alcotest, branch with_set_suffix or without_set_suffix
│                               # based on tag 1.9.1, patch commits on top
└── qcheck-inc/                 # this repo
    └── src/alcotest/           # our QCheck ↔ alcotest bridge (QCheck_alcotest)
```

No `vendor/` directory, no submodule for alcotest — the link is purely via
`opam pin`.

## First-time setup

Two prerequisites: a clone of `mirage/alcotest` as a sibling of this repo,
and an opam pin pointing at it.

### If `../alcotest/` does not yet exist

```sh
git clone git@github.com:pablobenario/alcotest.git ../alcotest
git -C ../alcotest checkout without_set_suffix   # or with_set_suffix
```

### If `../alcotest/` already exists on upstream `main`

```sh
git -C ../alcotest fetch --tags
git -C ../alcotest switch without_set_suffix   # or with_set_suffix
```

### Pin opam to the sibling clone (one-time per switch)

```sh
opam pin add alcotest ../alcotest --kind=path --yes
```

`--kind=path` tells opam to track the working tree, so source edits in
`../alcotest/` propagate on the next `dune build` (no re-pin required).

Verify:

```sh
opam pin list | grep alcotest
# alcotest.1.9.1  rsync  file:///…/experimental/alcotest
```

## Important: alcotest branch must match the qcheck-inc branch

The pin follows the **working tree** of `../alcotest/`, not a specific branch.
Both repos must be on matching branches (`with_set_suffix` or `without_set_suffix`)
for a consistent build. If you switch `../alcotest/` to `main`, the next
`dune build` will link against unpatched alcotest and `failwith "TODO:..."` cases
will silently be tagged `[FAIL]` instead of `[INCOMPLETE]`. No build error —
purely behavioural degradation.

Quick guard before building:

```sh
git -C ../alcotest branch --show-current   # expect: with_set_suffix or without_set_suffix
git -C ../qcheck-inc branch --show-current # expect: same branch
```

Use `run-inc-variants.zsh` to switch both repos atomically (see "Two variants" above).
Or switch manually:

```sh
git -C ../alcotest switch with_set_suffix
git -C ../qcheck-inc switch with_set_suffix
opam reinstall alcotest --yes
```

## Working on the patch

### Inspect the current diff against upstream

```sh
git -C ../alcotest log 1.9.1..HEAD --oneline
git -C ../alcotest diff 1.9.1..HEAD -- src/
```

Files touched by the patch:

| File                                                              | Purpose                                                                                                                                                                                                                                                                                         |
|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
Files touched in **both** variants:

| File | Purpose |
|------|---------|
| `src/alcotest-engine/model.ml` | Add `` `Incomplete of string`` variant to `Run_result.t`; mark non-failing |
| `src/alcotest-engine/core.ml` | `has_run` returns true on `Incomplete`; `protect_test` routes `Failure s` with `"TODO:"` prefix to `` `Incomplete s `` |
| `src/alcotest-engine/pp.ml` | Five tag branches (colour, label, error-pretty, tag-of-result, compact char); `Result`-arm renders multi-line Incomplete messages indented under the verdict |
| `test/e2e/alcotest/passing/incomplete_in_test.ml` | Minimal e2e regression: one `[OK]` + one `failwith "TODO:..."` → `[INCOMPLETE]`, exit 0 |
| `test/e2e/alcotest/passing/incomplete_in_test.expected` | Sanitised expected output |
| `test/e2e/alcotest/passing/incomplete_breakdown_in_test.ml` | E2e regression for the multi-line breakdown rendering |
| `test/e2e/alcotest/passing/incomplete_breakdown_in_test.expected` | Sanitised expected output |
| `test/e2e/alcotest/passing/dune.inc` | Auto-regenerated to wire both tests into the `runtest` alias |

Additional files touched only in **`with_set_suffix`**:

| File | Purpose |
|------|---------|
| `src/alcotest-engine/pp_intf.ml` | Expose `current_test_suffix : string option ref` in `module type Pp` |
| `src/alcotest-engine/pp.ml` | Per-test `current_test_suffix` ref + `~suffix` arg to `pp_result_full` for the inline stats suffix |
| `src/alcotest-engine/test.ml` | `let set_test_suffix s = Pp.current_test_suffix := Some s` |
| `src/alcotest-engine/test.mli` | `val set_test_suffix : string -> unit` (re-exported through `Alcotest`) |

The e2e regression tests live inside alcotest's own test harness and guard
against accidental removal of the `when`-guard and the breakdown-rendering path.

### Make a change

```sh
cd ../alcotest
$EDITOR src/alcotest-engine/pp.ml       # or whichever file
git commit -am "..."                    # keep history focused per logical change
cd ../qcheck-inc
opam reinstall alcotest --yes           # re-rsync the pin and rebuild alcotest
dune build                              # link qcheck-inc against the updated alcotest
```

`dune build` alone does **not** pick up source edits in `../alcotest/` — the
opam pin is a live *source* (`--kind=path`), but re-rsync only happens on an
opam install/reinstall trigger. Run `opam reinstall alcotest --yes` after any
edit to files under `../alcotest/src/`, then `dune build`.

### Test the patch end-to-end

```sh
dune build                                     # must succeed silently
dune exec test/core/lambda_subst_alco.exe      # [INCOMPLETE] should appear for
                                               # the incomplete-only test
dune exec test/core/lambda_subst.exe           # direct QCheck runner
                                               # (alcotest-independent, sanity check)
```

Expected alcotest output fragment (verbose, `-v`):

```
  [OK]          generators            0   Generator Validity (Well-Scoped).   10000 passed
  [OK]          generators            1   Shrinker Validity.   1000 passed
  [FAIL]        substitution          0   Capture Avoidance (naive/buggy subst).   16 passed, 1 failed
  [INCOMPLETE]  substitution          1   Capture Avoidance (correct subst bu...   730 passed, 470 incomplete
                incomplete cases: 470
                  subst_incom: Abs case (470 times)
  [FAIL]        substitution          2   Capture Avoidance (mixed: buggy + i...   14 passed, 2 incomplete, 1 failed
  [FAIL]        substitution          3   Capture Avoidance (throws incomplet...   395 passed, 164 incomplete, 1 failed
```

Two per-test annotations (output above is from `with_set_suffix`):
- **Inline stats on verdict line** (`with_set_suffix` only): `N passed[, M incomplete][, K failed]`
  appended after the test doc. Wired via `Alcotest.set_test_suffix`: the bridge sets
  the suffix from the QCheck `TestResult` before returning or raising, and patched
  `pp.ml`'s `Result` arm reads and clears it when rendering the verdict. In
  `without_set_suffix`, stats appear in the failure message body instead.
- **Breakdown below `[INCOMPLETE]`** (both variants): the per-reason TODO list indented
  at column 16 (`left_gutter + left_tag`). Encoded into the `failwith` message and
  parsed by patched alcotest's `Result` arm — only fires on `` `Incomplete ``.

For `[FAIL]` tests that also have incomplete cases, the per-reason list is
additionally appended to the failure-box body below the QCheck
counter-example (see "The bridge" section below).

### Verify the native `failwith "TODO:..."` path — sibling demo project

Independent of QCheck, a plain alcotest test that calls `failwith "TODO:..."`
should render `[INCOMPLETE]` rather than `[FAIL]`. The canonical
demonstration is the sibling project at `../alcotest-incomplete-demo/` —
its own opam switch, pinning this repo's patched alcotest and qcheck-inc,
so it exercises the full real-consumer path (switch bootstrap, pin,
install, link).

Layout:

```
experimental/
├── alcotest/                       # patched alcotest
├── qcheck-inc/                     # this repo
└── alcotest-incomplete-demo/       # sibling demo — own _opam/
    ├── arith_stubs.{ml,mli}        # library with failwith "TODO:..."
    ├── test_arith_stubs.ml         # plain alcotest tests
    └── dune / dune-project / README.md
```

First-time bootstrap (see that directory's `README.md` for the full
walkthrough):

```sh
cd ../alcotest-incomplete-demo
opam switch create . 5.4.0 --no-install --yes && eval $(opam env)
opam pin add alcotest ../alcotest --kind=path --yes
opam pin add qcheck-core ../qcheck-inc --kind=path --yes
opam pin add qcheck ../qcheck-inc --kind=path --yes
opam pin add qcheck-alcotest ../qcheck-inc --kind=path --yes
dune runtest
```

Expected output fragment:

```
  [OK]          implemented   0   add.
  [OK]          implemented   1   multiply non-negative.
  [INCOMPLETE]  stubs         0   multiply negative arg (TODO).
  [INCOMPLETE]  stubs         1   divide (TODO).

Test Successful in … 4 tests run.
```

Exit 0. `[INCOMPLETE]` does not contribute to the exit code.

The test file there (`test_arith_stubs.ml`) uses only `open Arith_stubs`
and standard `Alcotest.(check ...) / test_case / run` calls — no
QCheck, no patched-alcotest-specific identifier. All the `[INCOMPLETE]`
tagging comes from patched alcotest's `protect_test` matching the
`"TODO:"` prefix on `Failure` messages raised inside the library.

## Rebasing onto a newer upstream alcotest release

```sh
git -C ../alcotest fetch origin
git -C ../alcotest checkout <newer-tag>                # e.g. 1.10.0
git -C ../alcotest switch with_set_suffix               # or without_set_suffix
git -C ../alcotest rebase <newer-tag>                  # resolve any conflicts
opam reinstall alcotest --yes                          # pick up the new sources
dune clean && dune build
```

The `without_set_suffix` patch is small — ~20 added lines across 3 files under
`src/alcotest-engine/` (the `[INCOMPLETE]` tag plumbing and the multi-line
breakdown rendering in `pp.ml`), plus two tiny regression guards and the
mechanical `dune.inc` regeneration. No new public identifiers, no refactors —
conflicts on a routine upstream bump should be rare and mechanical.

The `with_set_suffix` patch adds ~15 more lines across `pp_intf.ml`,
`pp.ml`, `test.ml`, and `test.mli` for the per-test suffix hook and one
user-facing identifier (`Alcotest.set_test_suffix`).

## Reverting to stock alcotest

```sh
opam pin remove alcotest --yes
```

This restores the registry version. The clone at `../alcotest/` is untouched;
re-pin with `opam pin add alcotest ../alcotest --kind=path --yes` (and make
sure the branch is `with_set_suffix` or `without_set_suffix`) to get the
`[INCOMPLETE]` tag back. After reverting to stock, `dune exec test/core/lambda_subst_alco.exe`
still compiles and runs — the bridge uses only `failwith`, which is
stdlib — but `failwith "TODO:..."` cases now get the standard `[FAIL]`
treatment instead of `[INCOMPLETE]`, and incomplete-only runs exit 1
instead of 0. Silent behavioural degradation, not a build error.

## The bridge: `src/alcotest/QCheck_alcotest.ml`

> The description below applies to the **`with_set_suffix`** variant. In
> `without_set_suffix` the bridge embeds the stats in the exception message
> body instead of calling `Alcotest.set_test_suffix`.

The QCheck → alcotest adapter never writes to stdout during test execution.
All per-test information flows through two channels: (1) the inline stats
suffix (`N passed, M incomplete, K failed`), set via
`Alcotest.set_test_suffix` before the closure returns/raises, and (2)
exception messages encoding the incomplete breakdown and/or wrapping a
QCheck failure. Patched alcotest decodes both and renders cleanly on the
verdict line (keeping the `\r`-overwrite of the pending `...` line intact).

For every QCheck test the bridge computes stats from the `TestResult`
(`get_count`, `get_count_incomplete`, `get_state`) and calls
`Alcotest.set_test_suffix` once, regardless of the outcome. Outcome-specific
behaviour then branches as follows:

- Real QCheck failure, `count_incomplete = 0` → `check_result` raises →
  alcotest tags `[FAIL]`, renders the counter-example in the failure box,
  and appends the inline stats suffix to the verdict line.
- Real QCheck failure, `count_incomplete > 0` → bridge catches the
  exception, wraps its `Printexc.to_string` message with a newline-separated
  per-reason list (2-space indent), re-raises as `Failure msg` preserving
  the original backtrace via `Printexc.raise_with_backtrace` → alcotest tags
  `[FAIL]`, renders the merged message in the failure box, and appends the
  inline stats suffix.
- No failure, `count_incomplete > 0` → bridge raises
  `failwith "TODO:\nincomplete cases: N\n  reason_a (a times)\n  reason_b (b times)…"` →
  patched alcotest's `protect_test` recognises the `TODO:` prefix → tags
  `[INCOMPLETE]`, appends the inline stats suffix, and `pp.ml`'s `Result`
  arm renders the lines after `TODO:` indented under the verdict at column
  `left_total` (16).
- No failure, no incompletes → closure returns `()` → alcotest tags `[OK]`
  and appends the inline stats suffix.

The `failwith` call is only reached when the QCheck2 framework actually
incremented `count_incomplete`, which happens exclusively in the
`| Failure msg when todo_reason msg <> None` arm of the runner. Thus the
entire `[INCOMPLETE]` feature is gated on a test actually using
`failwith "TODO:..."`; it's opt-in from both sides. A plain single-line
`failwith "TODO: reason"` (e.g. from a non-QCheck alcotest test, as in
`../alcotest-incomplete-demo/`) carries no breakdown and renders the same
as before: just the `[INCOMPLETE]` verdict line, nothing below.

## See also

- `INC.md` — the `failwith "TODO:..."` convention and QCheck2 internals
  that feed `count_incomplete` and `todo_reasons`.
