# State transition rules

> Ships with the **claude-code-ide-org** plugin. `claude-org-setup` promotes
> this file into a consuming repo's `.claude/rules/` so it is always
> loaded there; until that runs it is on-demand reading, like any skill
> reference. The consuming project's own rules take priority over it.

**"Side effect" below means the call you must make, not something that
happens to the file.** Every entry queues an event; the CLOCK line appears
when a human applies it. The rules are unchanged by that — you still make
exactly these calls, in exactly these places — but nothing in this table
edits an org file at the moment you act.

| Transition                | Side effect                         |
|---------------------------|-------------------------------------|
| `TODO`     → `NEXT`       | None                                |
| `TODO`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `DOING`    → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `WAITING`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `REVIEW`     | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `WAITING`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DONE`       | None                                |
| Any        → `MAYBE`      | None                                |

**The table describes setting a keyword because the work is happening
now.** Under `DOING`'s looser sense — started and owed, not executing —
a keyword can also be set *retroactively*, and then none of the clock
column applies. See the rules below.

`REVIEW` is **experimental** (TODO.org `:ID:` c954f650) — finished work
handed back for human judgement. Clock-wise it behaves exactly like
`WAITING`: entering it closes the clock, leaving it for `DOING` opens one,
and `REVIEW` → `DONE` touches nothing because no clock is running. These
rows were added 2026-08-21; until then the keyword was in live use with
its clock semantics written down nowhere.

**`REVIEW` → `DONE` is the expected exit; `REVIEW` → `DOING` is the
exception** (the user, 2026-08-26). Going back to `DOING` means the review
found something *missing or broken* — it is rework, not the normal close.
Read the two rows above in that light: the clock reopens only because
work resumed, and most `REVIEW` headings should never reach that row at
all.

Which makes the keyword a claim worth being careful with. Setting
`REVIEW` asserts the work is finished and only judgement remains, so a
heading parked there to mean "not sure yet" is misusing it — that is
`WAITING`, or it is still `DOING`.

**`DOING` means started and owed a return — not executing right now.**
The useful metaphor is *in the mail*: we have begun and need to circle
back as soon as possible. It is durable and **plural**; several headings
may be `DOING` at once. What records actual execution is the *clock*,
not the keyword, and at most one heading carries a running clock because
org runs one.

On a **grouping** — a story or a slice — the same word reads one level
up: at least one member is in the mail. That sense opens *no automatic*
clock, and takes no `NEXT` either, since both belong to a member.

**`REVIEW` on a grouping means every member is terminal and the work has
not yet integrated** (the user, 2026-09-11). It names the window between
the last member closing and the grouping's own deliverable landing — for
a slice carrying code, between the final commit and the pull request
merging. The clock column needs nothing new: entering it closes the
grouping's clock only if the grouping holds the running one, exactly as
the `from DOING` rule already says, and `REVIEW` → `DONE` at the merge
touches nothing.

The window needs a name because review findings on a branch arrive
*after* every member is terminal, by construction — an implementation
cannot be reviewed until it is implemented. So a slice closing on "all
members done" closes before its own review exists. `:ID:` c19fbbf5 did
exactly that, and its review's findings had nowhere to go, a closed
slice's membership being a record. The close condition that follows from
this is in the org conventions, "Closing a slice".

**This is the keyword's first use on a grouping.** Measured 2026-09-11:
twelve slices had existed and not one had ever carried `REVIEW`, so this
paragraph is the whole of its grouping sense — expect it to need
sharpening in use rather than to be settled.

**A grouping may still be clocked deliberately, and that is not a
defect.** `:ID:` 3964c575 proposed that groupings carry no clock at all;
declined 2026-08-26. A parent's own coordination and planning time is
real work, and a blanket "only leaves may be clocked" rule discards it —
which is what `--container-heading-p`'s docstring has said all along. So
the exemption is deliberately narrow: it suppresses the *automatic*
clock a state change would open, never a deliberate `C-c C-x C-i`.

Two consequences worth stating, since both have been read backwards. The
nine groupings carrying their own CLOCK lines today are **history, not
debt** — each was clocked honestly while it was still a leaf, and became
a grouping later by acquiring children or by a refile. Nothing is to be
migrated. **That is amnesty for what already happened, not a licence to
make more**: each of those arose by accident, and choosing the shape
deliberately today is the error the story conventions now name (org
skill, "Dividing a heading that outgrew itself"). And the resulting ambiguity is a **reporting** problem, not a
data one: measured 2026-08-26, a clocktable row for a parent shows own
plus subtree as one number and its own share appears nowhere, recoverable
only by subtracting every child (`:ID:` 64d34a64). Both triggers
now ask `claude-code-ide-org--grouping-heading-p`, which is the union of
the two ways a heading can be one: a container is *emergent* (it acquired
keyworded children) and a slice is *declared* (`:KIND: slice`). Until
2026-08-26 they asked the container predicate alone, so a slice was
clocked and auto-promoted like an action, its members being links rather
than children (`:ID:` 95c27fca).

Note which predicate goes where. `--grouping-heading-p` is right wherever
the question is about *meaning* — whose clock, whose next action. Where
the question really is "does this have TODO children", as in
`bin/lint-org`'s statistics-cookie rule, the narrow container predicate
stays.

GTD's one-thing-at-a-time is not being followed here, deliberately. That
rule is calibrated to human working memory; an agent re-reading a
checklist each turn has different limits, and keeping several started
items visible is what stops them being silently dropped.

Consequences, each of which has been got wrong in practice:

- **A leaf held for *the user's* judgement is `WAITING`, not `DOING`** —
  nothing is owed by us, so nothing is in the mail.
- **A heading that was worked and set down stays `DOING`.** Demoting it
  to `NEXT` or `TODO` loses the fact that it is owed. This reverses an
  earlier draft of this section, which claimed the keyword tracks
  attention rather than progress and that no "started but resting" state
  should exist; that is exactly the state `DOING` is for.
- **Setting `DOING` retroactively is safe through the queue, and only
  through the queue.** `org_set_todo` opens no clock by itself, and apply
  binds `--trigger-auto-clock-in` off for every item it lands — measured
  2026-08-26, and pinned by
  `claude-code-ide-org-test-review-suppresses-the-auto-clock-in-trigger`.
  A hand `C-c C-t` to `DOING` in Emacs *does* clock in at once, so
  recording that something *was* started is a queue action rather than a
  keystroke. See `:ID:` 4f6a6bb1.

**Rule**: a transition *to* `DOING` opens a clock **when you are starting
work now** — the ordinary case, and what the table above describes. One
exception: a **retroactive** `DOING` — recording that a heading was started earlier — opens nothing,
because the work did not happen now. **The queue honours that exception,
so such a transition may be queued freely.** This said the opposite until
2026-08-26 and was wrong the whole time (`:ID:` 4f6a6bb1): `org_set_todo`
and `org_clock_in` are separate calls precisely so state and clock are
decided separately, and apply suppresses the trigger outright. The one
path that does *not* honour it is a hand `C-c C-t` in Emacs — where a
human is present to know which act they are performing.

**A second exception: a _grouping_.** A story or a slice entering
`DOING` opens no automatic clock, because on a grouping the keyword
means "at least one member is in the mail" rather than "work is
happening here". `--trigger-auto-clock-in` declines when
`--grouping-heading-p` is true.

**Note where that exemption actually bites, because it is narrower than
it reads.** The trigger tests `--auto-clock-in-active` *before* it tests
for a grouping, and apply binds that variable around the whole pass — so
on the apply path the trigger short-circuits for **every** heading,
grouping or leaf, and the grouping test is never reached. The exemption
therefore does its work in exactly one place: a TODO state changed *by
hand* in Emacs (`C-c C-t`, `S-right`). And it suppresses only the
*automatic* clock, never a deliberate `C-c C-x C-i` — a grouping's own
coordination time is real work and may be clocked on purpose.

**Rule**: a transition *from* `DOING` closes the clock **if this
heading's clock is the one running**. Because `DOING` is plural, a
heading can be `DOING` with no clock — another heading holds it — and
there is then nothing to close.
**Rule**: always use the MCP tools for state changes and clocking — do not
edit CLOCK entries or TODO keywords by hand when the tools are available.
If the `emacs-tools` MCP server is *not* connected, prefer stopping and
saying so over reaching for `emacsclient`: a direct `org-todo` call applies
immediately and writes **nothing** to the queue, so the change is invisible
to the review pass and to `org_pending_updates`. That is a real divergence
between the file and the record, not a harmless shortcut.

**Rule**: confirm the `emacs-tools` server is actually reachable *before*
the first state or clock call of a session, rather than discovering it
when a call fails. Check by calling `org_pending_updates` — it is
read-only, and a reply proves the server is up in a way that the tools
merely appearing in a list does not. If it is unreachable, say so before
doing anything that would otherwise have been queued.

This is a standing rule because the failure is silent and the fallback is
tempting: on 2026-08-15 the server did not connect at session start,
nothing announced it, and three state changes went through `emacsclient`
and never reached the queue. Nothing in the transcript looked wrong at the
time. The user should not have to ask for this check.

**And it can hang.** The `#+TODO:` line carries per-keyword logging
cookies: `!` records a timestamp on entry, `@` *prompts for a note*. In
this project `WAITING(w@/!)` and `CANCELLED(c@)` carry `@` and nothing else
does — so a transition driven non-interactively through `emacsclient -e`
blocks on a prompt for **those two keywords and only those two**. That
asymmetry is one of the reasons state changes go through the queue rather
than being applied live: apply runs inside a genuinely interactive command,
where the prompt is answerable.
**`PLANNING` was retired 2026-08-28** (`:ID:` c954f650), and with it the
`ExitPlanMode` promotion hook, the cross-session owner guard, and four
rows of the table above. Measured across the project's whole history
before removing it: 7 `PLANNING` transitions in 432 state changes, on 6
of the 24 days the keyword existed and absent from the three busiest;
43 headings carried a plan link and 7 of them ever wore it; and the
premise it was built on — long spans of agent work in Plan Mode — held
for one of the seven, four having clocked nothing at all inside the
window. All seven exited to `DOING`, so it never distinguished an
outcome.

Nothing replaced it, deliberately. A "plan approved" event was
considered and declined: nothing would consume it, and this project's
precedent (`:ID:` 7771fc63) is to delete a mechanism whose premise
failed rather than reimplement it more cheaply. **Plan Mode now needs no
state change of its own** — a heading is `DOING` while it is being
planned and implemented, which is what `DOING` already meant.

**Rule**: before a session's first act that changes anything — a repo
edit, a capture, an amend, any immediate org tool — name the heading the
work belongs to and call `org_clock_in` on it, or on "Review and
planning" (that exact title) for cross-cutting meta-work: review,
planning, deciding what to do rather than doing it. No heading yet means
capture one first, with an `initial_state`. The trigger is the *first
write, not the ask*: a session that opens as a question drifts into
tracked work, and the drift is invisible from inside the session doing
it — on 2026-09-03 three sessions worked through the immediate tools
alone and every span reached review UNASSIGNED (`:ID:` ccfd89ce). A
purely read-only session owes nothing. `bin/hooks/clock-target-check`
backstops this at turn end, once per session: write activity in the
transcript with no `clock_in` in the queue blocks the stop with a
reminder. It reports; it cannot name the heading — that judgement is
this rule's alone.

**Rule**: when asked to start work on a task tracked as an org heading with
a `:ID:`, transition it to `DOING` via `org_set_todo` *before* beginning,
unless it's already `DOING`. This has to be a standing instruction, not a
hook — deciding "this conversation is now doing that task" is a judgment
call about intent, which only the model can make. Hooks can only enforce
the mechanics of a transition once it's triggered — and that safety net
**is live** (corrected 2026-08-21; this prose said "not built yet" long
after it was). On `org-blocker-hook`: `org-depend-block-todo` (refuses
DONE while a `:BLOCKER:` names unfinished work) and
`claude-code-ide-org--blocker-clock-running-p` (refuses DONE while the
heading's own clock is running). On `org-trigger-hook`:
`--trigger-auto-clock-in` (opens the clock the moment DOING is
set by hand — gated by `claude-code-ide-org-auto-clock-in-on-doing`,
default `t`), plus `--trigger-demote-conflicting-next`, live and
ungated **inside a container**.

**`NEXT` belongs to a container's *members*, and nothing sets it by
itself** (`:ID:` 62b65ad0, 2026-08-26). Read that carefully: `NEXT` is
meaningful *within* a story, and **a story must never carry it** —
promoting one declares a project to be an action, which is `:ID:`
42808717. "Belongs to containers" was the original phrasing here and read
as the opposite of what it meant.

**A slice is the exception, and the rule was split on 2026-09-02 to say
so** (`:ID:` abce1850). It previously read "within a story *or a slice*",
which neither source heading argued: `:ID:` 42808717 was written six days
before slices existed and never mentions them, and `:ID:` 62b65ad0
mentions them once in 5,418 characters. The generalisation was
editorial.

And it does not hold, because the two groupings differ in the way that
matters. A story is *emergent*; its next action is one of its children,
so naming the parent names no action. A slice is *declared and
sequenced*, and **several are open at once** — three on the day this was
written — with nothing in the vocabulary saying which to pick up.
`DOING` on a slice means at least one member is in the mail, which is
state rather than priority.

So **a slice may carry `NEXT`, and it means "this is the slice to pick up
next"** — a portfolio-level nomination, not an action. Three constraints
keep it from re-creating the confusion `:ID:` 42808717 named one tier
down:

- **At most one top-level `NEXT` per `:CATEGORY:`, slices included**
  (`:ID:` 758a8b78, 2026-09-03 — generalising the original "at most one
  slice carries it"). Within the Slices category, mechanism work and
  starting a slice compete for the same nomination, which is a
  deliberate forcing function. A story's *internal* `NEXT` is exempt —
  it is a memoization of where to start upon entering the story, not a
  portfolio nomination — and a slice's *members* may show several
  `NEXT`s, since they are references reflecting other groups'
  nominations.
- **It does not substitute for a member's `NEXT`.** The two answer
  different questions — which slice, and which action inside it — and a
  slice marked `NEXT` whose members are all `TODO` is still
  un-nominated.
- **Nothing sets it automatically**, exactly as before. Sequencing
  slices is a judgement, and the retired promotion trigger is the
  standing evidence for what happens when that judgement is mechanised.

An auto-promotion trigger (`--trigger-auto-promote-sole-todo`) stood
here and is gone.

Two things went wrong with it, and only the second is obvious in
hindsight. It nominated badly: three of roughly eight top-level
promotions ended up parked as `MAYBE`. And its sibling group was a
*category* — `--map-siblings` walks with `org-get-next-sibling`, which at
top level stops only at the file's boundary — so "the sole remaining
`TODO` in Tooling" was a claim about a filing drawer, not a project. That
is `:ID:` 42808717 one tier up: it taught the trigger to refuse a
container because promoting one declares a project to be an action; this
retires the case where the *group* is the wrong kind of thing.

`--trigger-demote-conflicting-next` survives, scoped the same way: it
declines at top level, where there is no sibling group worth the name.
Having a parent is the test, since a keyworded heading with a parent
makes that parent a container by definition.

**What replaced the promotion is a report, not a rule.**
`--nomination-candidates-context` names every grouping whose live
members include no `NEXT`, at `SessionStart`, alongside the
stale-interval and ceremony reports — and it *asks* rather than acting,
which is the contract those reports already keep. It names a sole
candidate and merely counts several, because that is the case no rule
can decide. Measured on this corpus the day it shipped: five groupings,
each a real un-nominated project.

**Rule**: every transition *to* `DONE` **inside a grouping** nominates
the next action — set `NEXT` on whichever remaining member should be
picked up next, or say in a sentence that no clear candidate exists.
Leaving the group silently un-nominated is the thing to avoid. Closing a
*top-level* task nominates nothing, because it has no group; several
top-level `NEXT`s at once are expected and correct — at most one per
`:CATEGORY:` (`:ID:` 758a8b78), which is what a workstream now means.

Since 2026-08-26 this is the *whole* invariant rather than half of it.
`--trigger-demote-conflicting-next` still gives at most one `NEXT` per
container, but nothing gives you one automatically any more — setting
`NEXT` is strictly intentional, and the report only points. GTD's actual invariant is that a live project
always has a next action; a project without one is the canonical defect a
weekly review exists to catch.

**Rule, same moment**: any work the closing debrief names as *not done*
becomes a filed heading before the `DONE` is queued — or the debrief says
explicitly that it is not worth filing. **A sentence pointing at another
heading is not a filing action**, and neither is "belongs to X".

This exists because both halves happened in one session, hours apart, and
nothing distinguished them at the time. `:ID:` e1284bdb was closed *after*
its unfinished half was split out as `:ID:` 601c885c. `:ID:` aa1ba915 was
closed with its gap described in prose as belonging to `:ID:` edd47f32 —
which was never told, and whose four children did not include it. The user
caught it a day later by asking whether the heading was really done.

The reason prose is not enough is structural rather than a matter of
diligence: residue named in a *closed* heading's body sits in a document
readers are told to treat as history, and `org_wrap_plan` will eventually
sweep it into a `:PLAN:` drawer readers are told to skip. It is on a path
to becoming invisible from the moment it is written.

Note this is a strictly stronger claim than the nomination rule above.
Nominating answers "what next in this group"; this answers "what did
closing this leave behind", which may belong to no group yet.

**Rule**: when nominating, call out blockers that live in a *different*
subtree. Name the blocking heading and where it is; a `:BLOCKER:` property
is the machine-checkable form. A dependency inside the same sibling group
needs no announcement — anyone reading that group can already see it — but
a cross-subtree one is invisible from either side. Note that a `:BLOCKER:` naming a
heading captured in the same session is **inert** until a human applies
the queue *if that capture was keywordless* — `org-depend` blocks only on
an unfinished TODO keyword. Since 2026-08-31 `org_capture` takes an
`initial_state`, so pass one and the blocker bites immediately (`:ID:`
c74f8663). Omitting it is still right for a note rather than a task, and
then the old caveat applies unchanged.
**Rule**: any time a new task is described in conversation, create an org
heading for it (with a `:ID:`) and set its initial TODO state, rather than
only tracking it in conversation memory. Same reasoning as above — this is
a judgment call about what counts as "a task," so it has to be a standing
instruction, not something a hook could infer.
**Rule**: any newly created org heading gets a `:CREATED:` property in its
property drawer, stamped with an inactive timestamp (`[YYYY-MM-DD Dow
HH:MM]`) at creation time, alongside its `:ID:`. Applies to every heading
creation, not just the "new task described in conversation" case above.
**Its live scope is the text-editing creation path alone** (audited
2026-09-04, `:ID:` d5345abb): every MCP creation path — `org_capture`,
`org_divide` — stamps both automatically, and `org_set_property` refuses
the property outright, so only a hand-generated heading can miss it. The
skill's "Generating .org content" section carries the same rule for that
path.
**Rule**: when a new org heading is created as the direct result of an
approved Plan Mode plan, write only that heading (title, tags, properties,
any Plan-file link, intro body) and stop — show it and get explicit
approval before transitioning it to `DOING` or touching anything else the
plan describes. Approving a Plan is not approval of the heading's exact
wording. (This used to note that the `ExitPlanMode` auto-promotion hook
could not affect the rule; the hook was deleted with `PLANNING` on
2026-08-28, so nothing promotes anything automatically now.) The
more general form of this rule — `ExitPlanMode` approval and "start
implementing" are always two separate checkpoints, not just for newly
created headings — lives in the org skill (its `SKILL.md`,
"Plan Mode checkpoint") rather than here, since it's a way-of-working for
Claude Code's Plan Mode generally, not an org-file convention specific to
this repo.
