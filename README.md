# QnapServerManagement
Utilities for managing a Qnap Server that contains mostly Videos and Audio in a Plex server, along with Photo and Video backup.

For a beginner-focused, copy-paste operating guide, see [USER_GUIDE.md](USER_GUIDE.md). The recommended one-command workflow is `tools/czkawka/run-workflow.ps1`; it scans, normalizes, classifies, and opens the reviewer without moving files.

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
- `tools/czkawka/run-workflow.ps1` - Runs scan, normalization, classification, optional date review, and reviewer launch as one safe workflow.
- `tools/czkawka/remediate.ps1` - Dry-run-first quarantine workflow with stale-file checks, transaction logging, and guarded undo.
- `tools/czkawka/tests/phase6-tests.ps1` - Validates remediation safety against temporary files.
- `.gitignore` - Keeps generated reports and local config artifacts out of source control.

### Commands
```powershell
# Install the pinned CLI using the checksum in tools/czkawka/config.json
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\install.ps1

# Run a read-only scan against a UNC root
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\scan.ps1 -ScanRoot "\\server\photos"

# Run the same scans against a local fixture directory
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\scan.ps1 -ScanRoot .\fixtures\photos -AllowLocalRoot

# Force re-download and replace an existing install
powershell -ExecutionPolicy Bypass -File .\tools\czkawka\install.ps1 -Force

# Validate Phase 1-3 with PowerShell 7
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase1-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase2-smoke.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase2-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase3-smoke.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase3-tests.ps1

# Classify normalized findings without changing files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\classify-results.ps1 -InputPath .\reports\czkawka\normalized.json

# Open the native reviewer; Phase 5 records decisions but does not move files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\review.ps1 -InputPath .\reports\czkawka\normalized.classified.json -DateReviewPath .\reports\dates\date-review.json

# Inspect date evidence without changing files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -Path "\\server\photos" -Recurse

# Apply a reviewed report using explicit decisions, then undo if needed
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -ReviewPath .\reports\dates\date-review.json -DecisionPath .\reports\dates\decisions.json -Apply
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -Path "\\server\photos" -Recurse -Apply -ApproveHighConfidence
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 -Undo -UndoManifestPath .\reports\dates\date-undo.jsonl

# Preview quarantine actions without moving files
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\remediate.ps1 -InputPath .\reports\czkawka\classified.json -DecisionPath .\reports\review\decisions.json -QuarantineRoot .\reports\quarantine

# Apply explicitly requested quarantine actions, then undo if needed
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\remediate.ps1 -InputPath .\reports\czkawka\classified.json -DecisionPath .\reports\review\decisions.json -QuarantineRoot .\reports\quarantine -Apply
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\remediate.ps1 -DecisionPath .\reports\review\decisions.json -TransactionManifestPath .\reports\quarantine\transactions.jsonl -Undo
```

### Configuration
The checked-in `tools/czkawka/config.json` uses repository-relative local paths and obvious `YOUR-SERVER`/`YOUR-SHARE` UNC placeholders. Replace those UNC values with the actual share and protected/preferred folders before scanning. The local executable is installed under `tools/czkawka/bin`, and reports are written under `reports/czkawka`. The Czkawka 12.0.1 Windows CLI URL and SHA256 checksum are pinned in that config; `install.ps1` reads them by default.

### Safety notes
- Production scans should use a UNC root. Local directories are allowed only with `-AllowLocalRoot` for fixture validation. Missing executables, missing shares, and invalid Czkawka arguments fail before files are changed.
- Each scan writes compact JSON under `raw/`, stderr diagnostics under `diagnostics/`, and command metadata (including the actual `czkawka_cli --version`) under `metadata/`.
- Exit codes `0` and `11` are treated as successful scan outcomes; other exit codes fail early. Deletion flags are never passed to Czkawka.
- Cache is retained by default; the `-Fresh` switch maps to Czkawka's `-H` option for a cache bypass when needed.
- The Phase 2 normalizer accepts both the stable local schema and captured Czkawka 12 HASH/image JSON. It emits schema version `1`, preserving source scan, group membership, file metadata, reference state, raw artifact paths, CLI version, scan root, and scan timestamp. `parse-results.ps1 -ScanReportDir` combines `dup` and `image` outputs from one scan folder.
- The normalizer retains warning, inaccessible-file, and stale-file evidence for later human review; it does not delete or alter files.
- Date repair is dry-run by default. EXIF `DateTimeOriginal` outranks digitized date, then filename, then folder names. Sidecars are excluded. Naive timestamps are unspecified local time; explicit offsets convert to UTC. Invalid, ambiguous, conflicting, mixed-timezone, or future dates are not applied automatically.
- Timestamp changes require `-Apply` plus an explicit approve path, decision file, or `-ApproveHighConfidence` for high-confidence EXIF items. The default policy changes CreationTime only, records an append-only undo manifest, and supports `-Undo`.
- Saved reports are revalidated for file size and LastWriteTime before changes. Decision files support `skip`, `protect`, `approve`, and `manual` actions; manual decisions must include a `date` value.
- Classification is advisory only. It merges overlapping findings, retains original evidence edges plus repeated-path metadata/warning/access/stale evidence, marks protected/reference items, and never deletes, moves, or changes timestamps. Protected and preferred directory rules match complete directory boundaries rather than similarly named sibling folders.
- Remediation is quarantine-only and dry-run by default. It revalidates size and modified time, refuses stale/protected/excluded files, uses collision-safe destinations, appends transactions, and never enables Czkawka deletion flags.
