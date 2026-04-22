# Patched alcotest — external sibling clone

This repo depends on a **patched copy of alcotest** that lives as a separate
clone at `../alcotest/` (sibling of `qcheck-inc/`). The patch adds a fourth
verdict tag, `[INCOMPLETE]` (yellow), so the alcotest runner can flag tests
that hit `failwith "TODO:..."` cases without a real failure.

Upstream alcotest has only `[OK]` / `[FAIL]` / `[SKIP]`. Our patch adds
`[INCOMPLETE]` as a fourth outcome that is **not** counted as a failure,
**not** counted toward the nonzero exit code, but **is** counted toward the
summary's "N tests run" total.

There are two equal ways to produce `[INCOMPLETE]`:

1. **Convention** — any alcotest test (QCheck or not) that raises `Failure`
   whose message starts with `"TODO:"`. Typically via `failwith "TODO: not
   implemented yet"` inside the code under test. Recognised by `protect_test`
   in patched alcotest.
2. **Programmatic** — `Alcotest.incomplete "reason"` raises a new
   `Alcotest.Incomplete` exception, also caught by `protect_test`. Mirrors
   `Alcotest.skip ()`. Used by the `QCheck_alcotest` bridge to roll up
   multiple QCheck-iteration TODOs into a single alcotest outcome.

If nothing in the test suite triggers either path, the patched alcotest
behaves identically to upstream — the added code paths are simply unreachable.

## Layout

```
experimental/
├── alcotest/                   # git clone of mirage/alcotest, branch qcheck-inc-incomplete
│                               # based on tag 1.9.1, one patch commit on top
└── qcheck-inc/                 # this repo
    ├── patches/
    │   └── alcotest-incomplete.patch   # the patch, for reproducibility
    └── src/alcotest/           # our QCheck ↔ alcotest bridge (QCheck_alcotest)
```

No `vendor/` directory, no submodule for alcotest — the link is purely via
`opam pin`.

## First-time setup

Two prerequisites: a clone of `mirage/alcotest` as a sibling of this repo,
and an opam pin pointing at it.

### If `../alcotest/` does not yet exist

```sh
git clone git@github.com:mirage/alcotest.git ../alcotest
git -C ../alcotest checkout 1.9.1
git -C ../alcotest switch -c qcheck-inc-incomplete
git -C ../alcotest am ./patches/alcotest-incomplete.patch
```

### If `../alcotest/` already exists on upstream `main`

```sh
git -C ../alcotest fetch --tags
git -C ../alcotest checkout 1.9.1
git -C ../alcotest switch -c qcheck-inc-incomplete
git -C ../alcotest am ./patches/alcotest-incomplete.patch
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

## Important: branch must be `qcheck-inc-incomplete` at build time

The pin follows the **working tree** of `../alcotest/`, not a specific branch.
If you switch `../alcotest/` back to `main` (to pull upstream, test something,
etc.), the next `dune build` inside `qcheck-inc` will start linking against
unpatched alcotest and any use of `Alcotest.incomplete` will fail to compile.

Quick guard before building:

```sh
git -C ../alcotest branch --show-current   # expect: qcheck-inc-incomplete
```

Switch back if needed:

```sh
git -C ../alcotest switch qcheck-inc-incomplete
```

## Working on the patch

### Inspect the current diff against upstream

```sh
git -C ../alcotest log 1.9.1..HEAD --oneline
git -C ../alcotest diff 1.9.1..HEAD -- src/
```

Files touched by the patch (all under `../alcotest/src/alcotest-engine/`):

| File           | Purpose                                                                               |
|----------------|---------------------------------------------------------------------------------------|
| `model.ml`     | Add `` `Incomplete of string`` variant to `Run_result.t`; mark non-failing            |
| `core_intf.ml` | Declare `exception Incomplete of string` inside `Core.V1`                             |
| `core.ml`      | Define and re-export the exception; `has_run` returns true; `protect_test` catches both `Incomplete` *and* `Failure "TODO:..."` |
| `pp_intf.ml`   | Extend the tag polymorphic variant                                                    |
| `pp.ml`        | Five branches: colour, label, error-pretty, tag-of-result, compact char               |
| `test.ml`      | `let incomplete reason = raise (Core.V1.Incomplete reason)`                           |
| `test.mli`     | `val incomplete : string -> 'a` + docstring                                           |

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

### Refresh the committed patch file

After committing changes inside `../alcotest/`, regenerate the patch so
`patches/alcotest-incomplete.patch` stays in sync with the branch:

```sh
git -C ../alcotest format-patch 1.9.1..qcheck-inc-incomplete --stdout \
  > patches/alcotest-incomplete.patch
git add patches/alcotest-incomplete.patch
git commit -m "Refresh alcotest patch"
```

The patch file is the only record of the alcotest changes inside this repo,
so keeping it current is how we stay reproducible without a submodule.

### Test the patch end-to-end

```sh
dune build                                     # must succeed silently
dune exec test/core/lambda_subst_alco.exe      # [INCOMPLETE] should appear for
                                               # the incomplete-only test
dune exec test/core/lambda_subst.exe           # direct QCheck runner
                                               # (alcotest-independent, sanity check)
```

Expected alcotest output fragment:

```
  [OK]          generators            0   Generator Validity (Well-Scoped).
  [OK]          generators            1   Shrinker Validity.
> [FAIL]        substitution          0   Capture Avoidance (naive/buggy subst).
  [INCOMPLETE]  substitution          1   Capture Avoidance (correct subst bu...
  [FAIL]        substitution          2   Capture Avoidance (mixed: buggy + i...
  [FAIL]        substitution          3   Capture Avoidance (throws incomplet...
```

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
reference to `Alcotest.incomplete`, no QCheck. All the `[INCOMPLETE]`
tagging comes from patched alcotest's `protect_test` matching the
`"TODO:"` prefix on `Failure` messages raised inside the library.

## Rebasing onto a newer upstream alcotest release

```sh
git -C ../alcotest fetch origin
git -C ../alcotest checkout <newer-tag>                # e.g. 1.10.0
git -C ../alcotest switch qcheck-inc-incomplete        # our branch
git -C ../alcotest rebase <newer-tag>                  # resolve any conflicts
# Regenerate the patch file so it matches the new base:
git -C ../alcotest format-patch <newer-tag>..qcheck-inc-incomplete --stdout \
  > patches/alcotest-incomplete.patch
opam reinstall alcotest --yes                          # pick up the new sources
dune clean && dune build
```

The patch is small (≈ 26 added lines across 7 files, no refactors), so
conflicts on a routine upstream bump should be rare and mechanical.

## Reverting to stock alcotest

```sh
opam pin remove alcotest --yes
```

This restores the registry version. The clone at `../alcotest/` is untouched;
re-pin with `opam pin add alcotest ../alcotest --kind=path --yes` (and make
sure the branch is `qcheck-inc-incomplete`) to get the `[INCOMPLETE]` tag
back. After reverting to stock, `dune exec test/core/lambda_subst_alco.exe`
will fail to compile or link because `Alcotest.incomplete` no longer exists.

In practice, `src/alcotest/QCheck_alcotest.ml` calls `Alcotest.incomplete`
only when `count_incomplete > 0`. To keep the bridge buildable against both
patched and stock alcotest, you would need to guard that line (e.g. with a
cppo flag) — we don't do this today because we always pin.

Separately, the `failwith "TODO:..."` convention silently degrades to `[FAIL]`
on stock alcotest: stock's `protect_test` has no `Failure s when … "TODO:"` arm.
No link error, just different output.

## The bridge: `src/alcotest/QCheck_alcotest.ml`

The QCheck → alcotest adapter raises `Alcotest.incomplete` after
`T.check_result` returns successfully, only when `count_incomplete > 0`.
Priority order:

- Real QCheck failure → `check_result` raises → alcotest tags `[FAIL]`.
- No failure, `count_incomplete > 0` → `Alcotest.incomplete` raises →
  alcotest tags `[INCOMPLETE]`.
- No failure, no incompletes → closure returns `()` → alcotest tags `[OK]`.

The `Alcotest.incomplete` call is only reached when the QCheck2 framework
actually incremented `count_incomplete`, which happens exclusively in the
`| Failure msg when todo_reason msg <> None` arm of the runner. Thus the
entire `[INCOMPLETE]` feature is gated on a test actually using
`failwith "TODO:..."`; it's opt-in from both sides.

## See also

- `INC.md` — the `failwith "TODO:..."` convention and QCheck2 internals
  that feed `count_incomplete` and `todo_reasons`.
- `../alcotest/CHANGES.md` (upstream) — alcotest release notes; useful
  when deciding whether to rebase onto a new tag.
