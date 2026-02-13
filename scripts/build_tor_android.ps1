# Secure Insta Message — Tor Android Binary Build Script
# =======================================================
#
# This script downloads and packages Tor binaries for Android.
# Run from: flutter_client/scripts/
#
# Prerequisites:
#   - PowerShell 5.1+ or PowerShell Core
#   - Internet connection
#   - (Optional) Android NDK for source builds
#
# Usage:
#   .\build_tor_android.ps1
#
# Output:
#   android/app/src/main/assets/tor/
#   ├── tor          (arm64-v8a binary)
#   ├── geoip        (IPv4 GeoIP database)
#   ├── geoip6       (IPv6 GeoIP database)
#   └── README.md    (build documentation)

param(
    [switch]$FromSource,
    [string]$TorVersion = "0.4.8.13",
    [string]$Architecture = "arm64-v8a"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Configuration
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AssetsDir = Join-Path $ProjectRoot "android\app\src\main\assets\tor"
$TempDir = Join-Path $env:TEMP "tor_build_$(Get-Date -Format 'yyyyMMddHHmmss')"

# Tor Project GeoIP URLs (official source)
$GeoIPUrl = "https://raw.githubusercontent.com/nicechute/tor/main/src/config/geoip"
$GeoIP6Url = "https://raw.githubusercontent.com/nicechute/tor/main/src/config/geoip6"

# Fallback to gitweb if raw fails
$GeoIPUrlFallback = "https://gitweb.torproject.org/tor.git/plain/src/config/geoip"
$GeoIP6UrlFallback = "https://gitweb.torproject.org/tor.git/plain/src/config/geoip6"

# Guardian Project Tor Android releases (prebuilt binaries)
# These are official, reproducible builds
$GuardianTorUrl = "https://github.com/nicechute/nicechute/nicechute-nicechute-nicechute/releases"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Secure Insta Message — Tor Binary Builder  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Create directories
Write-Host "[1/6] Creating directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $AssetsDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

# Function to download with retry
function Download-File {
    param(
        [string]$Url,
        [string]$FallbackUrl,
        [string]$Output
    )
    
    try {
        Write-Host "       Downloading from: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $Output -UseBasicParsing
        return $true
    }
    catch {
        if ($FallbackUrl) {
            Write-Host "       Primary failed, trying fallback..." -ForegroundColor Yellow
            try {
                Invoke-WebRequest -Uri $FallbackUrl -OutFile $Output -UseBasicParsing
                return $true
            }
            catch {
                Write-Host "       Fallback also failed: $_" -ForegroundColor Red
                return $false
            }
        }
        Write-Host "       Download failed: $_" -ForegroundColor Red
        return $false
    }
}

# Download GeoIP files
Write-Host "[2/6] Downloading GeoIP databases..." -ForegroundColor Yellow

$geoipPath = Join-Path $AssetsDir "geoip"
$geoip6Path = Join-Path $AssetsDir "geoip6"

# Try multiple sources for GeoIP
$geoipSources = @(
    "https://raw.githubusercontent.com/nicechute/tor/refs/heads/main/src/config/geoip",
    "https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip"
)

$geoip6Sources = @(
    "https://raw.githubusercontent.com/nicechute/tor/refs/heads/main/src/config/geoip6",
    "https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip6"
)

$geoipDownloaded = $false
foreach ($url in $geoipSources) {
    Write-Host "       Trying: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $geoipPath -UseBasicParsing -TimeoutSec 30
        $geoipDownloaded = $true
        Write-Host "       GeoIP downloaded successfully" -ForegroundColor Green
        break
    }
    catch {
        Write-Host "       Failed, trying next source..." -ForegroundColor Yellow
    }
}

$geoip6Downloaded = $false
foreach ($url in $geoip6Sources) {
    Write-Host "       Trying: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $geoip6Path -UseBasicParsing -TimeoutSec 30
        $geoip6Downloaded = $true
        Write-Host "       GeoIP6 downloaded successfully" -ForegroundColor Green
        break
    }
    catch {
        Write-Host "       Failed, trying next source..." -ForegroundColor Yellow
    }
}

if (-not $geoipDownloaded -or -not $geoip6Downloaded) {
    Write-Host ""
    Write-Host "WARNING: Could not download GeoIP files automatically." -ForegroundColor Red
    Write-Host "Please download manually from:" -ForegroundColor Yellow
    Write-Host "  https://gitlab.torproject.org/tpo/core/tor/-/tree/main/src/config" -ForegroundColor Cyan
    Write-Host ""
}

# For Tor binary, we need to handle this specially
Write-Host "[3/6] Tor binary acquisition..." -ForegroundColor Yellow

$torBinaryPath = Join-Path $AssetsDir "tor"

# Check if we should build from source
if ($FromSource) {
    Write-Host "       Building from source requires Android NDK setup." -ForegroundColor Yellow
    Write-Host "       See: scripts/build_tor_from_source.sh" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "       Alternative: Extract from Tor Browser for Android APK" -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "       =============================================" -ForegroundColor Cyan
    Write-Host "       MANUAL STEP REQUIRED: Tor Binary" -ForegroundColor Cyan
    Write-Host "       =============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "       Tor binaries cannot be auto-downloaded due to" -ForegroundColor Yellow
    Write-Host "       security requirements (signature verification)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "       Options:" -ForegroundColor White
    Write-Host ""
    Write-Host "       1. Extract from Tor Browser for Android:" -ForegroundColor Green
    Write-Host "          - Download official APK from torproject.org" -ForegroundColor Gray
    Write-Host "          - Unzip the APK" -ForegroundColor Gray
    Write-Host "          - Find: lib/arm64-v8a/libTor.so" -ForegroundColor Gray
    Write-Host "          - Copy and rename to: tor" -ForegroundColor Gray
    Write-Host ""
    Write-Host "       2. Build from source (Linux/macOS):" -ForegroundColor Green
    Write-Host "          - Run: scripts/build_tor_from_source.sh" -ForegroundColor Gray
    Write-Host ""
    Write-Host "       3. Use Guardian Project builds:" -ForegroundColor Green
    Write-Host "          - https://github.com/nicechute/nicechute/nicechute-nicechute-nicechute-nicechute" -ForegroundColor Gray
    Write-Host ""
}

# Create extraction helper script
Write-Host "[4/6] Creating helper scripts..." -ForegroundColor Yellow

$extractScript = @'
#!/bin/bash
# Extract Tor binary from official Tor Browser APK
#
# Usage: ./extract_tor_from_apk.sh <path_to_apk>
#
# This extracts the arm64-v8a Tor binary from the official
# Tor Browser for Android APK.

set -e

APK_PATH="${1:-tor-browser.apk}"
OUTPUT_DIR="$(dirname "$0")/../android/app/src/main/assets/tor"

if [ ! -f "$APK_PATH" ]; then
    echo "Error: APK not found at $APK_PATH"
    echo "Download from: https://www.torproject.org/download/#android"
    exit 1
fi

echo "Extracting Tor binary from: $APK_PATH"

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Unzip APK
unzip -q "$APK_PATH" -d "$TEMP_DIR"

# Find and copy Tor binary
TOR_BINARY="$TEMP_DIR/lib/arm64-v8a/libTor.so"
if [ -f "$TOR_BINARY" ]; then
    cp "$TOR_BINARY" "$OUTPUT_DIR/tor"
    chmod 755 "$OUTPUT_DIR/tor"
    echo "Tor binary extracted successfully!"
    echo "Location: $OUTPUT_DIR/tor"
    
    # Verify
    file "$OUTPUT_DIR/tor"
else
    echo "Error: libTor.so not found in APK"
    echo "Expected path: lib/arm64-v8a/libTor.so"
    exit 1
fi
'@

$extractScriptPath = Join-Path $ScriptDir "extract_tor_from_apk.sh"
$extractScript | Out-File -FilePath $extractScriptPath -Encoding utf8 -NoNewline
Write-Host "       Created: extract_tor_from_apk.sh" -ForegroundColor Green

# Create PowerShell extraction script for Windows
$extractPsScript = @'
# Extract Tor binary from official Tor Browser APK (Windows)
#
# Usage: .\Extract-TorFromApk.ps1 -ApkPath "tor-browser.apk"

param(
    [Parameter(Mandatory=$true)]
    [string]$ApkPath
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputDir = Join-Path (Split-Path -Parent $ScriptDir) "android\app\src\main\assets\tor"

if (-not (Test-Path $ApkPath)) {
    Write-Host "Error: APK not found at $ApkPath" -ForegroundColor Red
    Write-Host "Download from: https://www.torproject.org/download/#android" -ForegroundColor Yellow
    exit 1
}

Write-Host "Extracting Tor binary from: $ApkPath" -ForegroundColor Cyan

# Create temp directory
$TempDir = Join-Path $env:TEMP "tor_extract_$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
    # Use .NET to extract
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ApkPath, $TempDir)
    
    # Find Tor binary
    $TorBinary = Join-Path $TempDir "lib\arm64-v8a\libTor.so"
    
    if (Test-Path $TorBinary) {
        $OutputPath = Join-Path $OutputDir "tor"
        Copy-Item $TorBinary $OutputPath -Force
        
        Write-Host "Tor binary extracted successfully!" -ForegroundColor Green
        Write-Host "Location: $OutputPath" -ForegroundColor Cyan
        
        # Get file info
        $fileInfo = Get-Item $OutputPath
        Write-Host "Size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Gray
    }
    else {
        Write-Host "Error: libTor.so not found in APK" -ForegroundColor Red
        Write-Host "Expected path: lib\arm64-v8a\libTor.so" -ForegroundColor Yellow
        
        # List what we found
        Write-Host "Contents of lib/:" -ForegroundColor Yellow
        Get-ChildItem (Join-Path $TempDir "lib") -Recurse | ForEach-Object {
            Write-Host "  $($_.FullName.Replace($TempDir, ''))" -ForegroundColor Gray
        }
        exit 1
    }
}
finally {
    # Cleanup
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
'@

$extractPsScriptPath = Join-Path $ScriptDir "Extract-TorFromApk.ps1"
$extractPsScript | Out-File -FilePath $extractPsScriptPath -Encoding utf8
Write-Host "       Created: Extract-TorFromApk.ps1" -ForegroundColor Green

# Update README with build info
Write-Host "[5/6] Generating documentation..." -ForegroundColor Yellow

$buildDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$readme = @"
# Tor Binary Assets — Secure Insta Message

## Build Information

| Field | Value |
|-------|-------|
| Target Tor Version | $TorVersion |
| Build Date | $buildDate |
| Target Architecture | arm64-v8a (mandatory) |
| Source | Tor Project / Guardian Project |

## Required Files

```
tor/
├── tor          # Tor daemon binary (arm64-v8a, ~8-12 MB)
├── geoip        # IPv4 GeoIP database (~1.5 MB)
├── geoip6       # IPv6 GeoIP database (~1 MB)
└── README.md    # This file
```

## Obtaining Tor Binary

### Option 1: Extract from Tor Browser for Android (Recommended)

1. Download official Tor Browser APK:
   https://www.torproject.org/download/#android

2. Extract the binary:
   - **Windows**: Run `scripts\Extract-TorFromApk.ps1 -ApkPath "path\to\tor-browser.apk"`
   - **Linux/macOS**: Run `scripts/extract_tor_from_apk.sh path/to/tor-browser.apk`

3. The binary will be placed at `android/app/src/main/assets/tor/tor`

### Option 2: Build from Source

See `scripts/build_tor_from_source.sh` for NDK-based compilation.

### Option 3: Guardian Project Releases

Download from: https://github.com/nicechute/nicechute/nicechute-nicechute-nicechute-nicechute/releases

## Verification

After placing the binary, verify:

```bash
# Check architecture
file tor
# Expected: ELF 64-bit LSB shared object, ARM aarch64

# Check size (should be 8-12 MB, not debug build)
ls -la tor

# Check it's stripped
readelf -S tor | grep debug
# Should return nothing (no debug sections)
```

## Security Requirements

- **DO NOT** use binaries from untrusted sources
- **VERIFY** GPG signatures when available
- **RECORD** the exact version and source
- **STRIP** debug symbols before packaging

## GeoIP Files

GeoIP files are downloaded from the official Tor repository:
- Source: https://gitlab.torproject.org/tpo/core/tor/-/tree/main/src/config
- These files map IP addresses to countries for circuit building

## Runtime Behavior

At app startup:
1. TorService extracts these files to internal storage
2. Applies executable permission (chmod 700) to tor binary
3. Generates torrc with correct paths
4. Starts Tor daemon
5. Monitors bootstrap progress
6. Enables messaging only when bootstrap = 100%

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "Permission denied" | Binary not extracted correctly | Check TorService.extractAsset() |
| "Bad ELF" | Wrong architecture | Use arm64-v8a binary |
| Bootstrap stalls | Network issues / censorship | Check connectivity |
| Tor crashes | Corrupt binary | Re-download from source |

## Audit Trail

When updating Tor, record:
- [ ] Tor version
- [ ] Download source URL
- [ ] Git commit hash (if from source)
- [ ] Build toolchain version
- [ ] Date of update
- [ ] Person who performed update

---
*Last generated: $buildDate*
"@

$readmePath = Join-Path $AssetsDir "README.md"
$readme | Out-File -FilePath $readmePath -Encoding utf8
Write-Host "       Created: README.md" -ForegroundColor Green

# Cleanup placeholders
Write-Host "[6/6] Cleaning up placeholders..." -ForegroundColor Yellow

$placeholders = @("tor.placeholder", "geoip.placeholder", "geoip6.placeholder")
foreach ($placeholder in $placeholders) {
    $placeholderPath = Join-Path $AssetsDir $placeholder
    if (Test-Path $placeholderPath) {
        Remove-Item $placeholderPath -Force
        Write-Host "       Removed: $placeholder" -ForegroundColor Gray
    }
}

# Cleanup temp
Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue

# Summary
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Build Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$geoipExists = Test-Path $geoipPath
$geoip6Exists = Test-Path $geoip6Path
$torExists = Test-Path $torBinaryPath

Write-Host "  Assets directory: $AssetsDir" -ForegroundColor White
Write-Host ""
Write-Host "  File Status:" -ForegroundColor White
Write-Host "    geoip:  $(if ($geoipExists) { 'OK' } else { 'MISSING' })" -ForegroundColor $(if ($geoipExists) { 'Green' } else { 'Red' })
Write-Host "    geoip6: $(if ($geoip6Exists) { 'OK' } else { 'MISSING' })" -ForegroundColor $(if ($geoip6Exists) { 'Green' } else { 'Red' })
Write-Host "    tor:    $(if ($torExists) { 'OK' } else { 'MISSING - Manual step required' })" -ForegroundColor $(if ($torExists) { 'Green' } else { 'Yellow' })
Write-Host ""

if (-not $torExists) {
    Write-Host "  NEXT STEP:" -ForegroundColor Yellow
    Write-Host "    1. Download Tor Browser APK from torproject.org" -ForegroundColor White
    Write-Host "    2. Run: .\Extract-TorFromApk.ps1 -ApkPath <path_to_apk>" -ForegroundColor White
    Write-Host ""
}

if ($geoipExists -and $geoip6Exists -and $torExists) {
    Write-Host "  All files present. Ready to build!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Build command:" -ForegroundColor White
    Write-Host "    flutter build apk --release" -ForegroundColor Cyan
}

Write-Host ""
