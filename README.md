# QnapServerManagement
Utilities for managing a Qnap Server that contains mostly Videos and Audio in a Plex server, along with Photo and Video backup.

## Phase 1: Czkawka CLI foundation

This repository now includes a pinned Windows installation and read-only scan workflow for the Czkawka CLI.

### Included files
- `tools/czkawka/install.ps1` - Downloads and verifies a pinned Czkawka CLI release before installing it locally.
- `tools/czkawka/config.json` - Stores the executable path, local report root, UNC scan root, protected/excluded paths, and scan defaults.
- `tools/czkawka/scan.ps1` - Validates the UNC root, runs the exact-duplicate and image scans in read-only mode, and preserves raw JSON plus metadata.
- `tools/czkawka/parse-results.ps1` - Converts supported Czkawka result JSON into a versioned normalized document while retaining the raw input path.
- `tools/czkawka/tests/phase2-smoke.ps1` - Runs a deterministic grouped-result parser smoke test.
- `tools/czkawka/tests/phase2-tests.ps1` - Runs the broader Phase 2 fixture and error-handling tests.
- `tools/czkawka/repair-dates.ps1` - Produces a dry-run date-evidence report and supports explicitly approved timestamp changes with an undo manifest.
- `tools/czkawka/tests/phase3-smoke.ps1` and `tools/czkawka/tests/phase3-tests.ps1` - Validate Phase 3 evidence, dry-run, approval, and undo behavior.
- `tools/czkawka/classify-results.ps1` - Merges overlapping normalized findings into explainable, advisory review groups with confidence tiers and keep suggestions.
- `tools/czkawka/tests/phase4-tests.ps1` - Validates deterministic grouping, confidence tiers, labels, evidence retention, and protected-reference behavior.
- `tools/czkawka/review.ps1` - Native Windows reviewer for one classified group at a time, with previews, persisted decisions, and static HTML export.
- `.gitignore` - Keeps generated reports and local config artifacts out of source control.

### Commands
```powershell
# Install the pinned CLI
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\install.ps1 -Version 12.0.1 -Checksum "<sha256>"

# Run a read-only scan against a UNC root
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\scan.ps1 -ScanRoot "\\server\photos"

# Force re-download and replace an existing install
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\install.ps1 -Version 12.0.1 -Checksum "<sha256>" -Force

# Validate the Phase 2 result normalizer with PowerShell 7
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase2-smoke.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase2-tests.ps1

# Classify normalized findings without changing files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\classify-results.ps1 -InputPath .\reports\czkawka\normalized.json

# Open the native reviewer; Phase 5 records decisions but does not move files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\review.ps1 -InputPath .\reports\czkawka\normalized.classified.json -DateReviewPath .\reports\dates\date-review.json

# Inspect date evidence without changing files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -Path "\\server\photos" -Recurse

# Apply a reviewed report using explicit decisions, then undo if needed
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -ReviewPath .\reports\dates\date-review.json -DecisionPath .\reports\dates\decisions.json -Apply
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -Undo -UndoManifestPath .\reports\dates\date-undo.jsonl
```

### Configuration
The checked-in `tools/czkawka/config.json` uses repository-relative local paths and obvious `YOUR-SERVER`/`YOUR-SHARE` UNC placeholders. Replace those UNC values with the actual share and protected/preferred folders before scanning. The local executable is installed under `tools/czkawka/bin`, and reports are written under `reports/czkawka`.

### Safety notes
- The scan workflow rejects non-UNC roots and missing shares before launching Czkawka.
- Raw scan output and metadata are written under the local reports directory so results remain local and reviewable.
- Exit codes `0` and `11` are treated as successful scan outcomes; other exit codes fail early.
- Cache is retained by default; the `-Fresh` switch maps to Czkawka's `-H` option for a cache bypass when needed.
- The Phase 2 normalizer emits schema version `1`, preserving source scan, group membership, file metadata, reference state, and the raw input artifact path.
- The normalizer retains warning, inaccessible-file, and stale-file evidence for later human review; it does not delete or alter files.
- Date repair is dry-run by default. EXIF evidence takes precedence over filename evidence; folder dates are low-confidence, sidecars are excluded, and invalid, conflicting, or future dates are not applied automatically.
- Timestamp changes require `-Apply`; the default policy changes CreationTime only, records an append-only undo manifest, and supports `-Undo`.
- Saved reports are revalidated for file size and LastWriteTime before changes. Decision files support `skip`, `protect`, `approve`, and `manual` actions; manual decisions must include a `date` value.
- Classification is advisory only. It retains original evidence edges, marks protected/reference items, and never deletes, moves, or changes timestamps.
- No deletion or quarantine logic is enabled in this phase.
