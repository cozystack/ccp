---
name: comment-audit
description: Audit code comments for design-doc prose — rationale, product motivation, before/after narrative, incident retelling — and report which ones to cut, which to tighten, which to keep, and which arguments are restated at several sites. Use this whenever reviewing a diff or PR that reads comment-heavy, whenever someone says a change has "too many comments", "excessive comments", "comment bloat", "essays in the code", or asks whether comments are justified, and as a matter of course on any PR that adds a large block of commentary to a function or package doc. Reports only; pair with `cozystack:comment-trim` to apply the cuts. Language-agnostic — works on any repository, not only Cozystack ones.
argument-hint: "[PR number | file | diff base] [--all] (default: lines the change added)"
---

# cozystack:comment-audit

Decide which comments in a change carry their weight and which are a design doc pasted into the source, then report both lists with line anchors and quoted text so a human can act without re-reading the diff.

This skill **does** read the working tree, the diff, and the repository's docs, and **does** produce a written report. It **does not** edit files, stage, commit, push, or comment on a PR. It is read-only end to end — there is nothing to gate, because nothing mutates. Use `cozystack:comment-trim` to apply the cuts.

Work in reasoning mode. Follow the phases in order. Use the phrasing "`cozystack:comment-audit`" (not "the skill") in messages to the user, and announce phase transitions: `cozystack:comment-audit Phase N — <name>`.

Match the operator's natural language detected from prior conversation messages — use it in the report's prose, section headings, and justifications. Quoted comment text, file paths, line anchors, and code identifiers stay verbatim in their original form.

## The rule

A comment earns its place when it tells the reader something the code cannot:

- **Non-obvious mechanism** — an aliasing or mutation hazard, an ordering constraint, a pointer receiver that mutates its receiver, a value that must be copied before use.
- **Why not the obvious approach** — a reader would reach for X; X is wrong here, and here's the mechanism that makes it wrong. This is the single most valuable kind.
- **A deliberate omission that reads as a bug** — why this error is swallowed, why this interface skips a validator, why this field is not checked.
- **A non-local constraint** — "only the key set is read", "must match the vocabulary declared in Y", "callers rely on this ordering".
- **Silent failure** — whenever getting it wrong produces no error, just a wrong answer that looks right. Bias hard toward keeping these.

A comment is design-doc prose when it argues rather than informs:

- **Product or business rationale** — "this is a product requirement, not an optimization", "users asked for this in feedback".
- **Evolution narrative** — "before this change", "weaker than what shipped previously", "used to accept". The reader does not have the old behavior and should not need it.
- **Incident retelling** — "this is the bug that took the API down for an hour last quarter". Post-mortem material.
- **UX reasoning** — "so the user can act without a support round-trip".
- **Defending against an alternative nobody proposed** — paragraphs justifying a choice that was never contested.
- **Editorializing** — "the single most load-bearing line in this file".
- **Restating the code** — the comment and the line below it say the same thing.

The test is not length. A twelve-line comment about a mutation hazard is fine; a three-line one about why the product wants this is not.

But length is not free either, and "it is all true" is not a defence. A doc comment is a **reference, not an explanation**: it tells a reader what they must not get wrong, in the fewest words that carry the claim. Prose that derives a conclusion — laying out the question, the wrong answer, then the right one — belongs in the design doc even when every sentence of it is correct. A block of nine true mechanism sentences where two would do is a finding, and the verdict for it is *Tighten*, not *Keep*.

## Do not judge by density

Resist computing comment-to-code ratios and comparing against neighboring files. If the file or its neighbours already carry design-doc prose, the local average is exactly the thing under review — matching it certifies the problem. Judge each comment on its own register. Ratios are at most a way to pick which file to read first, never evidence for a finding.

## Phase 1 — Scope the audit

Default to what the change **added**: the diff against the merge-base (`git diff <base>...HEAD`, or the PR's merge-base as reported by `gh pr view <n> --json baseRefName`). Pre-existing prose is a separate cleanup — a small change should not be made to fix a style it merely inherited, though it should not extend it either. Call out explicitly which side of that line each finding sits on.

`--all` audits whole files instead of the added lines. Use it only when the operator asks for it; it turns a review-sized report into a refactor proposal.

Resolve and state back: the base revision, the file list, and whether the run is diff-scoped or `--all`.

## Phase 2 — Classify every added comment block

Read each added comment block **in full** — a block skimmed is a block misclassified. Classify each against the rule above.

Quote the actual text in the report. A reviewer acting on "too wordy" has nothing to act on; a reviewer acting on a quoted sentence and a line anchor does.

## Phase 3 — Sweep for duplication

This is the highest-yield phase and it is easy to miss by reading linearly. The same argument frequently appears in a package or module doc, again inline at the call site, again in the design doc, and again in the PR description.

Grep for distinctive phrases from each substantial comment block across the repository and the diff:

```bash
grep -rn "<6-10 distinctive words>" --include='*.<ext>' . docs/
```

Two copies of an argument means one of them goes. Where a comment exists to stop code and a design doc drifting apart, the fix is a **pointer**, not a shorter paraphrase:

```text
// see docs/<path> §"<section>"
```

A paraphrase is a second copy that will drift; a pointer cannot.

**Grep finds copied phrasing. It cannot find a paraphrase, and the nearest copy is usually a paraphrase.** So follow the grep with a reading check on every substantial block: look at what is declared immediately around it — the type's field docs, the neighbouring case arms, the function signature itself — and ask whether the block re-states in prose what those already say in place. This is the highest-yield duplication in practice and grep will never show it, because the two copies share no distinctive words:

```go
// RouteLink is the ifindex the FIB would send out of.
// OwnerLink is the ifindex the address is CONFIGURED on.
...
// Two questions hide in here: the FIB answers "how would I SEND to this
// address", which says nothing about the link the address lives on...
```

The field docs already carry the distinction; the paragraph is a second copy in expository form. Keep the copy at the declaration, where a reader meets the concept, and cut the prose restatement.

## Phase 4 — Build the keep list

Every audit must name the comments that should survive. Without it the request reads as "fewer comments" and comes back as the same arguments in shorter sentences.

Build this list as you go through Phase 2 rather than as an afterthought — a keep list assembled at the end tends to be thin, because by then the reader is in cutting mode.

## Phase 5 — Sort keepers into Keep and Tighten

A two-verdict audit (cut or keep) has nowhere to put the most common defect in a comment-heavy change: a block whose claims are all legitimate and which is still three times longer than it needs to be. Every block that survives gets a second pass:

- the claim is load-bearing and the wording is already minimal → **Keep**;
- the claim is load-bearing but stated expositionally → **Tighten**, and quote the shorter form you propose, so the author is choosing between two concrete texts rather than being told to trim;
- the claim is load-bearing and a linked design doc already carries it → **Tighten to the pointer**: the comment collapses to `// see docs/<path> §"<section>"` and the explanation goes. A pointer plus the explanation it points at is two copies, not a citation.

Read each surviving block **cold** before deciding: not as the person who worked the problem out, but as someone who arrives at the file with no memory of the change. Every sentence feels load-bearing to whoever just derived it, which is why a self-audit that skips this step reliably keeps everything.

## Report format

```text
## The rule
[one short paragraph, stated once — not repeated per finding]

## Cuts
**<file>**
- `:<line>` — "<quoted text>". <one line: which category, and what survives if anything>
...

## Tighten
**<file>**
- `:<line>` — <what the block claims, and why the claim stays>. Proposed: "<the shorter text>"
...

## Keep
[the comments that earn their place, with a phrase each on why]

## Duplication
[each argument that appears at N sites, with all N anchors]

## Scope note
[what is pre-existing and therefore out of scope]
```

State the rule **once, at the top**. Per-bullet justification makes every item read as a taste call and invites a line-by-line argument.

## Handing off

When the operator wants the cuts applied, hand off to `cozystack:comment-trim` and pass the report — that skill applies nothing it has not classified, so an audit already in context saves it a full re-read.

## Anti-goals

- **Never forecast an aggregate line count.** "This should cut 140–160 lines" sets a number the work is then measured against, and it runs high: most blocks keep a sentence rather than vanishing, so a complete pass lands well under the guess and reads as under-delivery when the estimate was simply wrong. Quote the item list. The list is the ask.
- **Don't sweep test comments in with the rest.** Explaining why a fixture is `96` documents the test's purpose and is legitimate. Flag only the same violations — incident retelling, before/after narrative — and say so explicitly, or the author will strip comments that were doing real work.
- **Don't audit generated files.** Comments in `zz_generated*`, deepcopy, mocks, OpenAPI and vendored code come from a generator; findings there are unactionable.
- **Don't treat operator-facing config docs as code comments.** Comments in `values.yaml`, chart templates, `.env` samples and flag help text are documentation for a different audience, and verbosity there is usually correct.
- **Don't relitigate the code.** If the implementation has a real bug, that is a separate finding in a separate report; do not bury it in a comment audit.
