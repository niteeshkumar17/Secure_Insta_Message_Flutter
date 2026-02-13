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
