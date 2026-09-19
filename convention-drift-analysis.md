# Convention Drift in claude-code-ide-org: Analysis and Recommendations

**Audience:** the agent developing, testing, and maintaining this plugin and its governing rules/conventions (the machinery promoted into consumer repos alongside it).

**Prepared from:** a conversation between the project owner and Claude about a recurring failure pattern, plus one live transcript excerpt that reproduces it in miniature.

---

## 1. The reported problem

After many weeks of layering CLAUDE.md content, promoted rules, and skills, the owner reports the agent routinely violates conventions it has been told about — sometimes for the third time in a day — and then acknowledges the miss when reminded. The standing question: is this an MCP/tool-discoverability problem, a wording-strength problem, or something structural, and would subagents or file reorganization help?

## 2. Diagnosis

**This is not a wording problem.** The governing documents already use maximal emphasis — bold `**Rule**:` headers, historical incident postmortems, explicit counter-rules against backsliding. There is no register left to escalate to. The transcript in §3 confirms this directly: the agent could state the rule correctly and completely the moment it was challenged. The knowledge was present in context. It simply wasn't applied at the point of action.

**This is a standing-context volume problem.** Every rule added to CLAUDE.md, or to an always-loaded promoted rule file, is re-injected into every session regardless of relevance, and competes for attention against the actual work (file contents, tool output, code) on every single turn. The project's own CLAUDE.md already documents this dynamic explicitly — including the observation that an *accurate* file is more dangerous than an inaccurate one, because it makes the habit of trusting recall over verification harder to notice. The rule count has grown monotonically (new rule → exception → counter-rule → meta-rule against re-tightening) with no corresponding compression or retirement pass. At sufficient density, no amount of emphasis reliably wins a given turn's attention.

**The gap is specifically between "can recite" and "does, unprompted."** This is the most important distinguishing fact from the live example: the agent did not need to be *taught* the duplicate-check rule when asked — it needed to be *made* to run it before offering to act. That is an execution-ordering failure, not a knowledge failure, and prose reinforcement cannot fix an execution-ordering failure no matter how it's phrased, because the failure mode is exactly "the rule was in context and still wasn't consulted at the decision point."

## 3. Case study (live transcript, lightly annotated)

```
Agent: ...org_capture silently discarding an unrecognized argument is how a
       filed heading becomes a title with nothing under it, and the only
       reason I caught it was a diff that was 6 lines when it should have
       been 30. I haven't filed it; say the word and I will.

User:  the problem with the unrecognized argument is already reported, I
       believe. did you check?

Agent: No, I didn't — I offered to file it without searching, which is the
       duplicate check I'm supposed to do before proposing a capture.
       Checking now.

       [searches, greps, runs a shell command]

       You're right — bbf9fb77, filed 2026-09-08, and it already documents
       two prior occurrences. Mine is the third, and it adds something the
       first two didn't have. Recording it: ...
```

Two things worth noting beyond the headline miss:

- The agent's self-correction is accurate and complete — it names the exact rule, in the exact words a rules file would use. This rules out "didn't understand the rule" as the explanation.
- The thing that actually closed the gap was the user manually playing the role of a duplicate-check gate, by asking a pointed question. That is a real instance of the "checker" pattern discussed below, just done by a human instead of a system.

## 4. Recommendations

### 4.1 Move mechanically-checkable rules out of prose and into enforcement

Anything of the shape "before doing X, always do Y first" — where Y is a fixed, cheap, deterministic step (a search, a query, a lookup) — should not live as a sentence the agent has to recall at the right moment. It should be structural: a tool contract, a hook, or a wrapper that makes the omitted step impossible rather than merely discouraged.

Concretely for this project: a `propose_capture`-shaped step (or equivalent) that **requires evidence a prior search ran** — e.g., it takes the search/query result as an argument, or a pre-tool-use hook blocks the "offer to file" action until a query against existing headings has executed in that turn. If the tool literally cannot be reached without the check having happened, the failure mode in §3 becomes unreachable rather than merely rare.

This generalizes: any rule in the promoted machinery files that amounts to "always do this specific mechanical thing before/after that specific mechanical trigger" (queue-append on state change, `:PLAN:` link on `ExitPlanMode`, etc.) is a hook candidate. Reserve prose for genuine judgment calls (is this a slice or maintenance? is this heading a twin?) that can't be reduced to a fixed procedure.

### 4.2 Reduce always-loaded standing context

CLAUDE.md and several promoted rule files load unconditionally regardless of what the session is actually doing. Push harder on path-scoping and on-demand loading (as already done for `org-conventions.md`) so a session not touching org state isn't carrying that rule surface on every turn. Every unconditionally-loaded rule is a fixed tax on the attention available for whatever rule actually matters this turn.

### 4.3 Separate rule from rationale

The historical incident narratives, retired-rule postmortems, and "why we decided X" essays are valuable — but as journal content (DONE.org, changelog), not as standing context sitting alongside the rule itself. Where CLAUDE.md currently interleaves a one-line rule with a paragraph of justification, split them: keep the rule terse and checklist-shaped in the always-loaded surface, and let the reasoning live one hop away for whoever wants it.

### 4.4 Use dedicated, narrow "checker" passes for judgment-level curation

For the class of task that genuinely needs LLM judgment rather than a mechanical check — deduplicating newly noticed ideas against existing headings, assessing slice/story fit, spotting undeclared dependencies, nominating NEXT candidates, and especially detecting **twins** (the failure mode the project's own conventions already say "is caught by review, never by the composer") — a small, single-purpose checker invoked with a narrow, saturated context (the relevant convention section plus the specific query result, not the full rule stack) will outperform the same judgment made mid-task by an agent juggling everything else.

Two constraints on these checkers, to stay consistent with the project's existing "queue, don't apply" discipline:
- **They propose; they don't restructure.** Detection/nomination (duplicate flagging, dependency flagging, NEXT nomination) is safe to automate directly into the queue. Composition-level decisions (declaring a new slice out of loose tasks) should surface as a suggestion for human composition, not an automatic action — this mirrors the project's existing rule that a heading is never simply given children, it *divides*, by deliberate act.
- **Run them as triggered/periodic passes, not as more instructions inside the main loop.** The fix for context competition isn't adding another subagent's worth of instructions to the same crowded session — it's moving the judgment call out to a pass with its own small, focused context.

### 4.5 Reduce outer-loop chatter by changing the default action, not by adding a delegation step

The original question was whether the orchestrator would know to ask a checker "is this already captured?" instead of asking the user "want me to file that?" The honest answer: it won't, by default — "delegate before asking the user" is itself just another rule competing for recall, and it doesn't emerge from a checker existing.

The more robust fix is to remove the question rather than reroute it: given that captures already land in a human-reviewed queue, there is little reason for the orchestrator to ask permission to *propose* one. Run the (cheap, mechanical) duplicate check automatically, then capture directly and note it in the running summary. Reserve the existing review step as the actual approval gate. This eliminates a whole class of "should I ask the user or a subagent" chatter rather than replacing it with a different chatter path.

## 5. Summary of the core claim

None of the observed misses trace to insufficiently forceful wording, and none are solved by advertising tools better. They trace to (a) more standing rules than any single turn's attention budget can reliably serve, and (b) rules that are mechanically checkable but implemented as prose recall instead of as enforced structure. The fix is compression plus structural enforcement — hooks and tool contracts for the mechanical rules, narrow dedicated checker passes for the judgment-level ones, and fewer always-loaded words overall — not stronger language and not more subagents used as additional workers reading the same pile of instructions.
