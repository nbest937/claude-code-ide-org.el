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
*** Plan [2/5]
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

### Editing & transforming

- **Change TODO state**: update the keyword on the heading line; if the file uses
  LOGBOOK state-change entries, append one with the current timestamp.
- **Add/remove tags**: edit the tag cookie at the end of the heading line.
- **Add a CLOCK entry**: insert inside `:LOGBOOK:` (create the drawer if absent);
  compute the `=>  H:MM` duration.
- **Close an open clock**: fill in the end timestamp and compute the duration.
- **Always preserve**: indentation, drawer structure, existing entries — do not
  reformat content the user didn't ask to change.
- **Check off completed subtasks as you go**: when a checkbox item under a
  heading represents a planned implementation step and that step is actually
  finished, change `[ ]` to `[X]` right then — don't batch it for later, and
  don't leave a plan looking stale once the work it describes is done.
- **Only check a box once the work is verified, not merely attempted.** A
  step that "should have worked" or returned a success message is not the
  same as a step that's confirmed done — inspect the actual result (run the
  test, read the file back, check the output) before marking it. Treating a
  tool's own success claim as sufficient is exactly the kind of gap that has
  produced real, silent bugs in this project before.
- **Recompute statistics cookies whenever you check a box.** Update the
  enclosing `[N/M]`/`[P%]` cookie (heading-level or list-level, see above) to
  match the new count. If a cookie's scope is ambiguous, hand-count the
  checkboxes rather than guess — a wrong cookie is worse than no cookie.

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
- **A "Plan" checklist is a sub-heading, not bold text.** When a heading needs an
  implementation-steps checklist, make it a heading one level deeper — e.g.
  `**** Plan [/]` under a `***` feature heading — rather than a bold paragraph
  (`*Plan:* [/]`) followed by a plain list. A heading is independently foldable
  with TAB; a bold paragraph sitting above a list is not — Org's plain-list
  cycling only ever folds one list item's own children at a time (with point on
  that item's own first line), never the whole list, so there is no point at
  which TAB collapses a bold-text "title" together with the checklist under it.
- **Two blank lines before a level-2 (`**`) heading that has no TODO
  keyword** — the top-level section dividers of a file (e.g. `** Roadmap`'s
  own children), as opposed to the individual TODO-tracked items nested
  under them. Everywhere else — before a TODO-item heading (`*** DONE ...`,
  `*** MAYBE ...`), a `**** Plan [...]` sub-heading, or any other content —
  a single blank line is the norm. The extra line at level 2 only, and only
  when untagged-by-TODO-state, is a deliberate visual break between major
  sections; doubling it everywhere would just be noise.

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
