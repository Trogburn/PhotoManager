# Qnap Photo Review Workflow User Guide

This guide is for running the workflow on Windows with minimal PowerShell knowledge. The workflow is deliberately staged:

1. Scan the photo share without changing files.
2. Normalize and classify the scan results.
3. Review groups in the native reviewer.
4. Optionally quarantine only files explicitly requested by the reviewer.
5. Undo quarantine when needed.

The normal one-command workflow stops at the reviewer. It never moves, deletes, renames, or changes timestamps.

## Before First Use

Open PowerShell 7 in the repository folder:

```powershell
Set-Location C:\dev\GitHub\QnapServerManagement
```

Confirm the tools are available:

```powershell
pwsh --version
gh --version
```

`gh` is useful for repository work but is not required to run the photo workflow.

Install the pinned Czkawka CLI once. The checksum is stored in `tools/czkawka/config.json`:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\install.ps1
```

Do not use `-SkipChecksum` for a real installation.

## Configure Your Share

Edit `tools/czkawka/config.json` and replace these placeholders:

- `scan.uncRoot`: the photo share, for example `\\server\photos`
- `scan.protectedPaths`: folders that must never be quarantined
- `scan.excludedPaths`: folders excluded from remediation
- `scan.preferredDirectories`: folders preferred when suggesting a keep

Local defaults are intentionally repository-relative:

- Czkawka binary: `tools/czkawka/bin`
- Scan reports: `reports/czkawka`
- Quarantine: `reports/quarantine`

Do not put passwords or secrets in `config.json`.

## Recommended One-Command Workflow

After installation and configuration, run:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\run-workflow.ps1 -ScanRoot "\\server\photos"
```

This command:

- Runs the exact duplicate scan and similar-image scan.
- Preserves raw scan output and metadata locally.
- Normalizes both result files.
- Combines and classifies the findings.
- Opens the native reviewer.
- Writes decisions and an HTML report inside the new scan report folder.

To bypass the Czkawka cache:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\run-workflow.ps1 -ScanRoot "\\server\photos" -Fresh
```

To include a date-evidence report in the reviewer:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\run-workflow.ps1 -ScanRoot "\\server\photos" -IncludeDateReview
```

To generate all reports without opening the GUI:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\run-workflow.ps1 -ScanRoot "\\server\photos" -ExportOnly
```

The command prints the report paths. A typical report folder contains:

```text
raw\dup.json
raw\image.json
metadata\dup.metadata.json
metadata\image.metadata.json
normalized\dup.normalized.json
normalized\image.normalized.json
normalized\combined.normalized.json
classified.json
decisions.json
review.html
review.json
```

## Reviewer Actions

The reviewer shows one group at a time.

- **Previous / Next**: move between review groups. Endpoint buttons disable at the first and last group.
- **Keep suggestion**: records the classifier's suggested keep and highlights it.
- **Choose selected keep**: records the currently selected image as the keep. Click a preview card or use the item list first.
- **Skip / defer**: records a decision for only the current group. It does not change files.
- **Protect selected**: toggles protection for the selected item and persists the state.
- **Queue quarantine**: requests quarantine for the group's non-kept items after confirmation. It does not move files in Phase 5.
- **Queue selected quarantine**: requests quarantine for only the selected item after confirmation.
- **Open file / Open folder**: opens the selected item in Windows Explorer.

Unavailable previews remain selectable and are clearly labeled. The native details show the confidence explanation, complete evidence, filename, dimensions, size, modified time, proposed date, access state, and suggested keep. The HTML report has a search box for paths, filenames, evidence, dates, and access states; `review.json` contains equivalent searchable fields for archival or scripted filtering. Both exports are read-only; filesystem actions remain in PowerShell.

## Quarantine: Preview First

After making reviewer decisions, run remediation without `-Apply` first:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\remediate.ps1 `
  -InputPath .\reports\czkawka\scan-YYYYMMDD-HHMMSS\classified.json `
  -DecisionPath .\reports\czkawka\scan-YYYYMMDD-HHMMSS\decisions.json `
  -QuarantineRoot .\reports\quarantine
```

Replace `scan-YYYYMMDD-HHMMSS` with the actual report folder printed by the workflow. Dry-run output must be reviewed before applying anything.

## Apply Quarantine

Only after reviewing the dry-run summary, run the same command with `-Apply`:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\remediate.ps1 `
  -InputPath .\reports\czkawka\scan-YYYYMMDD-HHMMSS\classified.json `
  -DecisionPath .\reports\czkawka\scan-YYYYMMDD-HHMMSS\decisions.json `
  -QuarantineRoot .\reports\quarantine `
  -TransactionManifestPath .\reports\quarantine\transactions.jsonl `
  -Apply
```

Remediation will refuse or skip files that are missing, changed, protected, excluded, or otherwise stale. It never uses Czkawka deletion flags.

## Undo Quarantine

Undo validates every moved quarantine item before restoring it. It refuses to overwrite a source file that already exists or restore a changed quarantine item:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\remediate.ps1 `
  -DecisionPath .\reports\review\decisions.json `
  -TransactionManifestPath .\reports\quarantine\transactions.jsonl `
  -Undo
```

Use the same transaction manifest created by the apply command.

## Date Review

Date repair is separate and dry-run by default:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 `
  -Path "\\server\photos" `
  -Recurse `
  -OutputPath .\reports\dates\date-review.json
```

Review the report before applying approved decisions. The default policy changes CreationTime only and preserves LastWriteTime:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 `
  -ReviewPath .\reports\dates\date-review.json `
  -DecisionPath .\reports\dates\decisions.json `
  -Apply
```

Undo date changes with:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\repair-dates.ps1 `
  -Undo `
  -UndoManifestPath .\reports\dates\date-undo.jsonl
```

## Safety Rules

- Run the normal workflow before remediation.
- Review the dry-run output before using `-Apply`.
- Never use Czkawka deletion options.
- Keep protected and reference paths configured.
- Keep transaction manifests and undo files.
- Do not run remediation against a report after the source files have changed; rescan and review again.
- Test quarantine on a small set before using it on a large share.

## Troubleshooting

**The scan says the executable is missing**

Run the install command and verify `tools\czkawka\bin\czkawka_cli.exe` exists.

**The scan rejects the root**

Use a UNC path such as `\\server\photos` for the photo share. Missing shares fail before Czkawka starts. Local folders are accepted only when you pass `-AllowLocalRoot`, which is intended for test fixtures.

**The reviewer does not open**

Run the command with `-ExportOnly` to verify the classified input and both archive formats. Use PowerShell 7, not Windows PowerShell 5.1, for the complete workflow.

**A file was refused during remediation**

Read the result reason. Common causes are stale size/mtime, a protected path, an excluded path, or a missing source. Rescan rather than bypassing the check.

**Undo refuses to restore**

Do not overwrite or modify the quarantine file or recreate the source path manually. Resolve the reported collision or change, then rerun undo.

## Validation Commands

Run the local automated checks from the repository root:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase1-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase2-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase2-smoke.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase3-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase3-smoke.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase4-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase5-tests.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\czkawka\tests\phase6-tests.ps1
```
