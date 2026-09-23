# Plan Reviewer Prompt Template

Use this template when dispatching a reviewer subagent over a design
written into a heading's `:PLAN:` drawer.

**Purpose:** Verify the plan is complete, consistent, and ready for implementation.

**Dispatch before the write:** over the draft, once the self-review has
run, so its findings are fixed before anything reaches the drawer. A
drawer can only be appended to.

```
Subagent (general-purpose):
  description: "Review a heading's plan"
  prompt: |
    You are a plan reviewer. Verify this plan is complete and ready to implement.

    **Plan to review:** the draft below, not yet written to heading
    [ID_PREFIX]'s :PLAN: drawer. Read the heading's body with org_body,
    id=[ID_PREFIX], for the problem it answers. You propose; you change
    nothing.

    [DRAFT]

    ## What to Check

    | Category | What to Look For |
    |----------|------------------|
    | Completeness | TODOs, placeholders, "TBD", incomplete sections |
    | Consistency | Internal contradictions, conflicting requirements |
    | Clarity | Requirements ambiguous enough to cause someone to build the wrong thing |
    | Scope | Focused enough for one heading, not several independent parts |
    | YAGNI | Unrequested features, over-engineering |

    ## Calibration

    **Only flag issues that would cause real problems during implementation.**
    A missing section, a contradiction, or a requirement so ambiguous it could be
    interpreted two different ways — those are issues. Minor wording improvements,
    stylistic preferences, and "sections less detailed than others" are not.

    Approve unless there are serious gaps that would lead to a flawed build.

    ## Output Format

    ## Plan Review

    **Status:** Approved | Issues Found

    **Issues (if any):**
    - [Section X]: [specific issue] - [why it matters for implementation]

    **Recommendations (advisory, do not block approval):**
    - [suggestions for improvement]
```

**Reviewer returns:** Status, Issues (if any), Recommendations
