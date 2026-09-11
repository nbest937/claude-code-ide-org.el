# MCP tools (`modules/tools/claude-code-ide-org/config.el`)

> Ships with the **claude-code-ide-org** plugin. `claude-org-setup` promotes
> this file into a consuming repo's `.claude/rules/` so it is always
> loaded there; until that runs it is on-demand reading, like any skill
> reference. The consuming project's own rules take priority over it.

Most tools locate a single heading by its `:ID:` property.  Every heading
Claude is expected to act on must have one (`M-x org-id-get-create`).
`org_query` is the exception — it searches across files by query, not by ID.

**Queued (change nothing when called)** — the three that caused every
incident, and the reason the queue exists:

| Tool                | Notes                                  |
|---------------------|-----------------------------------------|
| `org_set_todo`      | Records a keyword change. **Changes no TODO keyword.** Call when entering/leaving any state |
| `org_clock_in`      | Records the start of work. **Opens no clock.** Always call when entering DOING |
| `org_clock_out`     | Records the end of work. **Closes no clock.** Always call when leaving DOING |

**Immediate (act on the file when called)**:

| Tool                | Wraps                    | Notes                                  |
|---------------------|--------------------------|-----------------------------------------|
| `org_clock_report`  | `org-clock-report`       | Clocktable summary; :ID:-scoped or all |
| `org_archive`       | `org-archive-subtree`    | Respects `#+ARCHIVE:` directive        |
| `org_query`         | `org-ql-select`          | Cross-file search; not :ID:-scoped     |
| `org_capture`       | `org-capture`            | Quick-add a new TODO heading           |
| `org_refile`        | `org-refile`             | Move a subtree under a different parent |
| `org_divide`        | custom (`org-demote-subtree`) | Task mitosis: insert a new parent above a heading and demote it under. The id, clock and history stay with the **child** |
| `org_wrap_plan`     | custom (two insertions)  | Wrap the prospective part of a body in a `:PLAN:` drawer. No `until` wraps the whole body (the composition-time case); `until` marks where the debrief begins (the retroactive case). Lossless — nothing deleted or reflowed — and it refuses rather than guesses: an existing `:PLAN:` drawer, an empty body, or a missing/duplicated `until` are errors. Retroactive only since `org_amend` gained `drawer=` — composition never needs it; the two-call procedure is in the org-conventions rules ("The `:PLAN:` drawer") |
| `org_set_property`  | `org-entry-put`          | Set a property by `:ID:`. `:BLOCKER:` is validated — ids resolved, prefixes expanded, unresolvable refused — and `append` unions rather than replaces. Refuses `:ID:`/`:CREATED:` |
| `org_move_sibling`  | `org-move-subtree-up/down` | Move a heading up/down among siblings |
| `org_sort_children` | `org-sort-entries`       | Sort a heading's direct children       |
| `org_slice_add_member` | custom (insert + refresh) | Add a heading to a slice's planned checklist, with `after` for ordering; the line, cookie and `:BLOCKER:` are derived by the refresh it runs. Refuses closed slices, duplicates and keyword-less members — never hand-edit a checklist while this exists |
| `org_log_background_plan` | custom (insert-plan-link) | Write-back for background-planned headings: inserts the Plan link. Still accepts `session_id`, but no longer records it — that went with `:SESSIONS:`; never touches TODO state or the clock |

**Conditional** — writes through Emacs when it can, queues when it can't:

| Tool                | Notes                                  |
|---------------------|-----------------------------------------|
| `org_amend`         | Appends prose to a heading's body. Writes through Emacs when the file is free, and **queues the text for review when the human has unsaved changes in that buffer** — so an interjection never collides and is never lost. Prefer it over the Edit tool for body text on a tracked heading, which writes behind Emacs's back |

**Read-only**:

| Tool                | Notes                                  |
|---------------------|-----------------------------------------|
| `org_outline`       | Compact index: level, keyword, title, `:ID:`, tags — **and each heading's own body prose beneath its line** (drawers excluded; `bodies=false` for structure only), since a convention-following body is a short summary and the index then answers orientation outright (`:ID:` 2a399034). Marks `[blocked: id …]`. **Scoped to one heading it leads with that heading's front matter** — `:CREATED:`, `:CATEGORY:`, `:KIND:`, the `:BLOCKER:` *value* with each id's keyword, the plan file. Accepts an 8-character prefix as scope. Use before creating a heading |
| `org_body`          | Returns one heading whole — heading line, drawers and body — by `:ID:` or 8-character prefix, or **just one drawer with `drawer=`** (PLAN, DEBRIEF, LOGBOOK): the on-demand half of the read split, now that the outline carries bodies — a missing drawer errors naming the drawers present. Whole-heading reads filter **nothing**, `:PLAN:` included; how to read that drawer depends on the keyword (skip when finished, read when live). `include_children` for the subtree. Reach for `org_outline` first |
| `org_pending_updates` | Summary of queued-but-unapplied updates, grouped by heading. Counts *proposals*, not queue lines. This is how you check a queued call landed |

There is **no MCP tool that applies the queue**, by design. Apply is `M-x
claude-code-ide-org-review`, run by a human. If you find yourself looking
for `org_review_apply`, it is a log-source label in `config.el`, not a
tool.

Text editing (via the org skill) is used for adding or changing tags,
generating new headings, and time reporting. `org_query` now covers
structured cross-file reads (e.g. "what's blocked," "everything :research:
and not DONE") that used to mean Claude reading whole files by hand.

**Read-only buffers: nothing to do.** The file-touching tools bind
`inhibit-read-only` themselves, so a buffer the user has toggled
read-only (`C-x C-q`) is written normally and the flag is still set
afterwards. **The clear-and-restore convention that stood here until
2026-08-31 is retired** (`:ID:` c8a97d9d) — do not clear
`buffer-read-only` by hand, and do not report having done so.

It is a *binding*, never a `setq`, and that is the whole safety
property: the flag comes back when the scope exits, including on a
non-local exit, so a tool erroring part-way through cannot leave the
buffer writable. The old convention could, and the failure window was
not theoretical — restoring the flag *correctly* after an `org_amend`
is what broke a human's own apply pass on 2026-08-25.

Two things this deliberately does not cover. **Interactive commands
still ask**: `M-x claude-code-ide-org-review` prompts before apply
(`--review-ensure-writable`), because clearing a human's guard is the
human's call when a human is present to make it. And a **hand-written
`emacsclient` call** is not a tool and binds nothing — if you find
yourself reaching for one against a read-only buffer, that is a signal
the tool surface is missing something, not a licence to clear the flag.

If the user ever wants a specific buffer left alone, they'll say so
explicitly; that overrides this for that instance only.
