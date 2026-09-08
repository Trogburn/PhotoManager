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
```

### Safety notes
- The scan workflow rejects non-UNC roots and missing shares before launching Czkawka.
- Raw scan output and metadata are written under the local reports directory so results remain local and reviewable.
- Exit codes `0` and `11` are treated as successful scan outcomes; other exit codes fail early.
- Cache is retained by default; the `-Fresh` switch maps to Czkawka's `-H` option for a cache bypass when needed.
- The Phase 2 normalizer emits schema version `1`, preserving source scan, group membership, file metadata, reference state, and the raw input artifact path.
- No deletion or quarantine logic is enabled in this phase.
