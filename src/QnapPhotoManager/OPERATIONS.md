# QnapPhotoManager operations

QnapPhotoManager is a Windows desktop shell for a review-first photo workflow. It
does not require a live QNAP share to build, test, or inspect local artifacts.
The current WPF application owns configuration, date-review boundaries, artifact
integrity, and workflow state; the PowerShell/Czkawka adapters perform the
actual scan and remediation work.

## Install and upgrade

Requirements:

- Windows 10/11 x64.
- .NET 10 Desktop Runtime, or the SDK when building from source.
- Read access to the QNAP share for scans and write access to a local artifact
  directory.
- PowerShell 7 (`pwsh`) or Windows PowerShell for the date-repair adapter.

Build and publish from the repository root:

```powershell
dotnet build .\src\QnapPhotoManager\QnapPhotoManager.csproj
dotnet publish .\src\QnapPhotoManager\QnapPhotoManager.csproj `
  --configuration Release --runtime win-x64 --self-contained false `
  --output "$env:LOCALAPPDATA\QnapPhotoManager"
```

Run `QnapPhotoManager.exe` from that published directory. Keep the directory
under the user's profile (rather than `Program Files`) because the default
relative `artifacts` directory is next to the application and must be writable.
For a new version, publish to a new versioned directory, verify the build, then
launch that directory. Do not replace a running executable.

The application does not silently install, download, delete, move, or rename
media. Keep the existing `tools\czkawka` installation and its pinned checksum
under source control; update it using the repository's documented installer
procedure, not by copying an arbitrary executable into the publish directory.

## Safe operation

1. Confirm the QNAP share is reachable and use a UNC scan root such as
   `\\server\photos`. Do not use a mapped drive letter for production
   automation.
2. Set an artifact root on a local, user-writable disk. Artifacts are evidence
   and should not be placed inside the source photo tree.
3. Run a read-only scan and inspect the generated raw, normalized, classified,
   review, and date evidence artifacts.
4. Review one group or date proposal at a time. Protected and excluded paths
   remain protected by the PowerShell workflow; advisory keep recommendations
   are not approvals.
5. Use a dry run before remediation. Confirm the frozen artifact snapshot only
   after reviewing it. Remediation is quarantine-only, never direct deletion.
6. Keep the transaction and undo manifests with the session artifacts. Do not
   edit them by hand.

`PathPolicy` rejects non-UNC production scan roots and prevents artifact paths
from escaping the configured artifact directory. `AtomicArtifactStore` writes
to a temporary file and renames it into place, refuses to overwrite an existing
artifact, and records a SHA-256 payload digest. Reads reject a modified payload.
These guarantees protect workflow evidence; they do not make the QNAP share
immutable and do not replace backups.

## Recovery

If a scan, review, or adapter fails:

- Leave the source media untouched and retain the session directory plus
  diagnostics.
- Return to the last valid workflow state rather than deleting partial files.
- If the application reports an artifact integrity failure, stop and preserve
  the artifact for investigation. Do not remove its digest or edit its JSON.
- If remediation reports a stale file, permission error, or hash mismatch,
  leave that source file in place and review the reported path manually.
- Restore quarantined files only through the guarded undo command in
  `tools\czkawka\remediate.ps1`. Undo refuses to overwrite a newer destination.
- Restore timestamp changes only through the date undo manifest. CreationTime is
  the default date policy; LastWriteTime is preserved unless explicitly
  selected.

Maintain an independent backup of the QNAP photo tree. Quarantine and undo are
recovery mechanisms, not backups. Before deleting quarantine contents, verify
the transaction manifest, the restored files, and at least one representative
sample in the normal photo application.

## Scope limitations

The WPF shell is intentionally incremental. It currently provides the session
and review boundaries; the complete scan, classification, date-repair, and
quarantine behavior remains in the repository's PowerShell adapters. A successful
WPF build or validation run must not be interpreted as a successful production
scan.
