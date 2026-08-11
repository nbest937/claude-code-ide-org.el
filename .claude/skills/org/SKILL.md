---
name: org
description: >
  Use this skill whenever the user wants help with Emacs Org-Mode files (.org).
  Covers reading and parsing .org files, editing or transforming them, explaining
  Org-Mode syntax, managing TODOs and task states, working with priorities and tags,
  and handling CLOCK drawers and time-tracking data. Trigger when the user mentions
  .org files, Org-Mode, org-agenda, TODO keywords, SCHEDULED/DEADLINE timestamps,
  CLOCK entries, org-clock, or asks about task management in Emacs. Also trigger when
  the user shares a block of Org-Mode text and wants it modified, analyzed, or
  explained.
---

# Org-Mode Skill

This skill helps Claude work expertly with Emacs Org-Mode files. The focus areas are:

1. **TODO & task management** — reading, editing, and generating task hierarchies with
   keywords, priorities, tags, and properties
2. **Clocking & time tracking** — parsing CLOCK drawers, computing durations, generating
   summaries and reports
3. **Syntax explanation** — explaining any Org-Mode construct clearly

---

## Org-Mode Syntax Reference

### Headings & TODO keywords

```org
* Heading level 1
** Heading level 2
*** TODO Task not yet started
*** NEXT Up next / prioritised
*** DOING Actively being worked on
*** WAIT Blocked or waiting on someone
*** MAYBE Someday / maybe
*** DONE Completed
*** CANCELLED Cancelled
```

Default keyword set used by this skill:
`TODO NEXT DOING WAIT MAYBE | DONE CANCELLED`

The `|` separates active (incomplete) states on the left from terminal (done) states on
the right. `DONE` and `CANCELLED` trigger Org's "task complete" behaviour (closing
timestamp, struck-through in the agenda). The five states to the left are all active.
Priority is expressed through keyword choice — do not add `[#A]`/`[#B]`/`[#C]` priority
cookies unless the user explicitly asks.

### Tags

```org
* Meeting with Alice :work:urgent:
```

- Tags are colon-delimited, attached to the heading line, preceded by a
  single space — never column-aligned/right-justified with padding. Padding
  to a fixed column is a known source of display bugs: `org-indent-mode`
  prepends invisible synthetic stars to headline lines (proportional to
  outline depth) that are normally styled to blend with the background, but
  a long padded line is more likely to soft-wrap, and the wrap point is a
  separate rendering path where that blending can visibly break down.
- Tags inherit downward through the heading hierarchy.
- Tags are free-form; declaration is optional but enables fast-selection (`C-c C-q`).

**Standard tags for this user's files:**

```org
#+TAGS: code comms research review
```

| Tag          | Meaning                                   |
|--------------|-------------------------------------------|
| `:code:`     | Software / technical work                 |
| `:comms:`    | Communication, writing, outreach          |
| `:research:` | Investigation, reading, learning          |
| `:review:`   | Review, feedback, evaluation              |

### Archiving convention

`DONE` items tagged `:code:` are archived to `DONE.org`. Set this at the top of
any file that tracks code work:

```org
#+TAGS: code comms research review
#+ARCHIVE: DONE.org::* Done
```

With this in place, `C-c C-x C-a` on a `DONE :code:` heading moves it into the
`* Done` section of `DONE.org`, preserving the full subtree including
LOGBOOK and CLOCK drawers.

For tasks **not** tagged `:code:`, the same `#+ARCHIVE:` directive applies unless
overridden per-heading. If the user wants non-code DONE items to go somewhere else,
they can set a per-heading override:

```org
* DONE Write project proposal                                   :comms:
  :PROPERTIES:
  :ARCHIVE: archive.org::* Done
  :END:
```

**When helping the user archive items:**
- Confirm the tag before suggesting `DONE.org` as the target.
- Remind the user that `C-c C-x C-a` does the move in Emacs; Claude can also
  produce the correctly-formatted entry for manual insertion into `DONE.org`.

### Timestamps & scheduling

```org
SCHEDULED: <2025-03-15 Sat>
DEADLINE:  <2025-03-20 Thu>
<2025-03-15 Sat 14:00>          ; active timestamp (shows in agenda)
[2025-03-15 Sat 14:00]          ; inactive timestamp (does not show in agenda)
<2025-03-15 Sat 14:00-15:30>    ; time range
<2025-03-15 Sat +1w>            ; repeater (every week)
```

### Properties drawer

```org
* My Task
  :PROPERTIES:
  :ID:       abc-123
  :EFFORT:   1:30
  :CUSTOM:   value
  :END:
```

### Dependencies between tasks

```org
* DONE Build the foundation
  :PROPERTIES:
  :ID:       e47ac400-dd17-4e6a-91aa-bcd837151610
  :END:

* TODO Build the walls
  :PROPERTIES:
  :ID:       799b14be-6849-4e22-8a76-4e214d8a25fe
  :BLOCKER:  e47ac400-dd17-4e6a-91aa-bcd837151610
  :END:
```

- `:BLOCKER:` on a heading names the `:ID:` of another heading that must
  reach a done state first — a native Org (org-depend) mechanism, not a
  project-specific one. Prefer it over a prose "depends on ..." sentence
  in the body whenever the blocking heading has a stable `:ID:`, since a
  property is machine-checkable and a sentence isn't.
- `:BLOCKER:` can hold multiple IDs space-separated; the blocked heading
  can't be marked done until every listed ID is.
- The inverse relationship — this heading, once done, unblocks another —
  is `:TRIGGER:`, placed on the *blocking* heading and naming the ID(s)
  it unblocks. Use whichever direction reads more naturally at the
  heading being edited; the two are equivalent in intent, not both
  required.
- Whether anything actually *enforces* the block (e.g. an
  `org-blocker-hook` function that consults `:BLOCKER:` and refuses a
  DONE transition while it's unsatisfied) depends on what hooks are
  registered in the user's Emacs config — the property is always valid
  Org syntax and worth recording either way, even absent enforcement.

### LOGBOOK drawer & state changes

```org
* DONE Fix the bug
  :LOGBOOK:
  - State "DONE"       from "TODO"       [2025-03-14 Fri 17:22]
  :END:
```

### Checkboxes & progress cookies

```org
- [ ] Not yet done
- [X] Done
- [-] Partially done / in progress
```

A statistics cookie — `[/]` (fraction) or `[%]` (percentage) — placed on a
heading line or a plain-list item tracks how many of its checkboxes are
checked:

```org
*** Pack for the trip [2/5]
- [X] Step one
- [X] Step two
- [ ] Step three
- [ ] Step four
- [ ] Step five
```

- `[/]`/`[%]` with no numbers yet is the uncomputed placeholder; it becomes
  `[N/M]` or `[P%]` once recomputed.
- A cookie on a **heading** counts every checkbox anywhere in that heading's
  subtree, however deeply nested. A cookie on a **plain-list item** counts
  only the checkboxes belonging to that specific list.

### CLOCK entries

```org
  :LOGBOOK:
  CLOCK: [2025-03-14 Fri 09:00]--[2025-03-14 Fri 11:30] =>  2:30
  CLOCK: [2025-03-13 Thu 14:00]--[2025-03-13 Thu 15:45] =>  1:45
  :END:
```

- Format: `CLOCK: [START]--[END] =>  H:MM`
- An open clock (no end) looks like: `CLOCK: [2025-03-14 Fri 09:00]`
- Duration `=>  H:MM` is computed from start/end; Claude should verify arithmetic when
  editing or reporting.

---

## Working with .org Files

### Reading & parsing

When the user shares an .org file or snippet:

1. Identify the heading hierarchy and TODO states.
2. Note any tags, priorities, scheduled/deadline dates.
3. Collect CLOCK entries; parse durations (see Clock Arithmetic below).
4. Summarize what you found before making any changes.

### State transition conventions

When helping the user move a task between states, follow these conventions:

| Transition              | Meaning                              | Side effect                  |
|-------------------------|--------------------------------------|------------------------------|
| `TODO` → `NEXT`         | Decided to do it soon                | None                         |
| `TODO` → `DOING`        | Starting work immediately            | Open a CLOCK                 |
| `NEXT` → `DOING`        | Starting work                        | Open a CLOCK                 |
| `DOING` → `DONE`        | Finished                             | Close the open CLOCK         |
| `DOING` → `WAIT`        | Blocked mid-task                     | Close the open CLOCK         |
| `DOING` → `CANCELLED`   | Abandoning                           | Close the open CLOCK         |
| `WAIT` → `DOING`        | Unblocked, resuming                  | Open a CLOCK                 |
| Any → `MAYBE`           | Deferring indefinitely               | None                         |

**Rules:**
- Transitioning **to `DOING`** always opens a new CLOCK entry (with start timestamp,
  no end yet).
- Transitioning **out of `DOING`** always closes the open CLOCK (fill in end timestamp
  and compute duration).
- Always append a LOGBOOK state-change note when changing TODO state:
  `- State "NEW"  from "OLD"  [timestamp]`

### Plan Mode checkpoint

`ExitPlanMode` approval and "start implementing" are always two separate
checkpoints — never treat plan approval alone as license to proceed
straight into implementation, even under an auto-accept mode that
otherwise biases toward not stopping. After a plan is approved, stop and
get the user's explicit confirmation before doing any of: adding a Plan
link to the task heading, transitioning that heading to `DOING` (or
`PLANNING` → `DOING`), or making any code/file edits the plan describes.
This holds regardless of whether the heading the plan is for already
existed or is newly created as part of the plan.

### Editing & transforming

- **Change TODO state**: update the keyword on the heading line; if the file uses
  LOGBOOK state-change entries, append one with the current timestamp.
- **Add/remove tags**: edit the tag cookie at the end of the heading line.
- **Add a CLOCK entry**: insert inside `:LOGBOOK:` (create the drawer if absent);
  compute the `=>  H:MM` duration.
- **Close an open clock**: fill in the end timestamp and compute the duration.
- **Always preserve**: indentation, drawer structure, existing entries — do not
  reformat content the user didn't ask to change.

### Inserting content programmatically

Writing org text from Elisp (via `emacsclient`, which is how larger edits
are made when the file is open in a live Emacs) fails *silently* in two
specific ways. Neither errors, and neither is visible in the return value.

- **Any line starting with `* ` becomes a heading.** A horizontal rule
  written as `* * *`, or prose that happens to wrap so a line begins with
  an asterisk and a space, silently creates a top-level heading and
  re-parents everything after it. Use `-----` for a rule. Note `*bold*`
  at line start is safe — it takes `*` followed by a *space*.
- **`org-end-of-subtree` on a parent lands past all its children.** Text
  inserted there belongs to the parent's **last child**, not the parent,
  because org body text attaches to the nearest preceding heading. This
  is correct for inserting a new *child heading* and wrong for inserting
  *body text* on the parent. For body text on a heading that has
  children, insert before its first child (`outline-next-heading`)
  instead.

So verify after every programmatic insert, before moving on:

```elisp
(list :headings (length (org-map-entries (lambda () t)))
      :parses (condition-case e (progn (org-element-parse-buffer) t)
                (error (format "%S" e))))
```

A heading count that moved by anything other than the number of headings
you meant to add is the `* ` trap. To check *ownership* — which heading a
block of text actually landed under — find the text's line number and
walk back to the nearest preceding heading; do not assume.

Prefer `org-element-map` over line regexps when deleting or rewriting
whole drawers, so a `:DRAWERNAME:` mentioned in *prose* is never matched
as a real drawer.

### Generating .org content

When creating tasks or files from scratch, or when adding tasks to an existing file:

- Check for `#+TODO:` or `#+SEQ_TODO:` lines at the top of the file. Use those keyword
  sets rather than assuming `TODO`/`DONE`.
- Use standard 2-space indentation for drawer content.
- Follow the heading → PROPERTIES → LOGBOOK order (properties first, then logbook).
- Use the Org date format exactly: `[YYYY-MM-DD Dow HH:MM]` for inactive,
  `<YYYY-MM-DD Dow HH:MM>` for active. Day-of-week abbreviations: Mon Tue Wed Thu
  Fri Sat Sun.
- Emit `=>  H:MM` with **two spaces** before `H:MM` (this is the canonical format).
- **A single space before a heading's tag, never column-aligned.** Don't pad
  with spaces to push `:tag:` out to a fixed column, even though many Org
  setups do this by default (`org-tags-column`) — see "Tags" above for why.
- **Two blank lines before a level-2 (`**`) heading that has no TODO
  keyword** — the top-level section dividers of a file (e.g. `** Roadmap`'s
  own children), as opposed to the individual TODO-tracked items nested
  under them. Everywhere else — before a TODO-item heading (`*** DONE ...`,
  `*** MAYBE ...`) or any other content — a single blank line is the norm.
  The extra line at level 2 only, and only when untagged-by-TODO-state, is a
  deliberate visual break between major sections; doubling it everywhere
  would just be noise.

---

## Clock Arithmetic

When computing or verifying clock durations:

1. Parse start and end as `HH:MM` on their respective dates.
2. Duration = end − start in minutes, then convert to `H:MM`.
3. For a task with multiple CLOCK entries, sum all durations.
4. If the user asks for a time report, group by day or by heading as requested.

**Example total computation**:
```
CLOCK: [2025-03-14 Fri 09:00]--[2025-03-14 Fri 11:30] =>  2:30   (150 min)
CLOCK: [2025-03-13 Thu 14:00]--[2025-03-13 Thu 15:45] =>  1:45   (105 min)
Total: 255 min = 4:15
```

Emit totals as `H:MM` (not decimal hours) unless the user asks otherwise.

---

## Time Reporting

When the user asks for a clocking summary or report, produce a structured breakdown:

```
Task: Fix the bug
  2025-03-13 Thu    1:45
  2025-03-14 Fri    2:30
  ─────────────────────
  Total             4:15
```

If multiple tasks are present, list each task with its subtotal, then a grand total.
Align columns for readability. If the user wants a specific date range, filter entries
accordingly.

---

## Background-planning a batch of NEXT/TODO headings

When asked to kick off planning for several open `NEXT`/`TODO` headings at
once (rather than one heading at a time, interactively), parallelize the
*research* but keep the *write-back* serialized. This project's org clock
and PLANNING ownership are single global in-memory variables — there is
exactly one clock, shared across every session touching the file — so N
simultaneous `PLANNING` owners is structurally impossible, not merely
risky. Only read-only research that writes solely to its own plan file
(`~/.claude/plans/<slug>.md`) is safe to genuinely run in parallel.

1. Use `org_query` to list open `NEXT`/`TODO` candidates.
2. Pick up to **3** headings per batch (matches this project's own
   Plan-Mode-workflow convention of launching up to 3 Explore agents in
   parallel).
3. Launch one background agent per heading (the `Agent` tool), each doing
   read-only research and `Write`-ing its own plan file. Each agent's
   brief must state explicitly: never call `org_set_todo`, `org_clock_in`,
   or any other state/clock-mutating tool — research and plan-file writing
   only.
4. As each agent reports its plan file is finalized, call
   `org_log_background_plan` for that heading — **one call at a time**,
   only after that specific agent is done, never in parallel with another
   heading's write-back. Pass `session_id` as
   `<this session's own real session id>-bg<N>` (the Nth agent in the
   batch) — a synthetic id derived from, but never equal to, the
   orchestrating session's real id, so unattended background research time
   is never misattributed as that session's own interactive work.
5. Leave TODO state as-is (still `NEXT`/`TODO`). Promoting a heading to
   `PLANNING`/`DOING` on the strength of a background plan is a separate,
   later, interactive decision — not part of this batch.
6. Don't auto-commit the resulting diff. Leave it for explicit review.

`org_log_background_plan` inserts the `[[file:...][Plan]]` link
(idempotent — a heading only ever carries one). It never touches
`:LOGBOOK:`, the TODO keyword, or the clock — the single-clock model
can't represent true parallelism honestly, so this path doesn't try.

It still takes a synthetic `session_id`, but no longer records it
anywhere: that was a `:SESSIONS:` drawer entry, and the drawer was
retired 2026-08-11 (TODO.org `:ID: 9d2fcdad-…`). Pass it anyway — the
argument is still validated, and it is the natural hook if per-session
attribution comes back as a queued event.

---

## Explaining Org-Mode Syntax

When the user asks what something means:

- Quote the exact construct from their file.
- Explain what it does in plain English.
- If relevant, show a before/after or a minimal working example.
- Point out common gotchas (e.g., active vs. inactive timestamps, tag inheritance,
  repeaters vs. one-off dates).

---

## Common Gotchas to Watch For

- **Open clocks**: a CLOCK line with no `--[END]` means the clock is still running.
  Don't compute a duration; flag it to the user.
- **Custom TODO keywords**: users often have `#+TODO:` lines at the top of their file
  defining custom states. Respect those rather than defaulting to `TODO`/`DONE`.
- **Tag inheritance**: a tag on a parent heading is inherited by children in the agenda,
  but is NOT physically present on child headings. Don't add it redundantly.
- **Drawer indentation**: drawer content (`:PROPERTIES:`, CLOCK lines, etc.) must be
  indented to be inside the heading, typically by 2 spaces relative to the heading stars.
- **Day-of-week**: always include and verify the day abbreviation in timestamps. Getting
  it wrong is valid Org but misleading.
