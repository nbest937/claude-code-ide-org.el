# `:CATEGORY:` values — this repo's taxonomy

**Always loaded, deliberately — this file carries no `paths:` scope.**
A heading is usually captured with no `.org` file open, so when this
table lived in the path-scoped `org-conventions-local.md` it never
reached the session doing the capturing: ten level-1 headings arrived
uncategorised in the two days after commit `42a3221` moved it there
(`:ID:` b0d55552). Two mechanisms now back the prose: `org_capture`
**requires** `category` for a top-level capture and names the values
the file already uses when it refuses, and `bin/lint-org` errors on a
level-1 heading with no drawer-local `:CATEGORY:`. A child inherits its
parent's and needs none.

## The ten values

Settled 2026-08-28 (`:ID:` 29439196, step 2). Single words, capitalised, so a
value is distinguishable at a glance from a TODO keyword and from a tag:

| value | what belongs here |
|---|---|
| `Queue` | the event queue itself — events, guideposts, spans, attribution |
| `Apply` | the review buffer and the apply pass over that queue |
| `Clock` | clock correctness proper — intervals, CLOCK lines, org-clock state |
| `Skill` | what an agent must follow: CLAUDE.md, the skills, these conventions, keyword semantics |
| `Tools` | the `org_*` MCP surface and its behaviour |
| `Dev` | the repo's own machinery: `bin/`, lint, tests, hooks, packaging, the Doom and shell environment |
| `Meta` | the meta-work datetree and the daily ceremony — the day node, archiving |
| `Slices` | slice machinery: composition, refresh, the blocker and the cookie |
| `Docs` | prose written for a human reader — README, procedures |
| `Upstream` | defects belonging to `claude-code-ide.el`, not to this repo |

**`Tools` versus `Dev` is one test: `Tools` is what Claude calls, `Dev` is
what a developer runs.** They split 26/26 without being forced, which is why
the seam is trusted. Note `Dev` names an *audience* where the others name
subjects — read alone it would swallow the file, and the bound comes entirely
from its sibling.

**Not `Review`, deliberately.** `REVIEW` is also a TODO keyword, so
`:CATEGORY: Review` would render an agenda line as `Review  REVIEW  Some
task` — the one value that defeats the reason these are capitalised. It also
read to its daily reader as naming the ceremony rather than the apply
subsystem. `apply` is the project's own word for it by a wide margin.

How the nine labels that preceded these were split, and the level-1
category tier they replaced, are history and stay path-scoped in
`org-conventions-local.md`.
