# Tor Binary Test Results

## Test Date: 2026-02-13

## Test Environment
- Device: Android (arm64)
- APK: Debug build
- Binary Source: Tor Browser APK (libTor.so extracted)

## Results

### Binary Analysis (On Device)
```
$ adb shell "run-as com.securemessage.app ls -la files/tor"
-rwx------ 1 u0_a890 u0_a890 8355864 2026-02-13 10:22 files/tor

$ adb shell "run-as com.securemessage.app file files/tor"
files/tor: ELF shared object, 64-bit LSB arm64, dynamic (/system/bin/linker64), for Android 21, built by NDK r28b (13356709), stripped
```

### TorService Logs
```
I TorService: TorService created
I TorService: TorService starting
E TorService: Failed to start Tor process
E TorService: java.io.IOException: Cannot run program "/data/user/0/com.securemessage.app/files/tor": error=13, Permission denied
```

## VERDICT: ❌ FAILED

| Check | Result |
|-------|--------|
| File extracted | ✅ Yes |
| Permissions | ✅ `-rwx------` |
| Size | ✅ 8.35 MB |
| **ELF Type** | ❌ **Shared object** (not executable) |
| **Execution** | ❌ Permission denied (exec() rejects .so) |

## Root Cause

The binary extracted from Tor Browser APK (`libTor.so`) is a **JNI shared library**, not a standalone executable:
- Type: `ELF shared object` (NOT `ELF executable`)
- Designed for: `dlopen()` / JNI loading
- **Cannot be**: executed via `ProcessBuilder` / `exec()`

Despite showing a non-zero entry point in static analysis on Windows, on-device `file` command confirms this is a shared object.

## Resolution Required

Per the Master Prompt directive:
> If execution fails, replace it — do not adapt the system to it.

The binary MUST be replaced with a source-built Tor executable.

### Build Options

1. **GitHub Actions** (Recommended)
   - Push repo to GitHub
   - Run: Actions → "Build Tor for Android"
   - Download artifact → Replace `android/app/src/main/assets/tor/tor`

2. **Linux/macOS Build**
   ```bash
   ./scripts/build_tor_from_source.sh arm64-v8a
   ```

3. **Docker Build**
   ```bash
   docker run --rm -v $(pwd):/workspace ubuntu:22.04 \
     /workspace/scripts/build_tor_from_source.sh arm64-v8a
   ```

## Expected Binary Characteristics

The replacement binary must satisfy:
```
$ file tor
tor: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked, stripped

$ readelf -h tor
ELF Header:
  Type:                              EXEC (Executable file)
  Entry point address:               0x[non-zero]
```

## Files to Replace
```
android/app/src/main/assets/tor/
├── tor       # ← Replace with executable (current is .so)
├── geoip     # ✅ OK  
└── geoip6    # ✅ OK
```
