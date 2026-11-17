# Releasing through a pull request (Hulder port) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Approved

**Goal:** Hulder's `scripts/release` lands its release commit through a pull request, exactly as
Muninn's does, by porting Muninn's script and test whole.

**Architecture:** No new design. Muninn's `scripts/release` and `scripts/tests/test-release-dry-run`
are copied from one reviewed Muninn commit with Muninn's names mapped to Hulder's. The test then
loses Muninn's zap cases and takes Hulder's fixture string. README, `AGENTS.md` and the
distribution spec take Muninn's documentation edits from the same commit, names mapped, so the
repositories' docs stay alike.

**Tech Stack:** bash (3.2-compatible), git, `gh`, `/usr/bin/python3` for `scripts/changelog.py`.

**Spec:** `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`; canonical design:
Muninn's spec of the same name
(`https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`).

**Port source:** `SRC` = the commit at the tip of Muninn's `fix/release-via-pr` once Codex's
pre-merge review of Muninn's pull request approves it; it includes Muninn's documentation (its
plan's Task 7). Muninn's session sends the id. The controller writes its full id here and
commits the plan before Task 1 starts. Every `SRC` below means that id.
`SRC` = `092d5f8d2d083a789b2f5545543febbd68b14878` (Muninn PR #8; pre-merge review receipt
`xr-1794905228-ba53f276`; Muninn's release suite 475/475 there).
`M` = a Muninn checkout holding `SRC` (`~/Code/Netronix/muninn-fix-release-via-pr`).

**Execution notes:** tasks run in order, 1 then 2 then 3, in this checkout. If
`fix/accessibility-grant` merges first, rebase onto `main` before Task 3; only `README.md` and
`AGENTS.md` can conflict, and only outside the lines Task 2 edits.

## Global Constraints

- The only differences from Muninn's two files, names mapped, are the zap helper and its four
  cases, and the fixture string `"Hulder v1: hide other apps"`. Nothing else is adapted, fixed or
  improved here; a defect found in the ported code goes back to Muninn's line, not into this port.
- The name mapping is exactly `sed -e 's/Muninn/Hulder/g' -e 's/muninn/hulder/g'`.
- Run `scripts/tests/test-release-dry-run` and `scripts/release --dry-run` outside the agent
  sandbox (`AGENTS.md`). They need the signing certificate, `brew` and `gh`.
- `scripts/release` is never run without `--dry-run`.
- No `CHANGELOG.md` entry.

## Review Focus

- A Muninn-only string the mapping turns into a wrong Hulder one, or misses: the port check
  (Task 1, Step 4) shows only the allowed hunks, and `rg -i muninn` over the two files finds
  nothing.
- The global `core.hooksPath` on this Mac: the suite passes without `GIT_CONFIG_GLOBAL=/dev/null`,
  because Muninn's suite now pins each bare repository's hooks path (Task 1, Step 5).
- The executable bit on the two files: `git diff --summary main` shows no mode change (Task 1,
  Step 4).
- The real `gh` login on this Mac lacking the `repo` scope or admin role: the dry run then prints
  `Note: a real release would stop here: …` and still exits 0. Task 3 reports that note, because
  acceptance 5 would fail on it.
- A dry run that writes anything: Task 3 compares refs, pull requests and releases before and
  after.

---

### Task 1: Port the release script and its test

**Depends on:** none (the `SRC` gate above)

**Files:**
- Modify: `scripts/release`, `scripts/tests/test-release-dry-run`

**Interfaces:**
- Consumes: Muninn's `SRC:scripts/release` and `SRC:scripts/tests/test-release-dry-run`.
- Produces: the ported files that Task 2 documents and Task 3 runs.

- [ ] **Step 1: Port the test.** Write `git -C "$M" show SRC:scripts/tests/test-release-dry-run`,
  mapped, over `scripts/tests/test-release-dry-run`. Then make the two allowed changes:
  - delete the `zap_is_settings_only` function with the two comment lines above it and the blank
    line after it, and the block of zap cases from
    `expect "a: the cask zaps only the settings" …` through
    `expect "a: a delete elsewhere fails" …`, with the `zap_extra`, `zap_list` and
    `delete_elsewhere` fixture lines inside it;
  - in the case `a: the section holds only the fixture's text`, replace `"Hulder records calls"`
    with `"Hulder v1: hide other apps"`.

- [ ] **Step 2: Run the ported test against today's script; it fails.** Outside the sandbox:
  `scripts/tests/test-release-dry-run`. Expected: a non-zero exit, with the pull-request cases
  (merge rights, landing, resume, tidy-up) among the failures. This is the port's revert check.

- [ ] **Step 3: Port the script.** Write `git -C "$M" show SRC:scripts/release`, mapped, over
  `scripts/release`. No other change.

- [ ] **Step 4: Port check.** Run:

```bash
T=$TMPDIR/port-check; mkdir -p "$T"
for p in scripts/release scripts/tests/test-release-dry-run; do
  git -C "$M" show "SRC:$p" | sed -e 's/Muninn/Hulder/g' -e 's/muninn/hulder/g' >"$T/${p##*/}"
  echo "=== $p"; diff "$T/${p##*/}" "$p"
done
rg -n -i muninn scripts/release scripts/tests/test-release-dry-run
git diff --summary main -- scripts
```

  Expected: no diff for `scripts/release`. For the test, exactly three hunks: the helper with
  its comments, the fixture-string line, and the zap cases. `rg` prints nothing, and
  `git diff --summary` prints no mode change.

- [ ] **Step 5: Run the suite; every case passes.** Outside the sandbox, without
  `GIT_CONFIG_GLOBAL`: `bash -n scripts/release scripts/tests/test-release-dry-run`, then
  `scripts/tests/test-release-dry-run`. Expected: exit 0. Report the totals as passed/total.

- [ ] **Step 6: Commit** `Release through a pull request, as Muninn does`, with the body
  `Ported from michaelrigart/muninn@SRC (names mapped; without Muninn's zap cases).`

### Task 2: Documentation, in Muninn's wording

**Depends on:** Task 1

**Files:**
- Modify: `README.md` ("Releasing"), `AGENTS.md` (the Release command line; "Releases and CI"),
  `docs/superpowers/specs/2026-11-03-hulder-distribution-design.md` (one header line)

**Interfaces:**
- Consumes: Muninn's documentation edits at `SRC` (its plan's Task 7), seen with
  `B=$(git -C "$M" merge-base origin/main SRC); git -C "$M" diff "$B" SRC -- README.md AGENTS.md docs/superpowers/specs/2026-11-03-muninn-distribution-design.md`.

Hulder's release docs equal Muninn's at `B`, names mapped, apart from two things that stay
Hulder's: the README's `design/render` sentence, and "Michael" where Muninn's `AGENTS.md` says
"the maintainer". Each step applies Muninn's edit to the same place, names mapped, and keeps
those two.

- [ ] **Step 1: README.** Apply Muninn's edit of its "Releasing" section.

- [ ] **Step 2: AGENTS.md.** Apply Muninn's edits of the Release command line and of
  "Releases and CI". Muninn's release-flow pointer goes where Muninn puts it, relative to the
  "Distribution design" line. Keep the file's 100-column wrap.

- [ ] **Step 3: Distribution spec.** Add the header line Muninn adds to its distribution spec,
  names mapped, after Hulder's `**Template:**` paragraph and before `## Why`. The rest of the
  document is not changed.

- [ ] **Step 4: Check.** Run:

```bash
T=$TMPDIR/port-check; mkdir -p "$T"; B=$(git -C "$M" merge-base origin/main SRC)
git -C "$M" diff -U0 "$B" SRC -- README.md AGENTS.md docs/superpowers/specs/2026-11-03-muninn-distribution-design.md |
  sed -e 's/Muninn/Hulder/g' -e 's/muninn/hulder/g' | rg -v '^(diff |index |--- |\+\+\+ |@@)' >"$T/docs-m"
git diff -U0 HEAD -- README.md AGENTS.md docs/superpowers/specs/2026-11-03-hulder-distribution-design.md |
  rg -v '^(diff |index |--- |\+\+\+ |@@)' >"$T/docs-h"
diff "$T/docs-m" "$T/docs-h"
rg -n 'HEAD:main|and pushes\)' README.md AGENTS.md scripts/release
```

  Expected: `diff` shows only lines that hold "Michael" instead of "the maintainer", and the
  rewrap those words cause. `rg` finds only the tap clone's push in `scripts/release`.

- [ ] **Step 5: Commit** `Describe releasing through a pull request`.

### Task 3: Acceptance on this Mac (controller)

**Depends on:** Tasks 1–2

- [ ] **Step 1: Full suite on the final commit.** Outside the sandbox: core tests, platform
  tests, `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`,
  `scripts/tests/test-release-dry-run`. Report each as passed/total.

- [ ] **Step 2: Dry run creates nothing.** Outside the sandbox, record before and after
  `scripts/release --dry-run`:
  `git for-each-ref`, `git ls-remote origin`,
  `gh pr list --repo michaelrigart/hulder --state all --json number,headRefName`,
  `gh release list --repo michaelrigart/hulder` and `git status --porcelain`.
  Expected: exit 0, every listing unchanged, last line
  `Dry run: nothing committed, branched, pushed, merged, tagged or published.` Report whether it
  printed `Note: a real release would stop here: …`, with the note's text.

- [ ] **Step 3: Pull request and CI.** Open the draft pull request; set this plan's and the
  spec's `**Status:**` to `In progress` with its reference. CI passes on it (acceptance 4).
  In the final pre-merge commit, set both to `Implemented` with the pull request. Acceptance 5
  (the next real release) stays Michael's after the merge.

- [ ] **Step 4: Merge order.** Hulder's pull request is ready to merge only when the pull requests
  of all five ports in the canonical design (Muninn, Hulder, Linger, Tafl and Skald) are open and
  Muninn's has merged. The final report lists each one's state, and says which are still missing
  if any are.
