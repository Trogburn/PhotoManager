function Test-PackagedZipEntries {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [Parameter(Mandatory)]
        [string[]]$Required
    )

    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw "Zip was not found: $ZipPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $names = @(
            $zip.Entries |
                ForEach-Object { $_.FullName.Replace('\', '/') }
        )
        foreach ($relative in $Required) {
            $want = $relative.Replace('\', '/')
            if ($names -notcontains $want) {
                throw "Zip is missing '$want'. Entries: $($names -join ', ')"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}
