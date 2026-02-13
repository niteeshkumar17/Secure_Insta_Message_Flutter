# Mobile Limitations — Secure Insta Message Flutter Client

> **Desktop CLI remains the strongest client.**

This document explains how the mobile environment fundamentally
weakens certain guarantees of the Secure Insta Message protocol.
Users must understand these limitations before relying on the
mobile client.

---

## 1. Background Execution & Cover Traffic

**Issue:** Mobile operating systems (Android/iOS) aggressively
suspend or kill background processes to save battery.

**Impact:** When the app is backgrounded or the device is idle,
the constant-rate cover traffic stream may be paused or stopped.
An adversary monitoring Tor network traffic could observe this
pause and correlate it with the user's device state.

**Mitigation:**
- The app warns when cover traffic is paused.
- Users should be aware that backgrounding the app reduces anonymity.
- The CLI client, running on a desktop, maintains continuous cover
  traffic without OS-imposed pauses.

---

## 2. OS Power Management

**Issue:** Battery optimization features (Android Doze, iOS Background
App Refresh) restrict CPU and network access for background apps.

**Impact:**
- Cover traffic timing precision degrades (jitter increases).
- Mailbox polling frequency may decrease.
- Tor circuits may be dropped and need re-establishment.
- Message delivery latency increases when the device is idle.

**Mitigation:**
- Users can disable battery optimization for this app (at the cost
  of battery life).
- The app explicitly warns about timing degradation.

---

## 3. No Push Notifications

**Issue:** Push notifications on mobile require routing through
Google's FCM (Android) or Apple's APNS (iOS) infrastructure.

**Impact:** Without push notifications, the user must actively
open the app to check for new messages. There is no way to be
notified of incoming messages while the app is closed.

**Why this is intentional:**
- FCM/APNS require a device token registered with Google/Apple.
- This token can be used to correlate user identity across services.
- Push notification metadata (timing, sender, payload hash) is
  visible to Google/Apple.
- Even "data-only" pushes reveal that a message arrived, which
  is metadata the protocol is designed to hide.

**This is not a bug. This is a security decision.**

---

## 4. Reduced Anonymity When Device Is Idle

**Issue:** When the device screen is off and the app is not in the
foreground, the cover traffic stream stops.

**Impact:** An adversary who can observe the user's Tor traffic can
determine when the user's device is active vs. idle. This is a
metadata leak that does not exist with the CLI client.

**Mitigation:**
- The CLI client should be preferred for high-risk communications.
- Users should understand that mobile platforms trade anonymity for
  battery life.

---

## 5. Keystore Security

**Issue:** Mobile devices may have weaker physical security than
desktop systems. Devices can be lost, stolen, or compelled.

**Impact:**
- If the device is seized, the Argon2id-encrypted keystore provides
  some protection, but is ultimately limited by passphrase strength.
- Mobile OS filesystem encryption adds a layer, but may be bypassed
  by sophisticated attackers.

**Mitigation:**
- Use a strong passphrase.
- Enable full-disk encryption on the device.
- Consider the CLI on a dedicated machine for the highest security.

---

## 6. Platform Channel Security

**Issue:** The Flutter client communicates with the Python core via
JSON-RPC over stdin/stdout. On mobile, this involves platform-specific
IPC mechanisms.

**Impact:**
- On rooted/jailbroken devices, other processes may be able to
  intercept IPC traffic.
- Debug builds may expose additional attack surface.

**Mitigation:**
- Only use release builds.
- Do not use the app on rooted/jailbroken devices.
- The IPC contains only commands and responses — key material
  stays within the Python core process.

---

## 7. Screen Capture & Accessibility Services

**Issue:** Mobile OSes allow screenshot capture and accessibility
services that can read screen content.

**Impact:**
- Message content displayed on screen can be captured.
- Accessibility services (including malicious ones) can read
  message text from UI elements.

**Mitigation:**
- The app sets `FLAG_SECURE` (Android) to prevent screenshots
  in system Task Switcher.
- Users should audit their installed accessibility services.
- This is a fundamental mobile platform limitation that cannot
  be fully mitigated.

---

## Summary

| Limitation | CLI Impact | Mobile Impact |
|---|---|---|
| Cover traffic continuity | ✓ Continuous | ⚠ May pause |
| Timing precision | ✓ Precise | ⚠ OS-dependent |
| Push notifications | N/A | ✗ Absent by design |
| Idle anonymity | ✓ Full | ⚠ Reduced |
| Physical security | ✓ Desktop | ⚠ Portable device |
| IPC security | ✓ Local pipes | ⚠ Platform-dependent |
| Screen capture | N/A (terminal) | ⚠ Possible |

**Bottom line:** The mobile client is a convenience layer. The
desktop CLI provides strictly stronger security guarantees. If
your threat model includes state-level adversaries, use the CLI
on a dedicated machine.
