# Tor Binary Assets — Secure Insta Message

## Build Information

| Field | Value |
|-------|-------|
| Source | Tor Browser for Android 15.0.5 |
| Tor Version | ~0.4.8.x (bundled with Tor Browser 15.0.5) |
| Extraction Date | 2026-02-13 |
| Architecture | arm64-v8a (aarch64) |
| Binary Source | `lib/arm64-v8a/libTor.so` from official APK |
| APK URL | https://dist.torproject.org/torbrowser/15.0.5/tor-browser-android-aarch64-15.0.5.apk |
| Tor Binary Size | 7.97 MB |

## Verification

The Tor binary was extracted from the **official** Tor Browser for Android APK
distributed by the Tor Project at `dist.torproject.org`.

```
APK: tor-browser-android-aarch64-15.0.5.apk
Binary: lib/arm64-v8a/libTor.so -> renamed to 'tor'
Format: ELF 64-bit LSB shared object, ARM aarch64
```

## File Manifest

| File | Size | Description |
|------|------|-------------|
| `tor` | 7.97 MB | Tor daemon binary (arm64-v8a) |
| `geoip` | 8.74 MB | IPv4 GeoIP database |
| `geoip6` | 15.77 MB | IPv6 GeoIP database |
| `torrc.template` | < 1 KB | Reference configuration |
| `README.md` | < 1 KB | This file |

## Security Notes

### Binary Provenance

- **Source**: Official Tor Project distribution server
- **URL**: https://dist.torproject.org/torbrowser/15.0.5/
- **The binary is NOT modified** - extracted directly from official APK
- **No debug symbols** - production build

### GeoIP Files

Downloaded directly from Tor Project GitLab:
- https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip
- https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip6

## Runtime Behavior

When the app starts:

1. **TorService** extracts these files to internal storage
2. Applies executable permission: `chmod 700 tor`
3. Generates `torrc` with correct paths
4. Starts Tor daemon as subprocess
5. Monitors bootstrap progress (0% -> 100%)
6. Enables messaging **only** when bootstrap = 100%

## Updating Tor

To update the Tor binary:

```powershell
.\scripts\Extract-TorFromApk.ps1 -ApkPath "path\to\new-tor-browser.apk"
```

Or on Linux/macOS:
```bash
./scripts/extract_tor_from_apk.sh path/to/new-tor-browser.apk
```

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| "Permission denied" | Binary not executable | Check extractAsset() |
| "bad ELF header" | Wrong architecture | Use arm64-v8a binary |
| Bootstrap stuck | Network issues | Check connectivity |
| Tor crashes | Corrupt binary | Re-extract from APK |

## Audit Trail

| Date | Action | Version |
|------|--------|---------|
| 2026-02-13 | Initial extraction | Tor Browser 15.0.5 |

---
*Secure Insta Message - Embedded Tor*
