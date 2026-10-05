# Citing tracked work by `:ID:`

> Ships with the **claude-code-ide-org** plugin. `claude-org-setup` promotes
> this file into a consuming repo's `.claude/rules/` so it is always
> loaded there; until that runs it is on-demand reading, like any skill
> reference. The consuming project's own rules take priority over it.

**When a response refers to tracked work by an opaque identifier — an org
`:ID:` prefix, an issue number, a ticket key — cite the identifier in the
prose and append end matter mapping each one to its exact, full title.**
Never paraphrase or truncate the title.

**Why:** expanding titles inline makes paragraphs too wordy to scan, but a
truncated or paraphrased title does not carry enough context to interpret
the reference. The end matter resolves the tension: the prose stays
readable and every reference stays fully recoverable.

## Canonical form

After a `---` separator, one line per identifier, **sorted by
identifier**, each line being the backticked id, then the TODO keyword
padded to a column, then the exact title *including any cookie*:

```
`2a6a1355`  REVIEW    Three new ways to owe a footnote and not see it: marker, list, quotation
`c19fbbf5`  DONE      [19/19] Ship the plugin: make the machinery and its prose travel together
```

The id leads because it is what the eye scans for, having just met it in
the prose. The keyword is second and column-aligned because it is the
volatile field — misalignment is how a stale keyword goes unnoticed, and
a trailing `*` on it means the state is queued rather than applied (see
"How to apply"). The
cookie belongs to the title, because `[8/9]` and `[16/16]` are the part
most often wrong when recalled. Backticks earn their place separately:
the terminal renders them in a distinct face, which is what makes the id
findable at a glance.

**No superscript markers, and no ordering by appearance** (retired
2026-09-16). *The identifier is already the key*, and sorting by it makes
each entry's position deterministic. Markdown footnote syntax (`[^1]`)
renders its brackets literally in the terminal.

## How to apply

Trigger on any response containing such an identifier, not only ones
about the tracker — identifiers get cited while reading source, writing
tests and summarising commits too.

**Deliver end matter with `org_footnotes`** (`:ID:` 30d05c93): call it
last before a reply citing a tracked id, with `ids` those the reply
cites. It generates the lines, keywords looked up and a queued one
starred, adds ids the narration cited, and folds them into the call; the
reply carries no `---` block. Where it answers that it is not wired,
write them by hand, looking each keyword and title up.

**Where a keyword change is queued and not yet applied, show the *queued*
state and mark it with a trailing `*`** — `REVIEW*`, not `DOING` plus a
sentence explaining that `REVIEW` is pending:

```
`2a6a1355`  REVIEW*   Three new ways to owe a footnote and not see it: marker, list, quotation
```

The `*` is the whole notation, and **it takes no note of its own** (the
user, 2026-09-17): a parenthetical saying which entries are queued is a
footnote to the footnote. Unstarred means "applied, on disk"; the on-disk
value stays recoverable through `org_pending_updates`.

**One entry per distinct identifier**, per *response*: a re-mention
needs no second entry, but the reader of the twentieth message does not
have the fourth one on screen.

**An id paired with its exact title *on one line* needs no end-matter
entry.** So a list whose items are headings — a status summary — pairs
each id with its title and owes nothing below; a list of *bare* ids is
the named failure. The pairing must be on the **same line**: a reader
scanning for the id must find the title beside it.

**A response citing many headings in prose owes an entry for each, and
that is the convention working** — a hook block on a long reply is the
backstop doing its job. A rendered session footnotes its ids (`:ID:`
9bc8fc8c), but the terminal rule does not relax for that.

**The "exact, full" requirement is about the title only.** An
8-character `:ID:` prefix is adequate on the identifier side, written the
same short way the prose writes it. Writing an id *into* a file — an org
link, a `:BLOCKER:`, a commit message — is the opposite case and still
needs the full value, looked up rather than recalled.

**Commit SHAs are not org `:ID:`s and must not look like them.** A 7-hex
SHA and an 8-hex prefix are visually identical. Spell the word: *commit
`b146008`*, never a bare `b146008`. A SHA opens no end-matter debt — it
is not tracked work and has no title to look up. Inside an `.org` body
the form is `[[orgit-rev:./::<sha>][<sha>]]`; see the org
conventions.

## What enforces it

`bin/hooks/footnote-check`, a `Stop` hook stubbed over
`claude-code-ide-org-write-footnote-check` in the running Emacs. It
scans the *segment* the stop closes — the final block from
`last_assistant_message`, plus every reader-visible block before it in
the same reply, from `transcript_path` — resolves each 8-hex candidate
against the project's `TODO.org` and `DONE.org`, and blocks when one is
a real heading absent from the final block's end matter. It hands back
the lines to append, in canonical form.

**Its lines carry the on-disk keyword, never a `*`** — it tests
whether each id *appears*, not its keyword. Ids an `org_footnotes` call
covered this turn count as present.

**A segment is one reply** (`:ID:` c247d8f3): it starts at the prompt or
where the previous reply ended — a blocked stop, a refusal. Narration
summaries count; tool inputs do not. **An outage owes nothing**: with
Emacs unreachable or slower than 3 s the stop goes through, which is why
the rule is the rule and this hook only a backstop.

Three things about its reading, each of which has been got wrong:

- **The `---` separator is load-bearing.** The end matter is defined as
  everything after the *last* line that is exactly `---`. End matter
  following a mere blank line does not exist as far as the hook is
  concerned, and it blocks demanding entries that are already there.
- **Fenced code blocks are not prose.** An id inside ``` or `~~~` is a
  transcript — tool output, a file excerpt, a rendered checklist — not a
  citation, and is dropped before the scan.
- **It reports a strict subset.** The hook names what it found missing
  in that segment; it is a backstop for the rule, not the rule itself.

An id that resolves to no heading in the project's org files is not a
citation and is ignored, so a repo with no tracked org files never sees
this hook fire.
