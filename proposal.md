# Incremental Property-Based Testing

**Author:** Pablo Ignacio Benario Figueroa  
**Advisor:** Éric Tanter  

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Background and State of the Art](#2-background-and-state-of-the-art)
3. [Objectives](#3-objectives)
4. [Evaluation](#4-evaluation)
5. [Proposed Solution](#5-proposed-solution)
6. [Preliminary Work: Analysis of the QuickCheck Checker](#6-preliminary-work-analysis-of-the-quickcheck-checker)

---

## Key Concepts

- **PBT (Property-Based Testing):** A testing technique where the programmer specifies properties the system must satisfy, and the framework automatically generates random inputs to verify them. Sits between unit testing (fast, low guarantees) and formal verification (slow, high guarantees).

- **Property:** A logical statement about program behavior, typically of the form `∀x. P(x)` or `∀x. Q(x) ⟹ P(x)`. Written by the developer; checked by the framework against many generated inputs.

- **Generator:** A component of a PBT framework that produces random test inputs. Can be constrained to produce only valid inputs (restricted generator) or combined with a guard that discards invalid ones (generate-and-filter).

- **Shrinking:** When a counterexample is found, the framework automatically tries to minimize it to the smallest input that still triggers the failure, making debugging easier.

- **Guard / Precondition:** A condition (`==>` in QuickCheck/QCheck, `assume()` in Hypothesis) that discards a generated input if it does not satisfy the required precondition. Overuse leads to wasted test budget.

- **QCheck:** The OCaml Property-Based Testing framework being extended in this work. Similar in spirit to Haskell's QuickCheck.

- **QuickCheck:** The original and most influential PBT framework, written in Haskell. Many concepts in this document (shrinking, generators, guards) originate here.

- **Hypothesis:** A mature PBT framework for Python. Uses `@given` decorators and `assume()` for preconditions.

- **Trivalued semantics (Pass / Fail / Unimplemented):** The core proposal of this work. Extends the classical binary Pass/Fail result with a third outcome — `Unimplemented` — to represent cases where execution reaches code that is not yet written, rather than code that is wrong.

- **Unimplemented / Incomplete:** A test outcome (colored **yellow** informally in this document) meaning the property could not be evaluated because it hit a code path not yet implemented (e.g., `raise NotYetImplemented`). Distinct from `Fail` (a real bug was found) and from `Discard` (input did not satisfy a precondition).

- **NotYetImplemented:** The canonical exception proposed for users to raise inside incomplete code branches. The modified QCheck runner catches it and records the result as `Unimplemented` instead of aborting.

- **Discard:** A generated input that is thrown away because a precondition (guard) was not satisfied. Not a test result — a generation artifact. Distinct from `Unimplemented`.

- **Incremental development:** A development style where a program is built piece by piece, with some branches fully implemented and others left as stubs or placeholders at any given point in time.

- **ICP (Incremental Certified Programming):** A theoretical framework (Díaz et al., 2025) that formally distinguishes between error and incompleteness in program verification, and proposes *Completion Refinement* as the relationship between an incomplete and a complete specification. Provides the theoretical grounding for this work.

- **Completion Refinement:** An ICP concept: an incomplete specification refines a complete one if, whenever the incomplete version gives a definite answer (Pass or Fail), it agrees with the complete version.

- **Effective Coverage:** Metric proposed in this work — the fraction of generated inputs that reached fully implemented code: `(Pass + Fail) / Total Runs`. Inputs hitting `Unimplemented` do not count toward coverage.

- **Monotonicity of progress:** A soundness property of the proposed extension: as the user fills in incomplete branches, `Unimplemented` results can only turn into `Pass` or `Fail`, never the reverse.

- **Rose tree:** The data structure used internally by QuickCheck/QCheck to represent the space of possible shrinks for a given input. Each node is a candidate shrunk value; children are further reductions.

- **Color metaphor (green / yellow / red):** Informal shorthand used throughout this document. Green = `Pass`, yellow = `Unimplemented`, red = `Fail`.

---

## 1. Introduction

Software development faces the challenge of delivering correct
programs in agile environments where requirements are constantly
changing. To achieve this, there are various validation and
verification techniques that allow detecting design and programming
errors early.

Among these techniques, Property-Based Testing (hereafter, PBT) has
proven to be a highly useful tool. Instead of writing individual test
cases, the programmer specifies properties that the system must
satisfy. The framework then automatically generates numerous test
cases and verifies compliance with those properties.

Each testing technique has advantages and disadvantages, creating a
tension between the level of correctness guarantee sought and the
available development time. Unit Testing sits at the simplest and
fastest-to-use end in agile projects, while formal verification sits
at the other extreme, offering maximum correctness guarantees but
requiring more development time. PBT sits at an intermediate point in
this spectrum, making it an interesting technique when there are tight
deadlines and stricter correctness guarantees are required.

However, current PBT presupposes that the system under test is
completely implemented. This assumption is unrealistic, since real
development is incremental and, at each iteration, complete parts
coexist with incomplete or changing parts. In practice, when running
properties on incomplete code, frameworks tend to abort early (e.g.,
due to exceptions like `NotImplemented`) or mark the execution as
failure, which prevents obtaining useful feedback about
already-implemented parts and blocks the effective use of PBT during
development.

This work addresses precisely that problem: **how to extend PBT so
that it is also useful on incomplete programs?** We propose endowing
the QCheck framework with a trivalued semantics for test results —
`Pass` / `Fail` / `Unimplemented` — making it explicitly recognize the
`Unimplemented` state. With this, tests can distinguish between real
failures and absence of implementation, allowing incremental use of
PBT, providing early feedback on already-implemented parts, and
clearly reporting which properties are affected by incomplete code.

**Expected contributions:**
1. A theoretical basis for achieving a PBT extension for incomplete
   programs.
2. A practical extension of QCheck that implements the trivalued
   result and associated metrics.
3. An empirical evaluation testing the implementation on a
   medium-to-large-sized project.

---

## 2. Background and State of the Art

### 2.1 Fundamentals of Property-Based Testing

PBT has established itself as an intermediate technique between unit
tests and formal verification. Instead of enumerating cases, the
developer specifies properties and the framework generates random
cases to verify them. There are mature implementations in multiple
ecosystems (e.g., QuickCheck/Haskell, Hypothesis/Python,
QCheck/OCaml), with a significant body of practical reports and
industrial experience. In these environments, PBT has shown particular
strength in discovering edge cases and violated invariants, in
orchestrating differential or round-trip tests, and in complementing
Unit Testing suites [pbtTestingInPractice24].

In PBT, properties occur primarily as: universal quantification,
implication, and/or equality:

```
∀x. P(x)
∀x. (Q(x) ⟹ P(x))
∀x. Q(x) = P(x)
```

The first expresses unconditional validity; the second introduces a
precondition Q. At the framework level, this materializes as:

1. Quantify with a generator ("∀" operationally).
2. Condition with a guard ("⟹" operationally) that discards cases that
   do not satisfy Q.
3. Check an equality through language primitives, e.g., `==`.

Multiple operators can also be combined in a property, for example:

```
∀x. (I(x) ⟹ O(x)) ∧ (S(x) ⟹ T(x)) ∧ (R(x) ⟺ R'(x))
```

### 2.2 Ecosystem and Materialization in Frameworks

There is a wide variety of mature implementations across multiple
ecosystems. Below, the primitives of the most relevant frameworks are
contrasted.

| Logic      | QuickCheck (Haskell)    | Hypothesis (Python)              | QCheck (OCaml)           |
|------------|-------------------------|----------------------------------|--------------------------|
| `∀x. P(x)` | `forAll gen (\x -> ..)` | `@given(strat) def test(..): ..` | `T.make gen fun x -> ..` |
| `Q -> P`   | `Q ==> P`               | `assume(Q(..)); assert P(..)`    | `(Q ==> P)`              |
| `P ∧ Q`    | `(P && Q)`              | `assert(P and Q)`                | `P && Q`                 |
| `P ∨ Q`    | `(P \|\| Q)`            | `assert(P or Q)`                 | `P \|\| Q`               |
| `¬P`       | `not P`                 | `assert(not P)`                  | `not P`                  |
| `P <-> Q`  | `P == Q`                | `assert(P == Q)`                 | `P = Q`                  |

#### 2.2.1 Minimal Examples per Framework

The following illustrates how the same property ("inserting an element
into a sorted list preserves the order") is implemented in three
different languages. In each case, two approaches are contrasted: the
use of dynamic preconditions (which discard cases) versus the use of
custom generators (which build valid cases).

**QuickCheck (Haskell): `∀x. Q(x) ⟹ P(x)` vs. restricted generator**

In the first style, the `==>` operator acts as a filter: if the
generated list `xs` is not sorted, the test is discarded. In the
second style, the `forAll` combinator is used together with a specific
generator `orderedList`, guaranteeing that the property always
receives valid data without wasting executions.

```haskell
import Test.QuickCheck

ordered :: [Int] -> Bool
ordered xs = and (zipWith (<=) xs (drop 1 xs))

insert :: Int -> [Int] -> [Int]
-- implementation under test

-- Style with precondition (discards):
prop_Insert :: Int -> [Int] -> Property
prop_Insert x xs = ordered xs ==> ordered (insert x xs)

-- Style with "correct by construction" generator (no discards):
prop_Insert2 :: Int -> Property
prop_Insert2 x = forAll orderedList $ \xs ->
  ordered (insert x xs)
```

**QCheck (OCaml): same idea, two styles**

Similarly, in OCaml, `Test.make` is used to define the test. The first
version generates arbitrary integer lists and uses the implication
`==>` to filter. The second defines a `gen_ordered` generator by
applying a sorting transformation (`List.sort`) directly on the base
generator, ensuring validity by construction.

```ocaml
open QCheck

let ordered xs =
  let rec ok = function
    | a::b::t -> a <= b && ok (b::t)
    | _ -> true in ok xs

let insert (_x:int) (xs:int list) : int list = (* SUT *) xs

(* With precondition (discards cases): *)
let prop_insert =
  Test.make
    ~name:"insert preserves order (implication)"
    ~count:100
    (pair small_int (list small_int))
    (fun (x,xs) -> (ordered xs) ==> (ordered (insert x xs)))

(* With restricted generator (no discards): *)
let gen_ordered = map List.sort (list small_int)

let prop_insert2 =
  Test.make
    ~name:"insert preserves order (forAll)"
    (pair small_int gen_ordered)
    (fun (x,xs) -> ordered (insert x xs))
```

**Hypothesis (Python): `assume` vs. restricted generator**

Hypothesis manages preconditions through the `assume` function: if the
condition fails, it throws an internal exception that marks the case
as discarded. To avoid this, the second example chains the
`.map(sorted)` method to the list generation strategy, always
delivering sorted lists to the test.

```python
from hypothesis import given, assume, strategies as st

def is_ordered(xs):
    return all(a <= b for a,b in zip(xs, xs[1:]))

def insert(x, xs):  # SUT
    return xs

# With precondition (discards):
@given(st.integers(), st.lists(st.integers()))
def test_insert(x, xs):
    assume(is_ordered(xs))
    assert is_ordered(insert(x, xs))

# With restricted generator (no discards):
@given(st.integers(), st.lists(st.integers()).map(sorted))
def test_insert2(x, xs):
    assert is_ordered(insert(x, xs))
```

### 2.3 Generation Mechanisms and Preconditions

The effectiveness of PBT depends on the quality of generators and the
handling of preconditions. In particular for properties using
preconditions, there are two styles:

1. **Generate and filter** (implication `Q ⟹ P`): simple to write; can
   exhaust the discard budget if Q is rare (unlikely to be constructed
   in the generation process).

2. **Restricted generator** (∀ over a structure of interest): more
   initial work, avoids discards and provides stable
   coverage. Equivalent to replacing `∀x. Q(x) ⟹ P(x)` by `∀x ∈
   D_Q. P(x)`. It's advisable to migrate to this generation pattern
   when too many discards are occurring in the precondition.

Also, to measure the effectiveness of the testing performed,
frameworks expose parameters that control how many cases are
generated, how many discards are tolerated, and what diagnostics are
reported during execution. These signals allow distinguishing between
generation problems (few valid cases), coverage problems (repetitive
cases), and configuration problems (limits too low).

- **Budget:** `maxSuccess`/`quickCheckWith` (QuickCheck), `~count`
  (QCheck), `max_examples` (Hypothesis).
- **Discards:** `maxDiscardRatio` (QuickCheck), Hypothesis health
  checks, QCheck statistics.

### 2.4 Frequent Specification Patterns

In real projects, the use of PBT rarely consists of isolated "ad hoc"
properties: most suites end up organized around a few recurring
specification schemes. These schemes capture typical forms of
relationship between implementation and specification (equivalences,
oracles, invariants, etc.) and are systematically reused across
different functions or modules. The most frequent patterns that appear
in practice are [pbtInMLProjects24, pbtTestingInPractice24]:

1. **Equivalence/differential:** `∀x. f(x) = g(x)`

2. **Oracle (specification):**
   ```
   ∀x. Spec(x) = f(x)
   or
   ∀x. Q(x) ⟹ Spec(x) = f(x)
   ```
   Useful when there is an executable specification or a reference model (possibly partial via Q).

3. **Round-trip (decode/encode):**
   ```
   ∀x ∈ D. decode(encode(x)) = x
   ```
   When equality is "up to normalization", use a normalizer N:
   ```
   ∀x ∈ D. N(decode(encode(x))) = N(x)
   ```

4. **Metamorphic:** `∀x. f(map g x) = map g (f(x))`

5. **Invariants:** `∀x. Inv(x) ⟹ Inv(T(x))`

### 2.5 Limitations Against Incomplete Programs

Despite the maturity of the techniques described above, in practice
the PBT cycle usually assumes that the code under test is complete.

The reality of software development is that it is incremental: teams
interleave complete functions with sections not yet implemented
(stubs, `NotImplemented`, exceptions, TODOs, empty branches,
partiality monads, etc.). Under this reality:

- Running PBT against a module with incompleteness produces early
  aborts (such as exceptions) or only failures, even when there are
  already-implemented portions that could be verified.
- The binary `Pass/Fail` semantics prevents distinguishing between
  "real failure" and "absence of implementation"; both are reported as
  error or abort the campaign.
- Since typical frameworks stop exploration at the first finding, if
  that finding is a "yellow" path (incomplete), no further green
  (correct) or red (error) evidence is sought in other
  already-implemented paths.

These limitations clash with agile development practices, where the
value lies in receiving early and sustained signal during system
construction. With traditional PBT, the signal is, at best, noisy or
non-existent until "everything is ready."

### 2.6 Example Case

To illustrate how the limitations described above block the workflow
in a realistic scenario, we will analyze an incremental implementation
of a simple lambda calculus. We start by defining the language terms
and a standard property about the substitution function.

The term syntax is defined in OCaml as follows:

```ocaml
type term =
  | Var of int
  | Abs of int * term
  | App of term * term
  | Con of int
```

A correct substitution function must avoid free variable
capture. Intuitively, if we substitute variable x with term b in term
a, the free variables of the result must correspond to the original
free variables of a (minus x) united with those of b.

This invariant is formalized in QCheck as:

```ocaml
let prop_subst_free_no_var_capture_open
  (subst_fn : int -> term -> term -> term) =
  QCheck2.Test.make
    ~name:"Property: Free Variables (Capture Avoidance)"
    ~print:print_triple
    ~count:1000
    gen_subst_triple_open
    (fun (a, x, b) ->
       let free_a = free_vars a in
       if List.mem x free_a then
         let res = subst_fn x b a in
         let lhs = free_vars res in
         let rhs = set_union (set_remove x free_a) (free_vars b) in
         if set_equal lhs rhs then true
         else (
           Printf.printf "FAILURE!"
             (print_term a) x (print_term b) (print_term res);
           false
         )
       else true)
```

#### 2.6.1 Incremental Development of Substitution

In an incremental development flow, it is common to postpone the
implementation of complex cases. A programmer could correctly
implement the base cases (`Var`, `Con`) and simple recursive cases
(`App`), but explicitly leave incomplete the delicate abstraction case
(`Abs`) for a future iteration.

It can also happen that the initial attempted implementation is
outright incorrect because it contains a logical bug, for example:

```ocaml
(* Partial implementation of [x:=s]t *)
let rec subst_naive x s t =
  match t with
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (t1, t2) -> App (subst x s t1, subst x s t2)
  | Abs (y, body) -> Abs (y, subst_naive x s body) (* BUG: captures y *)
```

If this were the case, the virtue of PBT is that it quickly finds the
error and immediately reports that the property is not being
satisfied; in particular, the output would look like:

```
--- Failure --------------------------------------------------------------------
Test Property: Free Variables (Capture Avoidance) failed (19 shrink steps):

a: (λv5.v9)
x: v9
b: v5
================================================================================
failure (1 tests failed, 0 tests errored, ran 1 tests)
- : int = 1
```

However the other possibility is what was mentioned at the start of
the example: that the programmer leaves for later in the development
the case they are not sure about. For example:

```ocaml
(* Partial implementation of [x:=s]t *)
let rec subst x s t =
  match t with
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (t1, t2) -> App (subst x s t1, subst x s t2)
  | Abs (y, _) ->
      (* Complex case explicitly postponed *)
      if x = y then t
      else
        raise IncompleteCode
```

Here the programmer is on a better path: correctly handles `Var`,
`Con` and `App` cases, and in the really delicate case (`Abs`) throws
an `IncompleteCode` exception as a marker of code not yet
implemented. This is an extremely common development pattern: the
difficult case is left for later, but one wants to be able to test and
reason about the already-implemented parts.

#### 2.6.2 Collapse of Traditional PBT Against Incompleteness

It is precisely when running the previously defined property on this
partial implementation that tools like QCheck report a catastrophic
error practically identical to the error that occurs with a logical
bug, and which does not even provide the programmer with information
about whether the rest of the implementation they wrote was on the
right track — which is precisely what this proposal aims to improve.

```
--- Failure --------------------------------------------------------------------

Test Property: Free Variables (Capture Avoidance) errored on (4 shrink steps):

a: (λv0.v9)
x: v9
b: 0

exception Incomplete_pbt_example.Ws_gen_incom3.IncompleteCode

================================================================================
failure (0 tests failed, 1 tests errored, ran 1 tests)
- : int = 1
```

From QCheck's perspective, any uncaught exception is a test error. The
framework does not distinguish whether the exception is due to:

- a real bug in the implementation of `subst`, or
- a case explicitly marked as "not yet implemented."

This result evidences the critical incompatibility:

1. **Early abort:** Execution stops at the first case that touches the
   `Abs` branch, preventing validation of whether `App`, `Var`, or
   `Con` cases are correct.
2. **Semantic ambiguity:** The framework reports error/failure,
   without distinguishing between a logical bug and a pending feature.
3. **Lack of metrics:** No information is obtained about how many
   cases passed successfully through already-implemented branches.

From the perspective of incrementality, this is precisely what we do
not want: the presence of incomplete code in *one* branch of the
function makes the PBT framework unable to give us useful information
about the other branches. In other words, the classic PBT model has a
binary semantics for each test: it passes (the property is satisfied)
or fails (a counterexample is found), and any exception is mapped to
"failure/errored" and stops execution.

### 2.7 Why This Is Incompatible With Incremental Development

If we think about the incremental workflow, what one would want is to
be able to:

1. Partially implement a function (for example, leaving only the `Abs`
   case incomplete).
2. Run properties on that partial version.
3. Obtain quantitative information about:
   - How many cases exercise only complete code.
   - How many cases go through some hole (`IncompleteCode`).
   - How many cases give rise to genuine counterexamples.
4. Refine the implementation or property based on that data, without
   having to first complete the entire definition.

The standard PBT model prevents this because:

- It **does not distinguish** between "inconclusive due to incomplete
  code" and "real counterexample."
- It **does not continue exploring** after finding the first
  exception.
- Therefore, it **is not informative** about the partial state of the
  code.

Consequently, direct use of classic PBT on incomplete code is
practically "all or nothing": either the function is complete and
tests give us reasonable information, or there are holes and the
framework gets stuck as soon as it hits one, without helping us
understand which parts of the code already work correctly.

### 2.8 Towards Incremental PBT

THE proposed solution (which motivates the design of a framework like
*incremental QCheck*) is to change the semantics of a test result to
introduce an explicit third state:

```
Pass  /  Fail  /  Incomplete
```

Instead of aborting on the first exception, the framework should:

- Continue generating inputs as long as possible.
- Classify each execution of the property as:
  - **Pass:** The property holds and no exception is thrown.
  - **Fail:** A genuine counterexample is found (without going through
    holes).
  - **Incomplete:** The execution touches code marked as incomplete
    (e.g., `raise IncompleteCode`).
- At the end, report a statistical summary.

Ideally, the report of an incremental PBT framework could look
something like this:

```
Property: Free Variables (Capture Avoidance)
  700 tests passed
  280 tests inconclusive (IncompleteCode)
  0 tests failed (no logical counterexamples found)

Summary:
  - Implemented branches exercised in 700 distinct cases.
  - 280 cases reach incomplete code in Abs.
```

This type of output is compatible with incrementality because:

- It allows us to quantify how much real information we have about
  already-implemented parts.
- It explicitly indicates where the holes are that prevent exploring
  more cases (e.g., the `Abs` branch).
- If in subsequent versions of the code we eliminate the holes, the
  report will change coherently (Incomplete count decreases, Fail may
  appear, etc.), reflecting incremental progress.

In summary, the substitution example captures the central point: under
the semantics of traditional PBT frameworks, the presence of
incomplete code makes PBT practically incompatible with an incremental
development flow. To reconcile both worlds, it is necessary to enrich
the result model of properties and design frameworks that treat
incompleteness as a separate output state, not as a catastrophic
failure that stops the testing process.

### 2.9 Related Resources and Solutions

#### Unit Testing Similar Practices

In Unit Testing there are patterns such as `pending` / `skip` /
`xfail` to mark tests as expected to fail or pending. While they help
manage expectations, they do not give meaning to the internal
incompleteness of the code under test.

#### Filtering/Guard Mechanisms in PBT

Tools like QuickCheck or Hypothesis allow discarding cases with
preconditions (`==>` / `assume`). This serves to guide the generator
and focus it on a valid space, but does not model operational
incompleteness (e.g., a branch that throws `NotImplemented`). If an
execution reaches incomplete code, the property fails or aborts; the
framework does not interpret it as a third state nor continue the
campaign.

#### Evaluation and Usability of PBT

Recent literature documents real problems in PBT such as generator
design, evaluation of the effectiveness of tested properties, and lack
of actionable feedback. Platforms have emerged to compare strategies
and tools that visualize the distribution of inputs and labels. Even
so, these proposals presuppose total code; their focus is on sampling
effectiveness and visibility over the property, not on supporting
incremental programming.

#### Incremental Certified Programming (ICP)

Recent work in *Incremental Certified Programming* (ICP) formalizes
the distinction between error and incompleteness, and proposes notions
such as *Completion Refinement* with respect to completeness. The key
idea is to reformulate specifications so that they are valid
throughout development: when a program is partially defined, the
judgment distinguishes the unimplemented case from the implemented but
incorrect one. This framework offers foundations and a prototype in
Rocq, which allows obtaining incremental specifications that imply the
originals once the code is completed [icp25].

### 2.10 Identified Gap and Novelty

In summary, today there is no PBT framework that: (i) explicitly
recognizes incompleteness as a state distinct from error
(`Pass/Fail/Unimplemented`); (ii) continues exploration after finding
an incomplete branch; (iii) reports metrics centered on incremental
development; and (iv) offers these capabilities without requiring the
user to adopt all of the ICP machinery. Below we detail the points
that would be novel if incrementality is adopted in PBT.

#### Compatibility With Real Agile Flow

A trivalued semantics enables agile development with PBT: at the
beginning "yellows" predominate; as the implementation advances,
"greens" grow; "reds" locate real bugs in already-implemented parts.

#### Monotonicity and Conceptual Soundness

Incorporating monotonicity with respect to completeness guarantees
that, upon completing a portion of code, a yellow result can only
become green or red, never hiding failures.

#### Reuse of Existing Ecosystems

Extending existing PBT libraries facilitates adoption and reduces
friction. ICP suggests instrumentation points (e.g., `try/catch`
around critical observations, equality adjustment by refinement
according to polarity) for a principled extension.

#### Metrics and Incremental Visibility

With ternary logic, new indicators are introduced (e.g., percentage of
yellow executions per property, inputs blocked by incompleteness,
effective coverage conditioned on `Unimplemented`), valuable for
prioritizing work and managing technical debt.

#### Pragmatic Specialization of ICP for PBT

Typical PBT properties are decidable and of bounded form, which allows
distilling the general ICP theory to a practical core usable without
the complexity of formal certification [icp25].

---

## 3. Objectives

### 3.1 General Objective

Design and implement an incremental extension of the QCheck
Property-Based Testing (PBT) framework that works with incomplete
programs through a trivalued semantics
(`Pass`/`Fail`/`Unimplemented`), maintains compatibility with existing
code, and provides useful metrics for agile development.

### 3.2 Specific Objectives

- **Foundations and model.** Formulate a trivalued semantics and a
  completeness criterion inspired by ICP, so that they serve as a
  theoretical foundation for extending PBT to incomplete programs.
- **Design and implementation.** Extend QCheck to incorporate
  `Unimplemented` without aborting campaigns, adjust shrinking to not
  treat `Unimplemented` as failure, and expose CLI reporting.
- **Ergonomics and adoption.** Minimize changes for users; offer a
  standard indicator (exception `NotYetImplemented`).
- **Scope and limits.** Evaluate to what extent the proposal can be
  transferred to other frameworks and characterize its limitations.

---

## 4. Evaluation

To evaluate the project, we will ask the following question:

- How does the extension behave in real projects?

To answer this question, we will evaluate the extension in large-scale
projects that already use PBT and have a stable, green suite. Starting
from that baseline, we will apply two controlled treatments on the
software under test: (i) introduction of incompleteness, and (ii)
introduction of incompleteness plus semantic failures (bugs).

The expectation is that the tool behaves consistently in all
scenarios, observing the following verdict pattern per property:

1. **Baseline (complete code):** predominance of green (`Pass`).
2. **With incompleteness:** mix of yellow (`Unimplemented`) and green
   (`Pass`).
3. **With incompleteness + bugs:** coexistence of red (`Fail`), yellow
   (`Unimplemented`), and green (`Pass`).

This design allows verifying that the extension does not abort in the
face of incompleteness, continues collecting evidence where possible,
and correctly distinguishes between real failures and cases blocked by
unimplemented code.

---

## 5. Proposed Solution

### 5.1 General Vision

The central proposal of this work consists of modifying the execution
model of the QCheck framework to transition from a binary validation
logic (*Pass/Fail*) to a trivalued semantics that integrates
incompleteness as a first-class state.

The objective is to allow test execution to not catastrophically abort
in the presence of unimplemented code, but rather capture this state,
record it as evidence of "pending progress," and continue exploring
the input space in search of errors in the parts that are implemented.

### 5.2 Trivalued Semantic Model

Currently, PBT frameworks classify results into three categories, but
two of them collapse conceptually:

1. **Success (Pass):** The property holds.
2. **Failure (Fail):** The property does not hold (a counterexample
   was found).
3. **Discard:** The generated case is not valid (false
   precondition). This is not a test result, but a generation failure.

Our proposal introduces a distinction orthogonal to failure and
discard:

- **Pass:** Execution ends successfully.
- **Fail:** Execution ends due to an uncontrolled exception or failed
  assertion (evidence of error).
- **Unimplemented (New):** Execution ends prematurely due to an
  explicit signal of missing implementation. Unlike *Discard*, this is
  a valid domain case that the system does not yet know how to
  process; unlike *Fail*, it does not imply a specification violation,
  but an absence of code.

### 5.3 Solution Architecture

To integrate this semantics into QCheck without rewriting the entire
ecosystem, we propose a surgical intervention in the runner's
execution cycle, based on the exception handling mechanism of the host
language (OCaml).

#### 5.3.1 Signaling Mechanism: Exceptions

We choose to use exceptions to signal incompleteness for reasons of
ergonomics and compatibility:

- **Non-intrusive:** Does not require changing the signature of
  functions under test (e.g., changing the return type from `int` to
  `int option` or `Result`). Nor is the user forced to import a new
  module for incrementality features to work.

- **Automatic propagation:** The exception propagates from the depth
  of the call (where `raise` occurs) to the runner, traversing any
  intermediate layer without the need for manual instrumentation.

- **Standard:** A canonical exception will be defined (e.g.,
  `QCheck.NotYetImplemented`) that the user can throw directly or
  alias from native exceptions.

#### 5.3.2 Runner Modification

The main intervention occurs in the function responsible for executing
a test instance. The proposed flow is as follows:

1. The generator produces a datum x.
2. The runner attempts to execute property P(x) within a protected
   block.
3. Exceptions are discriminately captured:
   - If `NotYetImplemented` occurs, the verdict is **Yellow**
     (Incomplete). The campaign continues.
   - If another exception or assertion failure occurs, the verdict is
     **Red** (Failure). The shrinking process begins.
   - If no exceptions occur, the verdict is **Green** (Success).

**Pseudocode of the Modified Runner:**

```python
def run_property_safe(prop, input):
    try:
        if prop(input):
            return Result.Success      # Green
        else:
            return Result.Failure      # Red (bool false)
    except NotYetImplemented:
        return Result.Unimplemented    # Yellow (NEW)
    except Exception as e:
        return Result.Failure(e)       # Red (Crash)
```

### 5.4 Shrinking Strategy

A critical design point not reflected in the pseudocode above is the
interaction with the counterexample minimization mechanism
(*shrinking*). In particular, the proposed contraction policy is
conservative:

- **Do not shrink Unimplemented:** If a case falls into incomplete
  code, no minimization is attempted. The reason is that a smaller
  case could accidentally avoid the incomplete branch and pass (false
  positive) or fall into another incomplete branch, without providing
  information about a real error. The `Unimplemented` state is
  considered an informative "dead end," not an error to debug.

- **Shrink only Fail:** Shrinking is reserved exclusively for genuine
  failures. This ensures that the developer only receives minimal
  cases when there is something to fix in the existing logic.

### 5.5 Reporting and Incremental Metrics

Since execution does not stop upon finding incomplete code, the
framework can collect aggregated statistics that are invisible in
traditional PBT. The final report will include:

1. **Implementation Coverage:** Percentage of generated cases that managed to execute completely versus those blocked by incompleteness.
   ```
   Effective Coverage = (Pass + Fail) / Total Runs
   ```

2. **Blockage Identification:** If a property reports 100%
   `Unimplemented`, it indicates that the generator is exclusively
   producing data that touches pending functionalities, guiding the
   developer to implement that branch or adjust the generator.

### 5.6 Properties of the Resulting System

- **Monotonicity of progress:** As the user replaces `raise
  NotYetImplemented` with real logic, `Unimplemented` results
  monotonically transform into `Pass` or `Fail`, never the reverse.

- **Backward compatibility:** If the user does not use the
  incompleteness exception, the framework behaves identically to the
  standard version of QCheck.

---

## 6. Preliminary Work: Analysis of the QuickCheck Checker

As part of the technical feasibility analysis for the proposed
solution, an in-depth study of the execution core of current
frameworks has been conducted (taking as reference the canonical
implementation in `Test.hs` of QuickCheck Haskell). The objective of
this prior analysis is to identify the exact intervention points
required to introduce trivalued semantics without breaking the
shrinking logic, seed handling, or generators.

### 6.1 Operational Vision

The *checker* iterates by generating inputs, executing the property,
and dispatching according to the verdict: success, discard, or
failure. It controls the test budget, discard ratio, case size, and
counterexample *shrinking*. The implementation in `Test.hs` organizes
this into: `test` (main loop), `runATest` (one test), `computeSize`
(size schedule), and `foundFailure`/`localMin` (contraction).

### 6.2 Pseudocode of the Main Loop

```
# Initial state (seed, limits, counters, coverage)
state := {
  seed, maxSuccess, maxDiscardRatio, maxSize, maxShrinks,
  nSucc := 0, nDiscard := 0, nDiscWindow := 0,
  labels := {}, classes := {}, tables := {},
  expected := True
}

function CHECK(prop, args):
  st := initState(args)
  loop:
    if finishedSuccessfully(st): return OK(st)
    if finishedInsufficientCoverage(st): return COVERAGE_FAIL(st)
    if tooManyDiscards(st): return GAVE_UP(st)
    st := RUN_ONE_TEST(prop, st)

function RUN_ONE_TEST(prop, st):
  size := computeSize(st)                # size schedule
  (seed1, seed2) := split(st.seed)       # pure PRNG, seed is split
  # Evaluate property with generator and size -> result + shrink tree
  (res, shrinkTree) := runProperty(prop, seed1, size)  # rose tree

  st' := updateCoverage(st, res)         # labels/classes/tables/coverage
  st'.seed := seed2                      # advance PRNG

  match res.ok:                          # trivalued checker verdict
    case Just True:                      # success
      st'.nSucc += 1
      st'.nDiscWindow := 0
      return st'
    case Nothing:                        # discard (e.g., guards ==> / assume)
      st'.nDiscard += 1
      st'.nDiscWindow += 1
      return st'
    case Just False:                     # failure: activate shrinking
      (nShrinks, nTryTot, nTryLast, resMin) := SHRINK(st', res, shrinkTree)
      if not resMin.expected:            # expected failure -> "NoExpectedFailure"
        return RECORD_OK_AS_EXPECTED_FAILURE(st', resMin)
      else:
        return REPORT_FAILURE(st', size, nShrinks, nTryTot, nTryLast, resMin)

function SHRINK(st, res, tree):
  nSuccShr := 0; nTry := 0; nTryTot := 0
  best := res
  queue := children(tree)
  while queue not empty and (nSuccShr + nTryTot) < st.maxShrinks:
    t := pop(queue)
    res' := evalNode(t)
    if res'.ok == Just False:             # improvement (smaller counterexample)
      best := res'
      queue := children(t)               # go deeper
      nSuccShr += 1; nTry := 0
    else:                                # no improvement
      nTry += 1; nTryTot += 1
  return (nSuccShr, nTryTot - nTry, nTry, best)
```

### 6.3 Control Logic

- **Success cutoff:** `finishedSuccessfully` when `nSucc >=
  maxSuccess`. If coverage is required, it also demands statistical
  sufficiency (Wilson) and periodic checks.

- **Insufficient coverage cutoff:** `finishedInsufficientCoverage` if
  declared thresholds are not met at a checkpoint.

- **Discard cutoff:** `tooManyDiscards` if `nDiscard / max(1, nSucc)`
  exceeds `maxDiscardRatio`; returns `GaveUp`.

- **Size schedule:** `computeSize` doses `[0 .. maxSize)` according to
  progress and recent discards to avoid stagnation.

- **Seeds:** Each iteration uses `split(seed)` for purity and
  reproducibility; `replay` fixes `seed` and `size` from a previous
  run.

### 6.4 Verdicts and Artifacts

- **Success:** `Success {numTests = nSucc, numDiscard = nDiscard,
  labels, classes, tables}`.

- **Giving up:** `GaveUp` when the discard ratio exceeds the limit.

- **Failure:** `Failure {numTests, numDiscard, numShrinks, reason,
  failingTestCase, ...}`. Shrinking explores the rose tree up to
  `maxShrinks`.

- **Expected failure not observed:** `NoExpectedFailure` if
  `expected=False`, but no failure was obtained.

### 6.5 From `Test.hs` to Pseudocode

- `test` → `CHECK`: loop and termination conditions.

- `runATest` → `RUN_ONE_TEST`: generate size, execute property, update
  state and dispatch according to result.

- `computeSize` → size schedule dependent on `nSucc` and
  `nDiscWindow`.

- `foundFailure`/`localMin`/`localMin'` → `SHRINK`: local minimum
  search in the shrink rose tree, with counters `numSuccessShrinks`,
  `numTryShrinks`, `numTotMaxShrinks`.

- `protectRose`/`reduceRose` → safe evaluation of tree nodes and
  exception handling.

- `labels`/`classes`/`tables` → coverage and statistics accumulators
  (`label`/`classify`/`tabulate`).

### 6.6 Conclusions

The analysis confirms that the checker operates as a closed loop:
generate → execute → classify. The intervention proposed in the
previous section will need to mainly modify the classification stage
in `RUN_ONE_TEST` to capture the new incompleteness exception before
the shrinking decision is made, thus preventing it from being treated
as a conventional failure.

---

## References

**[pbtTestingInPractice24]** Goldstein, Harrison; Cutler, Joseph W.;
Dickstein, Daniel; Pierce, Benjamin C.; Head, Andrew. "Property-Based
Testing in Practice." *Proceedings of the IEEE/ACM 46th International
Conference on Software Engineering (ICSE '24)*, Lisbon, Portugal,
2024, p. 187. ACM. DOI:
[10.1145/3597503.3639581](https://doi.org/10.1145/3597503.3639581)

**[pbtInMLProjects24]** Wauters, Cindy; De Roover,
Coen. "Property-based Testing within ML Projects: an Empirical Study."
*Proceedings of the 2024 IEEE International Conference on Software
Maintenance and Evolution (ICSME)*, 2024, pp. 648–653. DOI:
[10.1109/ICSME58944.2024.00067](https://doi.org/10.1109/ICSME58944.2024.00067)

**[icp25]** Díaz, Tomás; Maillard, Kenji; Tabareau, Nicolas; Tanter,
Éric. "Incremental Certified Programming." *Proc. ACM Program. Lang.*,
vol. 9, no. OOPSLA2, article 290, 28 pages, 2025. DOI:
[10.1145/3763068](https://doi.org/10.1145/3763068)
