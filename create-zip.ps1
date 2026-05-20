# Packages AndroidCACert as a Magisk-installable zip (LF line endings)
# REQUIREMENT: Place a static ARM64 openssl binary at bin\openssl before running this script.

$ModuleDir = $PSScriptRoot
$OutputZip = Join-Path (Split-Path $ModuleDir) "AndroidCACert.zip"
$OpenSslBin = Join-Path $ModuleDir "bin\openssl"

if (-not (Test-Path $OpenSslBin)) {
    Write-Error @"
[!] bin\openssl not found.

Download a static Android ARM64 openssl binary and place it at:
  $OpenSslBin

How to get it (choose one):
  A) From an Android device that already has openssl:
       adb pull /system/bin/openssl bin\openssl

  B) Build from source targeting android-arm64 with NDK.

  C) Extract from an openssl static build package for Android ARM64.
"@
    exit 1
}

Write-Host "[+] Found openssl binary: $OpenSslBin"

# Convert CRLF -> LF for shell scripts
$ShellFiles = @(
    "post-fs-data.sh",
    "service.sh",
    "META-INF\com\google\android\update-binary",
    "META-INF\com\google\android\updater-script",
    "module.prop"
)
foreach ($rel in $ShellFiles) {
    $path = Join-Path $ModuleDir $rel
    $content = [System.IO.File]::ReadAllText($path) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "LF: $rel"
}

# Build zip
if (Test-Path $OutputZip) { Remove-Item $OutputZip -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($OutputZip, 'Create')

$entries = @(
    @{ rel = "module.prop" },
    @{ rel = "post-fs-data.sh" },
    @{ rel = "service.sh" },
    @{ rel = "META-INF\com\google\android\updater-script" },
    @{ rel = "META-INF\com\google\android\update-binary" },
    @{ rel = "bin\openssl" }
)

foreach ($e in $entries) {
    $abs   = Join-Path $ModuleDir $e.rel
    $entry = $e.rel -replace '\\', '/'
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $abs, $entry, 'Optimal') | Out-Null
    Write-Host "Added: $entry"
}

$zip.Dispose()
Write-Host "`nCreated: $OutputZip"
