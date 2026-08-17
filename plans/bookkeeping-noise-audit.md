# Plan — Audit for clock/session bookkeeping noise before committing during a clocking-suppressed session

`:ID: 782cda6c-111c-454e-93eb-b2b27012078b`

## Context

Captured 2026-08-05: while one session had its own clocking explicitly
suppressed (a conversational instruction to that session, not a stored
flag anywhere — grepped `config.el`/`CLAUDE.md`/the org skill for
"suppress", the only hits are unrelated code comments and this heading's
own text, confirming there is no machine-visible "am I currently
suppressed" signal to check), it still observed real cross-session
`:LOGBOOK:`/`:SESSIONS:` deltas land on headings it touched or merely
looked at (the `PLANNING TODO state` heading and a `notes.org`
review-task heading, per the body). Open question: at commit time,
should such a session specifically vet whether the clock/session deltas
it's about to fold into a commit are genuine attributable work (its own
or another session's) vs. side-effect noise it incidentally observed or
triggered — and is that a new mechanical check or a judgment call?

### Boundary with the sibling heading (3cb3f955)

[[id:3cb3f955-f10a-47cd-84ab-e629d73ea59d][Org skill: commit a
newly-captured TODO immediately, when safe]] already has an approved-shape
plan ([[file:~/.claude/plans/capture-commit-safety.md][Plan]], read in
full). Its boundary section draws the split explicitly: that task owns
the *mechanics* of "commit the capture, when git-state-safe" via a
post-edit **diff-shape** gate — after writing a new capture heading, the
entire `git diff -- <file>` must be pure addition, entirely attributable
to the capture just written (the new heading's lines plus the
`org_set_todo`-appended LOGBOOK line). *Any* other content in the diff —
including another session's `:LOGBOOK:`/`:SESSIONS:` churn — makes that
gate decline outright, unconditionally, without attempting to classify
what the extra content is. It explicitly leaves this heading (782cda6c)
"the harder, narrower judgment call": once a file is already known to be
non-clean, *is* the extra content genuine work or noise?

This plan is that harder judgment call. It does not reopen or loosen
3cb3f955's gate.

### Grounding in real history, not the abstract

Per the research brief, I looked for what an actual clock/session-noise
diff hunk looks like in this repo's own commit history
(`git log -p -- TODO.org`), rather than reasoning about the question in
the abstract. Two commits form a directly relevant, load-bearing pair:

**`4cc769f`** ("Update session/clock bookkeeping on the PLANNING-state
task") added, to a heading originally opened by session `8564fffc…`:

```
 :SESSIONS:
 - Resumed [2026-08-04 Tue 14:37] (session 8564fffc-fca9-4e7a-bfed-e26be74361cf)
-- Paused [2026-08-04 Tue 17:37] (session c628ac7a-4135-4412-834a-1bb553d582d8)
-- Resumed [2026-08-04 Tue 17:37] (session c628ac7a-4135-4412-834a-1bb553d582d8)
+- Paused [2026-08-04 Tue 17:58] (session 73e3c11e-d45e-4a4b-9820-586bdf9d3968)
+- Resumed [2026-08-04 Tue 18:00] (session 73e3c11e-d45e-4a4b-9820-586bdf9d3968)
 :END:
 :LOGBOOK:
-CLOCK: [2026-08-04 Tue 17:37]
+CLOCK: [2026-08-04 Tue 18:00]
+CLOCK: [2026-08-04 Tue 17:50]--[2026-08-04 Tue 18:00] =>  0:10
+CLOCK: [2026-08-04 Tue 17:35]--[2026-08-04 Tue 17:40] =>  0:05
```

Every shape signal here says "genuine": `:SESSIONS:` entries alternate
correctly (Paused/Resumed pairs), CLOCK durations are plausible and
non-degenerate (0:10, 0:05), the session-id differs from the heading's
original owner, and the trailing open `CLOCK:` line is well-formed (a
real in-progress interval, not the timestamp-less corruption documented
elsewhere).

**`bc45342`** ("Clean up PLANNING-state task's clock/session
bookkeeping"), shortly after, discarded exactly that content:

> Discards a run of debugging-churn CLOCK/:SESSIONS: entries from
> chasing the clock-marker-desync and session-resume bugs (now tracked
> as their own TODOs), replacing them with a clean single pause at 16:00
> on the day the real early work happened. None of that churn reflected
> genuine work on this task.

This is the single most important finding of this plan's research: **a
shape-based check would have waved `4cc769f`'s content through as
genuine, but the project's own later judgment declared it noise.** The
churn existed because the heading was the *last-clocked* heading while
an unrelated session was chasing two other, now-separately-tracked bugs
— [[id:582cc7f4-41a2-4666-ad3f-1b76b459147e][session-resume blindly
inherits any session's last-clocked heading]] and
[[id:53b0047d-c55c-486c-8eed-ba4994d97a1a][Direct file writes to a live
org buffer can desync org-clock-marker]] — not because anyone was
actually doing PLANNING-state work. The discriminator `bc45342` actually
applied was **heading-attribution/provenance** — was there any
independent reason to believe real work happened on *this heading* —
never the entries' own text shape. Session-id tells you *who* wrote an
entry, never *whether real work happened*.

This rules out a diff-shape mechanical gate for this heading's question,
on this repo's own hardest real example — not hypothetically.

## Design

### Recommendation: prose guidance, not new tooling — with one narrow, explicit interaction with 3cb3f955's gate

Given the `4cc769f`/`bc45342` result above, a mechanical classifier can't
carry this: the real signal (did the writing session actually do
something with this heading, beyond the drawers themselves) isn't
recoverable from the diff hunk's text alone — it requires the kind of
context only a conversation-aware judgment call has. This matches the
register CLAUDE.md and the org skill already use for calls "only the
model/user can decide" (e.g. the read-only-buffer guidance, and
3cb3f955's own "why prose, not mechanical" conclusion for its narrower
sub-question).

**New org-skill subsection** — add
`## Reviewing :LOGBOOK:/:SESSIONS: hunks before a commit` to
`.claude/skills/org/SKILL.md`, placed immediately after
`## Committing a newly-captured TODO immediately` (3cb3f955's planned
subsection) if it has landed by the time this is implemented, or
otherwise in the same slot that plan specifies — after
`## Background-planning a batch of NEXT/TODO headings` and before
`## Explaining Org-Mode Syntax` (confirmed current heading list via
`grep -n '^##' .claude/skills/org/SKILL.md`; that gap is currently
empty except for whatever 3cb3f955 has or hasn't added yet). Content:

> Before folding a `:LOGBOOK:`/`:SESSIONS:` diff hunk into a commit that
> is deliberately broader than a single clean capture (marking a heading
> `DONE`, wrapping up a work session, or any commit made while your own
> clocking has been explicitly suppressed for this conversation), assess
> each touched heading's drawer hunk:
>
> 1. **Primary test — provenance, not shape.** Does the session that
>    wrote this entry have independent evidence of real work on *this
>    heading* around that time — a content edit, a TODO-state
>    transition, a Plan link, anything beyond the drawers themselves?
>    Check both the uncommitted working-tree diff *and* recent commit
>    history on that heading (`git log --oneline -- <file>` plus a look
>    at what changed) — a concurrent session that made a real content
>    edit and already committed it will leave only the drawer delta
>    uncommitted, and checking the diff alone would wrongly flag that
>    genuine case as suspect. If either shows real engagement, genuine,
>    fold it in. If the drawer delta is the *only* signal anywhere, treat
>    it as suspect: it's most likely a side effect of this project's own
>    known cross-session clock bugs (session-resume's last-clocked-
>    heading inheritance; direct-buffer-write clock-marker desync) rather
>    than real engagement with the heading.
>    Entries can alternate correctly, have plausible durations, and
>    carry a different session-id and still be noise — shape alone does
>    not settle it (see CLAUDE.md's own worked example from this
>    project's history: a well-formed delta that was later discarded as
>    debugging-churn that never reflected genuine work on its heading).
> 2. **Secondary, mechanical checks — corruption, a different problem.**
>    A bare `CLOCK:` line with no timestamp, non-alternating
>    `:SESSIONS:` entries (two `Resumed` in a row with no `Paused`
>    between), or degenerate near-zero-duration entries stacked seconds
>    apart are known bug symptoms, not a genuineness verdict either way
>    — flag and investigate separately rather than folding in or
>    discarding on this basis alone.
> 3. **Own session-id while suppressed** is a special case of test 1: if
>    a hunk carries *your own* session-id despite clocking having been
>    told to be suppressed, the suppression didn't hold. Apply test 1 the
>    same way, and separately surface the leak itself — a supposedly-
>    suppressed session writing clock data at all is worth mentioning
>    regardless of the drawer content's own verdict.
> 4. **When suspect and undecided:** don't silently fold it into a
>    commit under your authorship. Prefer leaving the file as-is and
>    surfacing the concern, same register as the capture-commit gate's
>    "leave uncommitted, say so" fallback. If a broader commit genuinely
>    can't wait, name the specific suspect hunk in the commit message
>    body and say why you believe it's genuine (or that you're including
>    it despite doubt) — match `bc45342`'s own commit message register:
>    it named exactly what was being discarded and why.
> 5. **Retrospective cleanup is a sanctioned fallback, already
>    precedented in this repo** (`4cc769f` committed noise; `bc45342`
>    cleaned it up after the fact, explaining why in its own commit
>    body) — not a mistake to avoid mentioning if it happens.
>    `claude-code-ide-org-consolidate-history` (`config.el`, callable via
>    `emacsclient`, not a new MCP tool) already automates the mechanical
>    round/merge/drop-zero-time part of a cleanup for one heading at a
>    time, and already runs automatically after every `org_clock_out` on
>    the clocking session's own heading — worth an extra manual call only
>    for a heading this session observed but never itself clocked out
>    of.

**One-sentence pointer in `CLAUDE.md`**, not a duplicated prose block —
matching this project's own stated convention
([[id:d5345abb-b451-4468-8f27-4bb2da983215][Audit CLAUDE.md for
directives that belong in the org skill instead]]: portable Org-mode
procedure belongs in the skill, CLAUDE.md carries project-scoped
pointers). Placement: "Engineering practices," not "Session tracking" —
the other commit/Plan-link/outcome-summary rules (feature-branch rule,
Plan-link rule, DONE-outcome-summary rule) already live there and use
the `**Rule**:` register; "Session tracking" is reserved for
`**Known edge case:**`/`**Known cosmetic quirk:**`-style writeups of
existing mechanism, a different register than a new committing rule. Add
one new `**Rule**:` bullet at the end of "Engineering practices":

> **Rule**: before folding a `:LOGBOOK:`/`:SESSIONS:` diff hunk into a
> commit — especially one made while your own clocking has been
> explicitly suppressed for the conversation — assess whether it's
> genuinely attributable work rather than cross-session bookkeeping
> noise. This is a judgment call, not a mechanical gate: shape alone
> (alternating entries, plausible durations, a differing session-id)
> provably fails to distinguish the two — confirmed on this repo's own
> history, commits `4cc769f`/`bc45342`: `4cc769f` added a well-formed,
> alternating, non-degenerate-duration `:SESSIONS:`/`:LOGBOOK:` delta
> under a differing session-id, and `bc45342` shortly after discarded
> exactly that content as "debugging-churn ... None of that churn
> reflected genuine work on this task" — a side effect of chasing
> unrelated clock bugs, not real engagement with the heading. See the
> org skill's "Reviewing `:LOGBOOK:`/`:SESSIONS:` hunks before a commit"
> section for the heuristic this worked example motivates.

### Resolving the interaction with 3cb3f955's gate explicitly

3cb3f955's own boundary section anticipated this task's "eventual
capability" being "consulted on the cases this task declines" — worth
pinning down precisely rather than leaving ambiguous, per that plan's own
observation that its gate "will decline more often than not fire clean"
specifically because of drawer churn.

**Decision: the checklist above never converts one of 3cb3f955's
declines into a proceed.** 3cb3f955's gate stays a strict, unconditional
decline-on-any-extra-content rule, for a reason this plan's own research
reinforces: that gate fires automatically, immediately after every
routine capture, with no foregrounded review step — exactly the setting
where the provenance judgment above can't reliably be exercised (it needs
conversational context about what *other* sessions were actually doing,
which the committing session can only ever infer, never verify), and
where a wrong "let it through" call would misattribute another session's
work — real or noisy — under this session's authorship with no human
checkpoint. Frequent + automatic + unverifiable + silent is exactly the
combination 3cb3f955 was designed to avoid by declining outright, and
loosening it here would undo that.

Instead, this task's checklist is consulted on 3cb3f955's declined cases
only as a **diagnostic enrichment**, never an override: when 3cb3f955
declines because of drawer churn specifically, the response can name what
kind of drawer content triggered the decline using this checklist's
categories (e.g. "left uncommitted — TODO.org also has what looks like
debugging-churn clock data on heading X from another session, see
782cda6c's checklist" vs. "left uncommitted — other unrelated content
present"). The decline itself is unchanged either way. This is the
explicit, non-ambiguous resolution the two plans need to compose
correctly rather than silently conflicting.

## Files

- `.claude/skills/org/SKILL.md` — new subsection (see Design above).
- `CLAUDE.md` — one new `Rule:` bullet in "Session tracking" (see Design
  above).
- No `config.el`/`config-test.el` changes — pure prose guidance, same as
  3cb3f955's plan; `bin/test`'s ERT suite is unaffected and gets no new
  tests.

## Verification

Per CLAUDE.md's testing rule, this is a documented manual verification
pass for the prose-guidance portion — whether a future Claude session
actually notices and applies unprompted guidance is the same fuzzy
trigger-matching CLAUDE.md's own testing rule explicitly says isn't worth
forcing into a deterministic test — plus a mechanical retro-classification
check against real historical data, which *is* checkable and was
substantially done already during this planning pass:

**Mechanically checkable now, re-runnable as-is (retro-classification
against real history):**
1. Apply test 1 to `4cc769f`'s diff: `git show 4cc769f --stat` confirms
   only `TODO.org`'s drawer lines changed, nothing else on the heading —
   no corroborating content edit accompanies the drawer churn. The
   checklist correctly flags it suspect, matching `bc45342`'s later
   verdict.
2. Contrast with a genuine case, to confirm the checklist doesn't
   over-flag ordinary same-session activity: any of this repo's own
   "Add TODO: ..." capture commits (e.g. `7989347`, `cbf7da2`) pairs a
   `:LOGBOOK:` state-change line with the new heading it belongs to in
   the *same* commit, written by the *same* session in the *same* turn —
   test 1's "independent evidence of real work on this heading" is
   satisfied trivially and correctly classifies it genuine.

**Manual walkthrough after the SKILL.md/CLAUDE.md edits land:** this
touches `TODO.org`'s live drawers and the single global clock
(`org-clock-marker`), so — same premise as this whole heading — run it
only when no other session is concurrently active against this repo, and
never combine it with an actual clock-in on the scratch heading (that is
exactly how `53b0047d`, cited above as design evidence, was triggered —
hand-editing a drawer while a clock is open on it risks desyncing the
marker; this walkthrough must not reproduce the bug it cites):
1. Create a disposable scratch heading with a `:SESSIONS:`/`:LOGBOOK:`
   already present but **not currently clocked in** (e.g. a closed CLOCK
   interval from a prior manual edit, or copy the drawer shape from an
   existing closed heading) — never open a live clock on it during this
   walkthrough.
2. Simulate cross-session drawer noise by hand-appending a further
   `:SESSIONS:`/`:LOGBOOK:` entry under a different, fabricated
   session-id, with no accompanying content edit to that heading, no
   corresponding commit, and no active clock anywhere in the file.
3. Ask Claude (in a session primed with the new guidance) to commit a
   change touching that file, and confirm it applies test 1 (checking
   both the working-tree diff and `git log` on the heading, per the
   evidence-window clause above), flags the hand-appended entry as
   suspect rather than silently folding it in, and explains why per the
   checklist's categories.
4. Repeat with a *legitimate*-looking accompanying edit (e.g. also change
   the heading's tags or body in the same commit) and confirm the
   checklist now treats the drawer delta as attributable and proceeds.
5. Clean up the scratch heading and any throwaway commits afterward —
   verification exercise, not real project history.

## After approval

If this plan is approved and implemented, add the
`[[file:~/.claude/plans/bookkeeping-noise-audit.md][Plan]]` link to
heading `782cda6c-111c-454e-93eb-b2b27012078b` in `TODO.org` per
CLAUDE.md's Plan-link rule (as soon as planning finishes — this file
being finalized counts, independent of whether/when the heading is
promoted to `DOING`). Per CLAUDE.md's "two separate checkpoints" rule, do
**not** transition the heading to `DOING` or begin the `SKILL.md`/
`CLAUDE.md` edits without a further, explicit go-ahead beyond plan
approval.
