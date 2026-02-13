# Building Tor Executable for Android

## The Problem

The Tor binary extracted from Tor Browser APK (`libTor.so`) is a **shared library** (JNI), not an executable. Our `TorService.kt` uses `ProcessBuilder` which requires an actual executable binary with an entry point.

### How to Verify Binary Type
```bash
# Check ELF type
readelf -h tor | grep "Type:"

# Shared library (WRONG): Type: DYN (Shared object file)
# Executable (CORRECT): Type: EXEC (Executable file) 
#                   or: Type: DYN (Position-Independent Executable) with non-zero entry point
```

## Build Options

### Option 1: GitHub Actions (Recommended)

1. Push this repository to GitHub
2. Go to Actions → "Build Tor for Android"
3. Click "Run workflow" → Select arm64-v8a → Run
4. Download the artifact when complete
5. Extract and copy `tor` to `android/app/src/main/assets/tor/`

### Option 2: Linux/macOS Build

Run the build script:
```bash
cd scripts
chmod +x build_tor_from_source.sh
./build_tor_from_source.sh arm64-v8a

# Output: flutter_client/android/app/src/main/assets/tor/tor
```

### Option 3: Docker Build

```bash
docker run --rm -v $(pwd):/workspace -w /workspace/scripts \
    --env ANDROID_NDK_HOME=/opt/android-ndk \
    build-tor-android:latest \
    ./build_tor_from_source.sh arm64-v8a
```

### Option 4: Manual Cross-Compilation

Requirements:
- Android NDK r23+ 
- Linux/macOS build host
- Build tools: autoconf, automake, libtool

```bash
# Set up NDK
export ANDROID_NDK_HOME=/path/to/android-ndk
export TARGET=aarch64-linux-android
export API=21
export TOOLCHAIN=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64

# Build dependencies (OpenSSL, libevent, zlib)
# ... see build_tor_from_source.sh for details

# Configure Tor for EXECUTABLE output
./configure \
    --host=$TARGET \
    --disable-asciidoc \
    --disable-system-torrc \
    --disable-lzma \
    --disable-zstd \
    --enable-static-tor \
    --enable-static-libevent \
    --enable-static-openssl \
    --enable-static-zlib \
    --with-libevent-dir=$PREFIX \
    --with-openssl-dir=$PREFIX \
    --with-zlib-dir=$PREFIX \
    CC=$TOOLCHAIN/bin/$TARGET$API-clang \
    CXX=$TOOLCHAIN/bin/$TARGET$API-clang++ \
    CFLAGS="-fPIE -fPIC -O2" \
    LDFLAGS="-pie -static-libstdc++"

make -j$(nproc)

# Result: src/app/tor (executable)
```

## Pre-built Binary Sources

If you cannot build from source, these projects provide pre-built Tor executables:

1. **Orbot** - https://github.com/guardianproject/orbot
   - Check releases for `tor-android-*` artifacts

2. **goptlib** - Various Go Tor implementations

3. **tor-mobile** - https://github.com/nicpolhern/tor-mobile
   - Community mobile Tor builds

## Verification After Build

Always verify the binary before packaging:

```bash
# Must show EXEC or DYN with entry point
readelf -h android/app/src/main/assets/tor/tor

# Entry point address must NOT be 0x0
# Example good output:
#   Type: EXEC (Executable file)
#   Entry point address: 0x12345678

# Check it's for arm64
file android/app/src/main/assets/tor/tor
# Should show: ELF 64-bit LSB executable, ARM aarch64
```

## Asset Structure

After building, your assets folder should look like:
```
android/app/src/main/assets/tor/
├── tor          # Executable binary (~5-10 MB)
├── geoip        # IPv4 country database
└── geoip6       # IPv6 country database
```

## Troubleshooting

### "Permission denied" when starting Tor
- Ensure executable permission: `chmod 755 tor`
- Check SELinux context on device

### Tor crashes immediately
- Verify binary architecture matches device
- Check logcat for specific error

### "Bad ELF interpreter"
- Binary may be built for wrong API level
- Rebuild with `API=21` or lower

### libTor.so is still a shared library
- You're using the wrong binary source
- Must build from source with `--enable-static-tor`
- Do NOT extract from Tor Browser APK
