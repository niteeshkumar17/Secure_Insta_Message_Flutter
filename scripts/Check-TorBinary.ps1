# Download Pre-built Tor Executable from Guardian Project
# This downloads FROM Orbot's build artifacts which contain proper executables

param(
    [string]$Architecture = "arm64-v8a"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$AssetsDir = Join-Path $ProjectRoot "android\app\src\main\assets\tor"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Download Pre-built Tor Executable" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Create output directory
if (-not (Test-Path $AssetsDir)) {
    New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
}

# Guardian Project's tor-android releases
# These contain actual executables, not JNI libraries
$TorAndroidVersion = "0.4.8.14"
$BaseUrl = "https://github.com/nicpolhien/tor-prebuilt/releases/download"

Write-Host "Checking available sources for Tor executable..." -ForegroundColor Yellow
Write-Host ""

# Option 1: Try tor-android from nicpolhien's prebuilt (community maintained)
$PrebuiltSources = @(
    @{
        Name = "nicpolhien/tor-prebuilt"
        Url = "https://github.com/nicpolhien/tor-prebuilt/releases"
        Note = "Community pre-built Tor executables"
    },
    @{
        Name = "AgoraDesk-LocalMonero/agoradesk-android"
        Url = "https://github.com/AgoraDesk-LocalMonero/agoradesk-android"
        Note = "Contains Tor executable in releases"
    }
)

Write-Host "Unfortunately, there are no widely-trusted pre-built Tor EXECUTABLES" -ForegroundColor Yellow
Write-Host "readily available for direct download." -ForegroundColor Yellow
Write-Host ""
Write-Host "The Tor Browser APK contains libTor.so which is a JNI LIBRARY," -ForegroundColor Red
Write-Host "NOT an executable that can be launched via ProcessBuilder." -ForegroundColor Red
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  RECOMMENDED: Build from Source" -ForegroundColor Cyan  
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Option 1: GitHub Actions (Easiest)" -ForegroundColor Green
Write-Host "  1. Push this repo to GitHub" -ForegroundColor White
Write-Host "  2. Go to Actions -> 'Build Tor for Android'" -ForegroundColor White
Write-Host "  3. Click 'Run workflow'" -ForegroundColor White
Write-Host "  4. Download artifact and extract to $AssetsDir" -ForegroundColor White
Write-Host ""
Write-Host "Option 2: Linux/WSL Build" -ForegroundColor Green
Write-Host "  ./scripts/build_tor_from_source.sh arm64-v8a" -ForegroundColor White
Write-Host ""
Write-Host "Option 3: Docker Build" -ForegroundColor Green
Write-Host "  docker run --rm -v `$(pwd):/workspace ubuntu:22.04 \" -ForegroundColor White
Write-Host "    /workspace/scripts/build_tor_from_source.sh arm64-v8a" -ForegroundColor White
Write-Host ""

# Check if we have the bad binary
$TorPath = Join-Path $AssetsDir "tor"
if (Test-Path $TorPath) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Current Binary Analysis" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    
    $FileSize = (Get-Item $TorPath).Length / 1MB
    Write-Host "File: $TorPath" -ForegroundColor White
    Write-Host "Size: $([math]::Round($FileSize, 2)) MB" -ForegroundColor White
    
    # Read first bytes to check ELF header
    $Bytes = [System.IO.File]::ReadAllBytes($TorPath)
    
    if ($Bytes.Length -gt 20) {
        # ELF magic: 0x7f 'E' 'L' 'F'
        if ($Bytes[0] -eq 0x7f -and $Bytes[1] -eq 0x45 -and $Bytes[2] -eq 0x4c -and $Bytes[3] -eq 0x46) {
            Write-Host "Format: ELF binary" -ForegroundColor White
            
            # e_type at offset 16 (2 bytes)
            $EType = [BitConverter]::ToUInt16($Bytes, 16)
            
            switch ($EType) {
                2 { 
                    Write-Host "Type: ET_EXEC (Executable) - GOOD!" -ForegroundColor Green 
                }
                3 { 
                    Write-Host "Type: ET_DYN (Shared Object)" -ForegroundColor Yellow
                    
                    # Check entry point at offset 24 (8 bytes for 64-bit)
                    if ($Bytes[4] -eq 2) { # 64-bit ELF
                        $EntryPoint = [BitConverter]::ToUInt64($Bytes, 24)
                        if ($EntryPoint -eq 0) {
                            Write-Host "Entry Point: 0x0 - THIS IS A SHARED LIBRARY, NOT EXECUTABLE!" -ForegroundColor Red
                            Write-Host ""
                            Write-Host "This binary CANNOT be used with ProcessBuilder." -ForegroundColor Red
                            Write-Host "You must build Tor from source to get a proper executable." -ForegroundColor Red
                        } else {
                            Write-Host "Entry Point: 0x$($EntryPoint.ToString('X')) - PIE Executable, may work" -ForegroundColor Green
                        }
                    }
                }
                default { 
                    Write-Host "Type: Unknown ($EType)" -ForegroundColor Yellow 
                }
            }
        } else {
            Write-Host "Format: Not ELF (unexpected)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  GeoIP Files Status" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$GeoIPPath = Join-Path $AssetsDir "geoip"
$GeoIP6Path = Join-Path $AssetsDir "geoip6"

if (Test-Path $GeoIPPath) {
    $Size = [math]::Round((Get-Item $GeoIPPath).Length / 1MB, 2)
    Write-Host "geoip:  OK ($Size MB)" -ForegroundColor Green
} else {
    Write-Host "geoip:  MISSING" -ForegroundColor Red
}

if (Test-Path $GeoIP6Path) {
    $Size = [math]::Round((Get-Item $GeoIP6Path).Length / 1MB, 2)
    Write-Host "geoip6: OK ($Size MB)" -ForegroundColor Green
} else {
    Write-Host "geoip6: MISSING" -ForegroundColor Red
}

Write-Host ""
