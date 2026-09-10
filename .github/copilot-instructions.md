# Repository Agent Instructions

These instructions apply to all agents working in this repository.

## Source Documents

- [PLAN.md](../PLAN.md) is the product and safety plan. Update it when scope, sequencing, architecture, or safety decisions change.
- [WORK_BREAKDOWN.md](../WORK_BREAKDOWN.md) is the execution tracker. Update it as work is completed.
- [README.md](../README.md) is the user-facing operating documentation. Keep it accurate and current as behavior, commands, configuration, and prerequisites change.

## Mandatory Documentation Updates

Every completed work unit must update the documentation in the same change when applicable:

1. Update `WORK_BREAKDOWN.md`:
   - Change the relevant phase status and percentage.
   - Check off completed deliverables.
   - Record validation performed.
   - Add a dated entry to that phase's agent update log.
   - Recalculate the overall percentage using the documented rule.
   - Record blockers explicitly instead of implying progress.
2. Update `README.md` whenever a user-visible command, setup step, configuration option, workflow, safety rule, prerequisite, or output changes.
3. Update `PLAN.md` when implementation reveals a changed assumption, a shifted phase, a new tradeoff, a removed requirement, or a decision that differs from the original plan.
4. Keep these three documents consistent. Do not mark a work breakdown item complete if the implementation or its acceptance checks are incomplete.

If a task changes only internal code and has no effect on plan, workflow, or user-facing behavior, still update `WORK_BREAKDOWN.md` with the completed work and validation. Do not add meaningless README or PLAN churn.

## Execution Discipline

- Work on one phase from `WORK_BREAKDOWN.md` at a time.
- Read `PLAN.md`, `WORK_BREAKDOWN.md`, and the relevant README sections before editing.
- Preserve unrelated user changes. Never reset or discard work you did not create.
- Before the first edit, identify the controlling code path, one falsifiable local hypothesis, one cheap check that could disprove it, and the smallest testable change.
- After the first substantive edit, run the narrowest available validation before broadening the work.
- Finish with executable validation whenever the environment provides it.
- Keep phase scope narrow. Do not begin a later phase because it is convenient; record dependencies and blockers instead.
- If an acceptance check cannot run, record why in `WORK_BREAKDOWN.md` and leave the item incomplete.

## Safety Requirements

- Czkawka is used as an unchanged, read-only detection tool. Do not copy or fork its scanning implementation unless the plan explicitly changes.
- Never add or enable Czkawka deletion flags.
- Detection and metadata repair must be dry-run first.
- Never automatically delete, quarantine, rename, or change timestamps based only on a score.
- Quarantine requires explicit human approval, stale-file revalidation, an append-only transaction log, and undo support.
- Timestamp repair must preserve original values and evidence in an audit/undo manifest. Reject ambiguous or conflicting date evidence instead of guessing.
- Treat reference/protected paths as non-removable.
- Prefer local reports and logs; preserve raw upstream scan artifacts.
- Keep network-share operations conservative and handle inaccessible or changed files without destructive fallback behavior.

## Implementation Preferences

- Prefer PowerShell and built-in Windows/.NET capabilities to minimize maintenance.
- Avoid adding a database, web server, or framework unless a documented acceptance check shows it is necessary.
- Keep Czkawka versioned and checksum-pinned; do not depend on `master` for production scans.
- Normalize unstable Czkawka JSON at the boundary and preserve the original JSON.
- Make confidence classifications explainable by showing the evidence behind each group and recommendation.
- Keep runtime reports, caches, local configuration, and secrets out of source control.
- Use ASCII by default when creating files.

## Completion Checklist

Before reporting work complete:

- [ ] Relevant implementation is complete and focused.
- [ ] Narrow validation passed, or the limitation is recorded.
- [ ] `WORK_BREAKDOWN.md` status, percentage, checklist, validation, and dated log are updated.
- [ ] `README.md` reflects all changed user-facing behavior.
- [ ] `PLAN.md` reflects any changed scope, assumptions, sequencing, or decisions.
- [ ] No unrelated files or user changes were reverted.