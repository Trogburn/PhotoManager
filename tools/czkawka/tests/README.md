# QNAP lab test harness

`qnap-lab-test-harness.ps1` is an opt-in validation boundary for testing
against a disposable QNAP lab share. It never uses administrator credentials,
never enables Czkawka deletion options, and never runs a network test by
default.

Network and golden-corpus modes have two mandatory gates:

```powershell
$env:QNAP_LAB_TESTS = '1'
$env:QNAP_LAB_ROOT = '\\NAS\DisposableLabShare'
```

Copy `qnap-lab.local.json.example` to gitignored `qnap-lab.local.json` and set
`allowedLabRoot` to that same disposable UNC (or set `QNAP_LAB_ALLOWED_ROOT`).
Run `apply-local-env.ps1` once so `QNAP_LAB_TESTS`, `QNAP_LAB_ROOT`, and
`QNAP_LAB_ALLOWED_ROOT` persist for your Windows user.
`QNAP_LAB_ROOT` must match the allowlist exactly when one is present. Drive
roots, parent paths, and production-like paths are rejected. Network mode
creates one new GUID-named child beneath that root, and every fixture,
quarantine, verification artifact, and transaction is confined to that child.

## Safe local validation

This is the default and does not contact the QNAP:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\czkawka\tests\qnap-lab-test-harness.ps1
```

No environment variables are needed for local mode because it cannot access a
network share or production media.

## Explicit network validation

Only run this against a disposable allowlisted lab share. This is the exact
opt-in command; do not run it unless the share is available and disposable:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\czkawka\tests\qnap-lab-test-harness.ps1 -Mode Network
```

Network mode creates two deterministic identical, valid JPEG fixtures under
`<GUID>\Input`, then runs scan, parse, and classify. It generates deterministic
keep decisions, confirms an unchanged-file/path safety gate in the harness,
performs a remediation dry-run, applies quarantine, runs
`verify-remediation.ps1`, undoes the transaction, and checks that every source
file is restored with the original SHA-256 integrity. Finally it removes only
that GUID child (unless `-KeepArtifacts` is supplied). It does not accept,
prompt for, or load credentials, and never passes Czkawka deletion flags.
Configure access through ordinary Windows share permissions before starting
the test.

## Explicit golden corpus validation

Golden corpus validation is separately gated and requires all three input
artifacts. The corpus path must be a child of the exact lab root:

```powershell
$env:QNAP_LAB_GOLDEN = '1'
$env:QNAP_LAB_GOLDEN_PATH = '\\NAS\DisposableLabShare\golden-v1'
$env:QNAP_LAB_GOLDEN_MANIFEST = 'C:\lab\manifest.json'
$env:QNAP_LAB_GOLDEN_CLASSIFIED = 'C:\lab\classified.json'
$env:QNAP_LAB_GOLDEN_DATES = 'C:\lab\dates.json'

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\czkawka\tests\qnap-lab-test-harness.ps1 -Mode GoldenCorpus
```

Do not put production media, secrets, or administrator credentials in the
golden corpus. The harness reports whether network or golden validation was
attempted and records `credentialsUsed = false`.
