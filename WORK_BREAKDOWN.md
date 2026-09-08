# Windows Photo Review Workflow Work Breakdown

This document is the execution handoff for Copilot agents. Complete one phase at a time, keep changes small, validate each phase before starting the next, and update the status table whenever work is completed.

The source of truth for product direction and safety decisions is [PLAN.md](PLAN.md).

## Overall Status

**Overall implementation: 29%**

| Phase | Scope | Status | Progress | Depends On |
|---|---|---:|---:|---|
| 1 | Czkawka CLI foundation | Complete | 100% | None |
| 2 | Stable local result model | Complete | 100% | Phase 1 |
| 3 | Metadata date repair utility | Not started | 0% | Phase 2 |
| 4 | Confidence and human grouping | Not started | 0% | Phases 2-3 |
| 5 | Native Windows review experience | Not started | 0% | Phase 4 |
| 6 | Safe remediation and undo | Not started | 0% | Phase 5 |
| 7 | Operational polish | Not started | 0% | Phase 6 |

### Status Definitions

- **Not started**: no implementation work has been accepted.
- **In progress**: implementation is underway, but acceptance criteria are incomplete.
- **Blocked**: work cannot continue until a named dependency or user decision is resolved.
- **Complete**: implementation and phase acceptance checks pass.

### Percentage Rules

- Phase percentages are based only on completed deliverables listed in that phase.
- A phase is not complete because files exist; its validation and acceptance checks must pass.
- Overall progress is the average of the seven phase percentages, rounded to the nearest whole number, unless a phase is explicitly blocked by an external dependency.
- When updating status, record the date, changed files, validation performed, and any blocker in the phase section.
- Do not mark future phases complete based on design work alone.

## Agent Operating Rules

1. Read [PLAN.md](PLAN.md) and this file before editing.
2. Work only on the current phase unless a small dependency fix is required.
3. Inspect existing files and preserve user changes; never reset or overwrite unrelated work.
4. Before the first edit, identify one local hypothesis, one cheap check that could disprove it, and the smallest testable change.
5. After the first substantive edit, run the narrowest available validation before reading broadly or starting another edit slice.
6. Keep runtime operations read-only until the remediation phase is explicitly approved.
7. Never enable Czkawka deletion flags. The project must quarantine files through its own verified workflow.
8. Preserve raw scan artifacts, diagnostics, audit manifests, and undo information.
9. Prefer built-in Windows PowerShell/.NET capabilities and avoid unnecessary dependencies or services.
10. Update this document after each accepted deliverable, not only at the end of a phase.

## Phase 1: Czkawka CLI Foundation

**Target:** Run repeatable, read-only exact-duplicate and similar-image scans from Windows against a UNC path.

**Deliverables**

- [x] Add `tools/czkawka/install.ps1` with a pinned release, checksum verification, and an explicit update path.
- [x] Add `tools/czkawka/config.json` for executable path, UNC scan root, local report root, scan thresholds, protected paths, excluded paths, and preferred directories.
- [x] Add `tools/czkawka/scan.ps1`.
- [x] Validate the UNC path before launching Czkawka.
- [x] Run `dup -s hash` and `image` separately in read-only mode.
- [x] Capture raw JSON, stderr/diagnostics, command metadata, version, timestamps, and exit status.
- [x] Treat exit codes `0` and `11` as successful scan outcomes; fail on process, argument, or path errors.
- [x] Support `-Fresh` by passing `-H`; retain cache by default.
- [x] Keep reports local by default and exclude runtime reports from source control.

**Acceptance checks**

- `czkawka_cli.exe --version` succeeds after installation.
- A local fixture produces both raw scan artifacts.
- A UNC scan succeeds without changing files.
- A finding result does not appear as a process failure.
- A missing share, invalid argument, or missing executable fails clearly.
- PowerShell syntax checks pass.

**Status:** Complete, 100%

**Agent update log:**

- 2026-09-08: Added the pinned install script, local config, read-only scan wrapper, and local artifact storage. Validated script syntax with a PowerShell parser check; both scripts parsed successfully.
- 2026-09-08: Replaced machine-specific-looking defaults with repository-relative installer/report paths and explicit `YOUR-SERVER`/`YOUR-SHARE` UNC placeholders. Configuration JSON, PowerShell syntax, and Phase 2 regression tests passed.

## Phase 2: Stable Local Result Model

**Target:** Convert Czkawka's version-dependent JSON into one documented local schema while retaining upstream artifacts.

**Deliverables**

- [x] Add `tools/czkawka/parse-results.ps1` or a small parser module.
- [x] Parse `dup` HASH output, including empty and reference-directory variants.
- [x] Parse grouped `image` output, including reference-directory variants.
- [x] Emit a versioned normalized result document.
- [x] Preserve source scan, Czkawka version, raw artifact paths, scan root, and scan timestamp.
- [x] Capture path, size, modified time, hash, width, height, perceptual difference, reference state, and group membership.
- [x] Add fixtures for valid results, empty results, malformed JSON, warnings, inaccessible files, and stale files.
- [x] Add deterministic parser tests.

**Acceptance checks**

- Every supported fixture normalizes deterministically.
- Malformed or unsupported shapes fail with an actionable message.
- Raw JSON remains available after normalization.
- UNC paths round-trip without accidental normalization.
- Schema version is recorded in every normalized result.

**Status:** Complete, 100%

**Agent update log:**

- 2026-09-08: Completed deterministic normalization for grouped and flat results, duplicate/image reference variants, empty results, warnings, inaccessible files, stale entries, metadata propagation, and actionable shape errors. PowerShell 7.6.5 smoke, fixture, and syntax checks passed.

## Phase 3: Metadata Date Repair Utility

**Target:** Safely repair Windows album sorting dates using real media evidence, without guessing.

**Deliverables**

- [ ] Add `tools/czkawka/repair-dates.ps1`.
- [ ] Inspect EXIF `DateTimeOriginal` and digitized date first.
- [ ] Add conservative filename parsing for `YYYY-MM-DD`, `YYYYMMDD`, and timestamp-style names.
- [ ] Keep video/container metadata and sidecars out of the first implementation unless a tested built-in or approved dependency is available.
- [ ] Treat folder names as lower-confidence evidence only.
- [ ] Treat current filesystem CreationTime and LastWriteTime as transfer/copy evidence, not capture time.
- [ ] Normalize timezone handling and reject conflicts, ambiguous dates, impossible dates, and unacceptable future dates.
- [ ] Produce a dry-run report with current timestamps, proposed date, source evidence, confidence, and parsed token.
- [ ] Add actions for accept one, accept high-confidence batch, skip, protect, and manual override.
- [ ] Revalidate path, size, and timestamp before applying changes.
- [ ] Default to changing CreationTime only; preserve LastWriteTime unless an explicit policy is selected.
- [ ] Write an append-only audit and undo manifest.
- [ ] Do not rewrite EXIF or rename files in the first version.

**Acceptance checks**

- Valid EXIF outranks filename and filesystem timestamps.
- Conflicting evidence is reported and not changed automatically.
- Ambiguous dates are skipped.
- Dry-run changes no files.
- Approved changes update the configured Windows timestamp policy.
- Stale or changed files are refused.
- Undo restores original timestamps.
- Fixture coverage includes timezone offsets, camera names, copied files, sidecars, inaccessible files, and impossible dates.

**Status:** Not started, 0%

**Agent update log:**

- No work recorded.

## Phase 4: Confidence and Human-Oriented Grouping

**Target:** Turn exact and visual matches into explainable review groups with useful keep recommendations.

**Deliverables**

- [ ] Add `tools/czkawka/classify-results.ps1`.
- [ ] Merge overlapping exact/image findings while retaining original evidence edges.
- [ ] Implement visible tiers: Very high, High, Medium, and Review carefully.
- [ ] Add explainable labels: exact duplicate, resized copy, likely thumbnail, downloaded copy, filename variant, and cross-folder match.
- [ ] Show dimensions, size ratios, perceptual difference, hashes, paths, and evidence sources.
- [ ] Add configurable keep recommendations based on preferred folders, dimensions, file size, filename quality, and protected/reference status.
- [ ] Ensure recommendations are advisory and never perform actions.
- [ ] Add deterministic classifier tests.

**Acceptance checks**

- Same-content files are always in the highest-confidence tier.
- Resized and thumbnail candidates are distinguishable from exact duplicates.
- Transitive groups retain the reason each item was included.
- Protected/reference paths cannot be recommended for removal.
- Classifier output is stable for the same normalized input.

**Status:** Not started, 0%

**Agent update log:**

- No work recorded.

## Phase 5: Native Windows Review Experience

**Target:** Let a human inspect and decide on one group at a time with minimal friction.

**Deliverables**

- [ ] Add `tools/czkawka/review.ps1` using a small native PowerShell/.NET GUI.
- [ ] Display side-by-side image previews with graceful handling for unavailable images.
- [ ] Show confidence tier, explanation, evidence, path, filename, dimensions, size, modified time, proposed date, and suggested keep.
- [ ] Add quick actions: keep suggestion, choose another keep, quarantine selected, skip/defer, open file, open folder, and protect.
- [ ] Include date-repair proposals in the same review workflow or provide a clear linked review screen.
- [ ] Require explicit confirmation for every quarantine or timestamp change.
- [ ] Generate static HTML/JSON reports for search and archival, while keeping filesystem actions native.
- [ ] Track decisions so deferred groups return to the reviewer.

**Acceptance checks**

- A human can identify exact duplicates without reading raw JSON.
- A human can distinguish original, resized copy, and thumbnail candidates.
- Every proposed action shows its reason before confirmation.
- Skip, protect, and defer decisions persist.
- UNC paths can be opened from the interface.
- Unavailable or inaccessible files are clearly marked.

**Status:** Not started, 0%

**Agent update log:**

- No work recorded.

## Phase 6: Safe Remediation and Undo

**Target:** Move only explicitly approved files to quarantine with stale-file protection and reliable recovery.

**Deliverables**

- [ ] Add `tools/czkawka/remediate.ps1`.
- [ ] Use quarantine rather than direct deletion.
- [ ] Make quarantine location configurable; test a dedicated folder on the same share first.
- [ ] Preserve relative source paths and use collision-safe destination names.
- [ ] Revalidate existence, size, modified time, and hash where available before moving.
- [ ] Refuse stale or changed entries.
- [ ] Write an append-only transaction manifest.
- [ ] Add an undo command that will not overwrite newer files.
- [ ] Add dry-run mode, protected paths, excluded paths, and summaries of moved/skipped/failed files.
- [ ] Keep Czkawka deletion flags out of the workflow.

**Acceptance checks**

- Dry-run moves nothing.
- An approved file is quarantined exactly once and logged.
- Stale files are refused.
- Destination collisions are handled safely.
- Permission failures leave source files untouched and are logged.
- Protected files cannot be moved.
- Undo restores a quarantined file without overwriting a newer destination.

**Status:** Not started, 0%

**Agent update log:**

- No work recorded.

## Phase 7: Operational Polish

**Target:** Make the workflow maintainable for recurring manual use and optional scheduled scanning.

**Deliverables**

- [ ] Update `README.md` with installation, configuration, UNC permissions, scan/review/remediation, supported formats, cache behavior, and recovery.
- [ ] Add version/checksum update guidance without silent executable replacement.
- [ ] Document third-party binary/license attribution.
- [ ] Add optional Task Scheduler guidance only for scan/report jobs.
- [ ] Ensure scheduled jobs never quarantine automatically.
- [ ] Add final PowerShell syntax, parser, classifier, date-repair, review, and remediation checks.
- [ ] Add or update `.gitignore` for runtime reports, caches, and local configuration secrets.

**Acceptance checks**

- A new Windows user can follow the README from install through review.
- A scheduled scan produces a report without changing media.
- Recovery and undo instructions are accurate.
- Runtime artifacts are not accidentally committed.
- All automated checks pass.

**Status:** Not started, 0%

**Agent update log:**

- No work recorded.

## Future Decisions

1. **Quarantine location:** same share preserves local disk space and avoids copying large files; local quarantine may simplify recovery. Keep it configurable and test a dedicated folder on the same share first.
2. **Thumbnail handling:** use both protected path rules and classifier labels, with protected paths taking precedence.
3. **Czkawka version:** pin a tested release and checksum; do not track `master` for production scans.
4. **Album timestamp policy:** CreationTime only by default. LastWriteTime describes file content/transfer state and should not be rewritten silently.
5. **Date metadata scope:** start with image EXIF and conservative filename parsing. Add video/container and sidecar metadata only after the image workflow is proven.
6. **Review UI:** use native Windows controls for filesystem actions; use static HTML/JSON only for portable browsing and archival.

## Change Log

- 2026-09-08: Created the execution breakdown. All phases are not started; overall implementation is 0%.
- 2026-09-08: Moved the canonical agent instructions to `.github/copilot-instructions.md`; phase percentages remain unchanged.
