# Secure Insta Message — Flutter Client

> **This is a UI client for the Secure Insta Message protocol.**
> **The reference implementation remains the CLI.**

```
Experimental. Privacy-preserving. Not optimized for convenience.
```

---

## What This Is

A Flutter-based mobile UI that wraps the existing
[Secure Insta Message](https://github.com/niteeshkumar17/Secure_Insta_Message)
Python core. This app:

- **Embeds Tor directly** — no Orbot or external Tor app required.
- **Delegates** all cryptography, onion routing, cover traffic, and
  protocol logic to the existing Python codebase.
- **Never** implements cryptographic primitives in Dart/Flutter.
- **Refuses** to operate without embedded Tor fully bootstrapped.
- **Preserves** the original threat model (with documented mobile
  limitations).

## Architecture

```
Flutter UI (Dart)
   ↓
TorManager (MethodChannel)
   ↓
TorService (Android Foreground Service)
   ↓
Embedded Tor Binary (arm64-v8a)
   ↓
SOCKS5 Proxy (127.0.0.1:9050)
   ↓
Secure Insta Message Core (Python)
   ↓
Relays / Mailboxes (onion services)
```

The Flutter client is a **presentation layer only**. Removing it
does not affect the network, the protocol, or any other client.

## Embedded Tor

This app **does not require Orbot**. Tor is embedded directly:

- **Automatic startup**: Tor starts when the app launches
- **Foreground service**: Runs with persistent notification
- **Bootstrap monitoring**: UI shows connection progress
- **Kill-switch enforced**: Messaging blocked until 100% bootstrapped
- **Localhost binding**: SOCKS proxy binds only to 127.0.0.1
- **Cookie authentication**: Control port secured

### Tor Binary Setup

Before building, you must place the Tor binary and GeoIP files:

```
android/app/src/main/assets/tor/
├── tor          # arm64-v8a binary from torproject.org
├── geoip        # IPv4 GeoIP database
└── geoip6       # IPv6 GeoIP database
```

See [assets/tor/README.md](android/app/src/main/assets/tor/README.md) for
instructions on obtaining and verifying Tor binaries.

## Features

### ✅ Supported

| Feature | Description |
|---|---|
| Embedded Tor | No Orbot required, standalone APK |
| Identity management | Generate, import/export Ed25519 keypairs |
| Fingerprint display | Public key fingerprint with QR code |
| Contact management | Manual key exchange, fingerprint verification |
| Text messaging | End-to-end encrypted via Double Ratchet |
| Voice messages | Asynchronous only (no calls) |
| Delivery receipts | ✓ sent / ✓✓ delivered (cryptographic) |
| Relay configuration | Manual relay/mailbox setup |
| Threat model docs | In-app security documentation |

### ❌ Intentionally Unsupported

These features are excluded by design:

- Push notifications (FCM / APNS)
- Typing indicators
- Read receipts
- Online / last-seen status
- Voice calls / video calls
- Media streaming
- Contact syncing
- Phone number or email identity
- Analytics, telemetry, crash reporting
- WebRTC / STUN / TURN
- Cloud account login

If a feature improves UX but weakens privacy guarantees,
**it is rejected**.

## Project Structure

```
flutter_client/
├── lib/
│   ├── main.dart                  # App entry point
│   ├── models/                    # Presentation data models
│   │   ├── identity.dart          # Identity (public key, fingerprint)
│   │   ├── contact.dart           # Contact (key, onion, verification)
│   │   ├── message.dart           # Message (no timestamps!)
│   │   ├── delivery_status.dart   # ✓ / ✓✓ only
│   │   ├── network_status.dart    # Tor, relay, cover traffic status
│   │   ├── core_command.dart      # JSON-RPC commands to core
│   │   └── core_response.dart     # JSON-RPC responses from core
│   ├── services/                  # Service layer (bridge → core)
│   │   ├── tor_manager.dart       # Embedded Tor control (MethodChannel)
│   │   ├── core_bridge.dart       # Python subprocess JSON-RPC bridge
│   │   ├── identity_service.dart  # Identity operations
│   │   ├── contacts_service.dart  # Contact management
│   │   ├── messaging_service.dart # Message send/receive/poll
│   │   └── network_service.dart   # Network status monitoring
│   ├── screens/                   # UI screens
│   │   ├── home_screen.dart       # Navigation hub + Tor status
│   │   ├── identity_screen.dart   # Identity management
│   │   ├── contacts_screen.dart   # Contact list
│   │   ├── chat_screen.dart       # Messaging
│   │   ├── network_status_screen.dart # Network monitoring
│   │   └── about_screen.dart      # Warnings & documentation
│   ├── widgets/                   # Shared UI components
│   │   └── common_widgets.dart    # Warning banners, status dots, etc.
│   └── theme/
│       └── app_theme.dart         # Dark theme
├── android/
│   └── app/
│       ├── src/main/
│       │   ├── kotlin/.../TorService.kt   # Tor foreground service
│       │   ├── kotlin/.../MainActivity.kt # MethodChannel bridge
│       │   └── assets/tor/        # Tor binary, geoip files
│       └── build.gradle           # Android build config
├── python_bridge/
│   └── flutter_bridge.py          # Python-side JSON-RPC adapter
├── MOBILE_LIMITATIONS.md          # Mobile-specific threat model
└── README.md                      # This file
```

## Building

### Prerequisites

- Flutter SDK ≥ 3.2.0
- Python 3.10+ (bundled with the core)
- Tor binary for arm64-v8a (see setup)
- The Secure Insta Message core repository

### Setup

```bash
# Clone the main repository
git clone https://github.com/niteeshkumar17/Secure_Insta_Message.git
cd Secure_Insta_Message

# Install Python dependencies
python -m venv .venv
source .venv/bin/activate  # or .venv\Scripts\activate on Windows
pip install -r requirements.txt

# Download and place Tor binaries
# See android/app/src/main/assets/tor/README.md

# Build the Flutter client
cd flutter_client
flutter pub get
flutter run
```

### Release Build

```bash
flutter build apk --release    # Android
```

**No app store analytics. No third-party SDKs. Reproducible builds
where possible.**

## Security Notes

- **Tor is embedded** — no Orbot required, standalone operation.
- **All cryptographic operations** happen in the Python core process.
- **All network traffic** goes through embedded Tor (kill-switch enforced).
- **No clearnet fallback** exists.
- **No telemetry** — zero data collection, zero analytics.
- **Messages have no timestamps** — only coarse ordering.
- See [MOBILE_LIMITATIONS.md](MOBILE_LIMITATIONS.md) for mobile-specific
  security considerations.

## Success Criteria

This Flutter app is correct if:

1. It embeds Tor and runs standalone without Orbot
2. It can send/receive messages using the existing core
3. It does not introduce new metadata leaks
4. It refuses unsafe operation (kill-switch)
5. It does not diverge from the protocol
6. Removing the app does not affect the network
7. The core repo remains unchanged

## Final Rule

> If the Flutter app ever becomes the "main thing", the project has failed.
> The app exists to make the system usable, not popular.

---

*Secure Insta Message — Ultra-Private Messaging System*
*Protocol v1.0 | Experimental | Not audited*
