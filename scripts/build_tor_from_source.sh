#!/bin/bash
# =============================================================================
# Secure Insta Message — Build Tor EXECUTABLE from Source for Android
# =============================================================================
#
# CRITICAL: This builds Tor as an EXECUTABLE binary, not a shared library.
#           The resulting binary can be launched via exec()/ProcessBuilder.
#
# This script builds Tor from source using the Android NDK.
# Run on Linux or macOS with Android NDK installed.
#
# Prerequisites:
#   - Android NDK r23+ (r25 recommended)
#   - autoconf, automake, libtool, pkg-config
#   - git, curl, make
#
# Usage:
#   export ANDROID_NDK_HOME=/path/to/ndk
#   ./build_tor_from_source.sh
#
# Output:
#   android/app/src/main/assets/tor/tor (arm64-v8a EXECUTABLE)
#
# Verification:
#   file tor                    # Should say "executable" or "pie executable"
#   readelf -h tor | grep Type  # Should NOT be just "DYN (Shared object file)"
#
# =============================================================================

set -e

# Configuration
TOR_VERSION="0.4.8.13"
TOR_URL="https://dist.torproject.org/tor-${TOR_VERSION}.tar.gz"
OPENSSL_VERSION="3.2.1"
LIBEVENT_VERSION="2.1.12-stable"
ZLIB_VERSION="1.3.1"

# Target architecture
TARGET_ABI="arm64-v8a"
TARGET_ARCH="aarch64"
TARGET_TRIPLE="aarch64-linux-android"
API_LEVEL=21

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/android/app/src/main/assets/tor"
BUILD_DIR="/tmp/tor_build_$$"
PREFIX="$BUILD_DIR/prefix"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}"
echo "============================================="
echo "  Secure Insta Message — Tor Source Builder"
echo "============================================="
echo -e "${NC}"

# Check NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    # Try common locations
    if [ -d "$HOME/Android/Sdk/ndk" ]; then
        ANDROID_NDK_HOME=$(ls -d "$HOME/Android/Sdk/ndk"/* 2>/dev/null | tail -1)
    elif [ -d "/usr/local/android-ndk" ]; then
        ANDROID_NDK_HOME="/usr/local/android-ndk"
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo -e "${RED}Error: Android NDK not found${NC}"
    echo "Set ANDROID_NDK_HOME environment variable or install NDK via Android Studio"
    echo ""
    echo "Example:"
    echo "  export ANDROID_NDK_HOME=\$HOME/Android/Sdk/ndk/25.2.9519653"
    exit 1
fi

echo -e "${GREEN}Using NDK: $ANDROID_NDK_HOME${NC}"

# Setup toolchain
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
if [ ! -d "$TOOLCHAIN" ]; then
    TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
fi

if [ ! -d "$TOOLCHAIN" ]; then
    echo -e "${RED}Error: NDK toolchain not found${NC}"
    exit 1
fi

export CC="$TOOLCHAIN/bin/${TARGET_TRIPLE}${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET_TRIPLE}${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export AS="$TOOLCHAIN/bin/llvm-as"
export LD="$TOOLCHAIN/bin/ld"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export NM="$TOOLCHAIN/bin/llvm-nm"

# Verify compiler
if [ ! -f "$CC" ]; then
    echo -e "${RED}Error: Compiler not found at $CC${NC}"
    exit 1
fi

echo -e "${GREEN}Compiler: $CC${NC}"

# Create directories
echo -e "\n${YELLOW}[1/7] Creating build directories...${NC}"
mkdir -p "$BUILD_DIR"
mkdir -p "$PREFIX/lib"
mkdir -p "$PREFIX/include"
mkdir -p "$OUTPUT_DIR"

cd "$BUILD_DIR"

# Download and build zlib
echo -e "\n${YELLOW}[2/7] Building zlib...${NC}"
curl -LO "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
cd "zlib-${ZLIB_VERSION}"

CHOST=$TARGET_TRIPLE ./configure --prefix="$PREFIX" --static
make -j$(nproc)
make install

cd "$BUILD_DIR"

# Download and build OpenSSL
echo -e "\n${YELLOW}[3/7] Building OpenSSL...${NC}"
curl -LO "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
cd "openssl-${OPENSSL_VERSION}"

./Configure android-arm64 \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl" \
    no-shared \
    no-tests \
    no-ui-console \
    -D__ANDROID_API__=$API_LEVEL

make -j$(nproc)
make install_sw

cd "$BUILD_DIR"

# Download and build libevent
echo -e "\n${YELLOW}[4/7] Building libevent...${NC}"
curl -LO "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz"
tar xzf "libevent-${LIBEVENT_VERSION}.tar.gz"
cd "libevent-${LIBEVENT_VERSION}"

./configure \
    --host=$TARGET_TRIPLE \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --disable-samples \
    --disable-libevent-regress \
    CFLAGS="-I$PREFIX/include" \
    LDFLAGS="-L$PREFIX/lib"

make -j$(nproc)
make install

cd "$BUILD_DIR"

# Download and build Tor
echo -e "\n${YELLOW}[5/7] Building Tor...${NC}"
curl -LO "$TOR_URL"
tar xzf "tor-${TOR_VERSION}.tar.gz"
cd "tor-${TOR_VERSION}"

# Configure Tor for Android
./configure \
    --host=$TARGET_TRIPLE \
    --prefix="$PREFIX" \
    --disable-asciidoc \
    --disable-system-torrc \
    --disable-tool-name-check \
    --disable-lzma \
    --disable-zstd \
    --enable-static-tor \
    --with-libevent-dir="$PREFIX" \
    --with-openssl-dir="$PREFIX" \
    --with-zlib-dir="$PREFIX" \
    CFLAGS="-I$PREFIX/include -O2 -fPIE" \
    LDFLAGS="-L$PREFIX/lib -pie -static-libstdc++"

make -j$(nproc)

# Strip and copy binary
echo -e "\n${YELLOW}[6/7] Stripping and packaging...${NC}"

TOR_BINARY="src/app/tor"
if [ -f "$TOR_BINARY" ]; then
    # Strip debug symbols
    $STRIP --strip-all "$TOR_BINARY"
    
    # Copy to output
    cp "$TOR_BINARY" "$OUTPUT_DIR/tor"
    chmod 755 "$OUTPUT_DIR/tor"
    
    echo -e "${GREEN}Tor binary created successfully!${NC}"
    echo "Location: $OUTPUT_DIR/tor"
    
    # ========================================
    # CRITICAL: Verify this is an EXECUTABLE
    # ========================================
    echo -e "\n${YELLOW}Verifying binary is executable (not shared library)...${NC}"
    
    FILE_OUTPUT=$(file "$OUTPUT_DIR/tor")
    echo "$FILE_OUTPUT"
    
    # Check with readelf
    if command -v readelf &> /dev/null; then
        ELF_TYPE=$(readelf -h "$OUTPUT_DIR/tor" 2>/dev/null | grep "Type:" | head -1)
        echo "ELF Type: $ELF_TYPE"
        
        ENTRY_POINT=$(readelf -h "$OUTPUT_DIR/tor" 2>/dev/null | grep "Entry point" | head -1)
        echo "$ENTRY_POINT"
        
        # Verify it's EXEC or DYN with entry point (PIE executables show as DYN but have entry)
        if echo "$ELF_TYPE" | grep -q "EXEC\|DYN"; then
            if echo "$ENTRY_POINT" | grep -qv "0x0$"; then
                echo -e "${GREEN}✓ Binary is a valid executable with entry point${NC}"
            else
                echo -e "${RED}✗ Binary has no entry point - may be shared library!${NC}"
                echo -e "${RED}  This will NOT work with ProcessBuilder/exec()${NC}"
                exit 1
            fi
        else
            echo -e "${RED}✗ Binary is not ELF EXEC/DYN type${NC}"
            exit 1
        fi
    fi
    
    # Additional verification: check if it's position-independent executable
    if command -v objdump &> /dev/null; then
        if objdump -p "$OUTPUT_DIR/tor" 2>/dev/null | grep -q "INTERP"; then
            echo -e "${GREEN}✓ Binary has program interpreter (executable)${NC}"
        else
            echo -e "${YELLOW}! Binary may be statically linked${NC}"
        fi
    fi
    
    ls -la "$OUTPUT_DIR/tor"
else
    echo -e "${RED}Error: Tor binary not found${NC}"
    exit 1
fi

# Download GeoIP files
echo -e "\n${YELLOW}[7/7] Downloading GeoIP files...${NC}"

GEOIP_URL="https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip"
GEOIP6_URL="https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip6"

curl -L "$GEOIP_URL" -o "$OUTPUT_DIR/geoip" || {
    # Fallback: copy from source
    cp "src/config/geoip" "$OUTPUT_DIR/geoip"
}

curl -L "$GEOIP6_URL" -o "$OUTPUT_DIR/geoip6" || {
    # Fallback: copy from source
    cp "src/config/geoip6" "$OUTPUT_DIR/geoip6"
}

# Generate build info
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
GIT_HASH=$(cd "tor-${TOR_VERSION}" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo "release-tar")

cat > "$OUTPUT_DIR/BUILD_INFO.txt" << EOF
Tor Build Information
=====================
Tor Version: $TOR_VERSION
Build Date: $BUILD_DATE
Architecture: $TARGET_ABI ($TARGET_ARCH)
API Level: $API_LEVEL
NDK: $ANDROID_NDK_HOME

Dependencies:
- OpenSSL: $OPENSSL_VERSION
- libevent: $LIBEVENT_VERSION
- zlib: $ZLIB_VERSION

Source: $TOR_URL
Build Host: $(uname -a)
EOF

# Cleanup
echo -e "\n${YELLOW}Cleaning up...${NC}"
cd /
rm -rf "$BUILD_DIR"

# Summary
echo -e "\n${CYAN}=============================================${NC}"
echo -e "${CYAN}  Build Complete!${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""
echo -e "Output directory: ${GREEN}$OUTPUT_DIR${NC}"
echo ""
ls -la "$OUTPUT_DIR"
echo ""
echo -e "${GREEN}Ready to build APK:${NC}"
echo "  cd $PROJECT_ROOT"
echo "  flutter build apk --release"
