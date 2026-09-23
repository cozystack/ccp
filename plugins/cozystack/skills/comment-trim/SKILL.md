---
name: comment-trim
description: Apply a comment trim — delete design-doc prose, rationale essays, before/after narrative and duplicated arguments from code comments while preserving every comment that documents a real mechanism, then prove mechanically that only comments changed. Use this when acting on review feedback about excessive or unjustified comments, when asked to "trim the comments", "cut the prose", "clean up the essays in this file", or as the follow-up to `cozystack:comment-audit`. Leaves the result in the working tree for review rather than committing. Language-agnostic — works on any repository, not only Cozystack ones.
argument-hint: "[audit file | PR number | file] (default: act on the audit in context)"
---

# cozystack:comment-trim

Turn a comment audit into edits. Delete what argues, keep what informs, and finish by proving the change moved no code.

This skill **does** modify files in the working tree, and **does** run the bundled verifier plus the project's own build / lint / tests for the packages it touched. It **does not** stage, commit, push, open PRs, or comment on a PR — the edits are left in the working tree for a human to review. Gate-and-confirm discipline applies: read-only lookups (diff, grep, verifier) run freely; before the first edit, state the file list and the claims being cut and get an explicit go-ahead; if the operator asks for a commit afterwards, that is a separate approval.

Work in reasoning mode. Use the phrasing "`cozystack:comment-trim`" (not "the skill") in messages to the user, and announce phase transitions: `cozystack:comment-trim Phase N — <name>`.

Match the operator's natural language detected from prior conversation messages — use it in prompts, gates, and the final report. The comment text actually written into the source, code identifiers, file paths, and any commit message stay in their canonical form (usually English).

If no audit exists in context, run the `cozystack:comment-audit` rule set first to produce one — apply nothing you have not classified.

## The failure this skill exists to prevent

The natural response to "too much comment prose" is to write the same arguments in fewer words. That fails the review a second time, because length was never the complaint — a rationale belongs in the design doc, the commit message or the PR body, and compressing it does not move it out of the source.

**Work claim by claim, not block by block.** Enumerate the distinct assertions a comment block makes, decide keep or cut on each one by register, and then act:

- a **cut** claim must be *absent* afterwards, not shorter;
- a **kept** claim keeps saying what it said, though you may tighten its wording.

Both operations shrink the block, so line count cannot tell you whether the trim happened. The check that can: name a claim you meant to cut and ask whether the file still asserts it, in any number of words. If it does, you compressed when you should have deleted.

The specific trap is using compression as a substitute for deletion. Shrink a block that is four-fifths rationale by a factor of four and it is still four-fifths rationale — unchanged in exactly the respect the reviewer objected to.

**Worked contrast.** Original:

> Retrying here is a product requirement, not an optimization. A transient network blip losing an upload is the worst experience this feature has, and before this change a single 503 anywhere in the batch discarded every part that had already succeeded.

Compressed — *fails*. Three claims in, three claims out; 70% shorter and still rationale:

> Retries exist because a transient blip used to discard an entire batch, which is unacceptable for uploads.

Deleted, with a pointer — *passes*. "It is a product requirement", "the worst experience this feature has" and "a 503 used to discard the batch" are now absent; a mechanism fact and an address remain:

> Retries resume from the last acknowledged part, so the per-part handler must be
> idempotent — see `docs/design/upload.md` §"Retry semantics".

Tightening a **keeper** is not this failure and is often an improvement. A nine-line proof that loses its closing restatement and says the same thing in four has cut a claim and compressed the rest — exactly right. The only caution is churn: a reworded line costs a reviewer more attention than an untouched one, so tighten where it helps and leave the rest alone.

## Phase 1 — Scope

Touch only what the change under review added. Pre-existing prose in the same file is a separate cleanup — mixing it in makes a feature diff unreviewable and takes on an argument the author never started. Note in the report what you left and why.

Leave generated files (`zz_generated*`, deepcopy, mocks, OpenAPI), vendored code, and operator-facing configuration docs (`values.yaml`, chart templates, flag help text) alone.

State the file list and the per-file claim list, then get the operator's go-ahead before the first edit.

## Phase 2 — Cut

**Delete outright** — product and business rationale, evolution narrative ("before this change", "used to"), incident retelling, UX reasoning, paragraphs defending a choice nobody contested, editorializing, and any comment that restates the line below it.

**Replace with a pointer** where a comment existed to keep the code and a design doc in sync:

```go
// Retries resume from the last acknowledged part — see
// docs/design/upload.md §"Retry semantics".
```

A paraphrase is a second copy of the argument and will drift; a pointer cannot. Cite the real section heading so the reference survives the document being reorganized.

**A pointer replaces the argument; it never accompanies it.** Adding the citation and leaving the explanation above it is the "second copy" this rule exists to prevent — and it is an easy mistake to make, because the block now ends with something that looks like the fix. If you write a pointer, the thing it points at goes in the same edit.

**Tighten** — where the audit says the claim stays but the wording derives it. Rewrite to the shortest form that still carries the claim, and check the result the same way as a cut: the block must now *state* the constraint rather than *argue* to it. "It is all true" does not earn nine sentences where two carry the same warning.

**Keep the claim** — mechanism, aliasing and mutation hazards, ordering constraints, "why not the obvious approach", deliberate omissions that read as bugs, non-local constraints, and anything whose violation fails silently. Verbatim by default; tighten only where the wording is genuinely in the way. When in doubt about a comment in this class, keep it: a surviving mechanism note costs a reviewer three seconds, and deleting one costs the next person an afternoon.

**Deduplicate.** Where an argument appears in a package doc and again inline, one of them goes. Keep the copy at the site that constrains the code — usually the branch or call site, since that is where someone is standing when they consider changing it — and delete the distant one.

**Rewrite tense, don't delete, for past-tense invariants.** "Omitting the tenant prefix let one tenant's entries answer another tenant's reads" is incident retelling, but the invariant underneath is real. It becomes "cache keys must carry the tenant prefix: without it entries collide across tenants and a read returns another tenant's value."

## Phase 3 — Verify

Three checks, in order. None is optional — a trim whose correctness rests on having read the diff carefully is worth much less than one that has been proven.

1. **Comments only.** The bundled script strips comments from both sides and compares what is left, so a stray edit cannot hide in a large diff:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/skills/comment-trim/scripts/comments-only.py" <base-rev> [<head-rev>]
   python3 "${CLAUDE_PLUGIN_ROOT}/skills/comment-trim/scripts/comments-only.py" --files OLD NEW
   ```

   (If `$CLAUDE_PLUGIN_ROOT` is unset, the script lives at `scripts/comments-only.py` next to this SKILL.md.)

   It is string-aware — URLs inside literals, Go raw strings, rune literals and Rust lifetimes do not fool it. Exit 0 means no code moved; 1 names the files where it did; 2 means a file's language was not recognised and needs a human look. Investigate any non-zero result before reporting; the usual cause is a real accidental edit.

2. **Pointer invariant.** For every `see docs/...` you added, confirm the explanation it replaces is gone — grep the file for a distinctive phrase from the deleted argument and expect no hit. A pointer sitting on top of the prose it cites is the failure this skill's central rule names, and it survives the comments-only check untouched.

3. **The project's own checks** for the packages touched — build, linter, and the tests for those packages only, never the whole suite. A comment trim cannot break a test, which is exactly why a failure here means something else went wrong and must be chased rather than waved through.

## Phase 4 — Report and stop

Leave the edits in the working tree. Do not commit unless asked — batching the whole trim into one commit after a human has looked at it is cheaper than a string of fixups, and the author may want to fold it into an existing commit.

Report:

- what was cut, by file, grouped by category rather than listed line by line;
- what was deliberately kept, so the reader can see the mechanism notes survived;
- the verification result, stated plainly ("comments only; build, lint and the touched packages' tests pass");
- anything from the audit you did **not** apply, with the reason. Silently skipping an item is worse than declining it.

If you are asked to commit, the message should state the rule and what moved, not re-argue the rationale — the same discipline the edit is enforcing. "Comments should carry the mechanism, not the product rationale; every argument removed here is already in the design doc" is the whole body.

## Anti-goals

- **Don't shorten an essay and call it deleted.** The check is whether the file still asserts the claim, not whether the block got smaller. This is the single most likely way this goes wrong.
- **Don't cut the keep list.** If an audit named comments to preserve and they are gone, the trim overshot and a reviewer now has to restore them from history.
- **Don't strip test comments wholesale.** Explaining why a fixture is `96` is the test documenting its own purpose. Only the same violations apply — narrative and incident retelling.
- **Don't improve the code while you are in there.** A rename or an extracted helper turns a provably-comments-only change into one that needs a real review.
