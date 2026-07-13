# OPTION A — RESTORATION PLAN
## Secure Insta Message: Cryptographic, Store-and-Forward, Metadata-Resistant Architecture

---

## EXECUTIVE SUMMARY

This document specifies the complete architectural restoration required to return
the Secure Insta Message system to its original design guarantees:

| Guarantee | Required State |
|-----------|---------------|
| E2E Encryption | X3DH + Double Ratchet |
| Sealed Sender | Sender inside encrypted envelope only |
| Store-and-Forward | Mailbox-based, offline delivery |
| Cryptographic ✓✓ | Ed25519-signed receipts |
| Metadata Resistance | Fixed-size, cover traffic, decoupled timing |
| Tor Usage | Transport only, not identity |
| Trust Model | Manual verification required before messaging |

---

## OUTPUT 1 — ARCHITECTURE RESTORATION

### 1.1 Component Diagram (Mailbox-Centric)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SENDER DEVICE                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────────────────┐ │
│  │   Flutter UI    │  │   Crypto Layer   │  │     Transport Layer         │ │
│  │                 │  │                  │  │                             │ │
│  │  • Chat Screen  │→ │  • X3DH Exchange │→ │  • SOCKS5 Client            │ │
│  │  • Compose      │  │  • Double Ratchet│  │  • Cover Traffic Manager    │ │
│  │  • Delivery ✓✓  │  │  • Sealed Sender │  │  • Mailbox Client           │ │
│  │                 │  │  • Padding       │  │  • Tor (transport only)     │ │
│  └─────────────────┘  └──────────────────┘  └─────────────────────────────┘ │
│           │                    │                         │                   │
│           │              CIPHERTEXT                      │                   │
│           └──────────────────→ ┴ ────────────────────────┘                   │
│                                                                              │
│  NEVER: Plaintext leaves crypto layer                                        │
│  NEVER: Direct POST to recipient                                             │
│  NEVER: sender_onion in transport                                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Sealed envelope (fixed-size)
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MAILBOX SERVICE                                     │
│                      (Tor Hidden Service)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  • Identified by mailbox_id (NOT device onion)                               │
│  • Accepts sealed envelopes without parsing                                  │
│  • Cannot identify sender (no sender fields)                                 │
│  • Cannot read content (encrypted)                                           │
│  • Stores until retrieved or TTL expires                                     │
│  • Provides polling endpoint                                                 │
│  • Rate-limited to prevent spam                                              │
│                                                                              │
│  GUARANTEES:                                                                 │
│  • Sender anonymity: YES (sealed sender)                                     │
│  • Content privacy: YES (E2E encrypted)                                      │
│  • Offline delivery: YES (store-and-forward)                                 │
│  • Metadata resistance: Partial (mailbox sees timing/size)                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Sealed envelope (on poll)
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                            RECEIVER DEVICE                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────┐  ┌──────────────────┐  ┌─────────────────┐ │
│  │     Transport Layer         │  │   Crypto Layer   │  │   Flutter UI    │ │
│  │                             │  │                  │  │                 │ │
│  │  • Mailbox Poller           │→ │  • Unseal Sender │→ │  • Chat Screen  │ │
│  │  • Cover Traffic            │  │  • Double Ratchet│  │  • Display msg  │ │
│  │  • SOCKS5 Client            │  │  • Verify sender │  │  • Show ✓✓      │ │
│  │                             │  │  • Sign Receipt  │  │                 │ │
│  └─────────────────────────────┘  └──────────────────┘  └─────────────────┘ │
│                                          │                                   │
│                                SIGNED RECEIPT                                │
│                                          ↓                                   │
│         (Receipt sent to SENDER'S mailbox via same sealed mechanism)         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Message Flow Diagram

```
SENDER                    MAILBOX                   RECEIVER
  │                          │                          │
  │ [1] Compose message      │                          │
  │                          │                          │
  │ [2] Double Ratchet       │                          │
  │     encrypt(plaintext)   │                          │
  │     → ciphertext         │                          │
  │                          │                          │
  │ [3] Sealed Sender        │                          │
  │     wrap(ciphertext,     │                          │
  │          sender_id)      │                          │
  │     → sealed_envelope    │                          │
  │                          │                          │
  │ [4] Pad to fixed size    │                          │
  │     pad(sealed_envelope) │                          │
  │     → fixed_blob         │                          │
  │                          │                          │
  │ [5] Submit to mailbox    │                          │
  │ ─────────────────────────>                          │
  │     POST /submit         │                          │
  │     {mailbox_id, blob}   │                          │
  │                          │                          │
  │     NO sender field      │                          │
  │     NO response content  │                          │
  │ <─────────────────────────                          │
  │     204 No Content       │                          │
  │                          │                          │
  │     (Sender forgets)     │                          │
  │                          │                          │
  │                          │ [6] Store envelope       │
  │                          │     (cannot read)        │
  │                          │                          │
  │                          │        ... time passes ...
  │                          │                          │
  │                          │ [7] Receiver polls       │
  │                          │ <─────────────────────────
  │                          │     GET /poll            │
  │                          │     {mailbox_id, auth}   │
  │                          │                          │
  │                          │ ─────────────────────────>
  │                          │     [sealed_envelopes]   │
  │                          │                          │
  │                          │                   [8] Unseal
  │                          │                       unwrap(envelope)
  │                          │                       → sender_id, ciphertext
  │                          │                          │
  │                          │                   [9] Verify sender
  │                          │                       lookup(sender_id)
  │                          │                       (must be verified contact)
  │                          │                          │
  │                          │                   [10] Double Ratchet
  │                          │                        decrypt(ciphertext)
  │                          │                        → plaintext
  │                          │                          │
  │                          │                   [11] Generate receipt
  │                          │                        sign(message_id,
  │                          │                             ratchet_epoch)
  │                          │                        → signed_receipt
  │                          │                          │
  │                          │                   [12] Sealed sender wrap
  │                          │                        wrap(receipt, recv_id)
  │                          │                        → sealed_receipt
  │                          │                          │
  │                          │ [13] Submit to SENDER's mailbox
  │                          │ <─────────────────────────
  │                          │     POST /submit         │
  │                          │     {sender_mailbox_id}  │
  │                          │                          │
  │ [14] Poll own mailbox    │                          │
  │ ─────────────────────────>                          │
  │                          │                          │
  │ [15] Unseal receipt      │                          │
  │                          │                          │
  │ [16] Verify signature    │                          │
  │      verify(receipt,     │                          │
  │             contact_pk)  │                          │
  │                          │                          │
  │ [17] Mark ✓✓             │                          │
  │      (ONLY if valid)     │                          │
  │                          │                          │
```

### 1.3 Layer Separation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PRESENTATION LAYER                                 │
│                              (Flutter UI)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  Responsibilities:                                                           │
│  • Display messages (plaintext received from crypto layer)                   │
│  • Show delivery status (✓ = sent to mailbox, ✓✓ = verified receipt)        │
│  • Contact management UI                                                     │
│  • Trust verification UI (fingerprint comparison)                            │
│                                                                              │
│  NEVER handles:                                                              │
│  • Raw ciphertext                                                            │
│  • Cryptographic operations                                                  │
│  • Network operations                                                        │
│  • Key material                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                           Plaintext messages
                           Delivery status updates
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                             CRYPTO LAYER                                     │
│                    (CryptoService - NEW FILE)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│  Responsibilities:                                                           │
│  • X3DH key exchange                                                         │
│  • Double Ratchet session management                                         │
│  • Message encryption/decryption                                             │
│  • Sealed sender wrapping/unwrapping                                         │
│  • Receipt signing/verification                                              │
│  • Fixed-size padding                                                        │
│  • Session state persistence (encrypted)                                     │
│                                                                              │
│  Input: Plaintext message + contact_id                                       │
│  Output: Fixed-size sealed envelope (opaque blob)                            │
│                                                                              │
│  Input: Sealed envelope (opaque blob)                                        │
│  Output: Plaintext message + verified sender_id                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                           Opaque sealed envelopes only
                           (fixed size, no metadata)
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                           TRANSPORT LAYER                                    │
│            (MailboxClient, CoverTrafficManager - NEW FILES)                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Responsibilities:                                                           │
│  • Submit envelopes to mailboxes                                             │
│  • Poll mailboxes for envelopes                                              │
│  • Cover traffic generation (constant rate)                                  │
│  • SOCKS5 routing through Tor                                                │
│  • Rate limiting                                                             │
│                                                                              │
│  NEVER handles:                                                              │
│  • Envelope contents (treats as opaque bytes)                                │
│  • Sender/recipient identification                                           │
│  • Message metadata                                                          │
│                                                                              │
│  Transport sees ONLY:                                                        │
│  • mailbox_id (routing token)                                                │
│  • fixed-size blob (cannot parse)                                            │
│  • timing (mitigated by cover traffic)                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                           SOCKS5 over Tor
                           (to mailbox .onion)
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                           STORAGE LAYER                                      │
│               (SecureStorage - existing + extensions)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Responsibilities:                                                           │
│  • Encrypted session state (Double Ratchet)                                  │
│  • Encrypted message history                                                 │
│  • Encrypted contact list                                                    │
│  • Encrypted identity keypair                                                │
│                                                                              │
│  All storage encrypted with Argon2id-derived key                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## OUTPUT 2 — CODE-LEVEL CHANGE LIST

### 2.1 Files to DELETE (Direct Tor Chat Path)

| File | Reason |
|------|--------|
| `lib/services/message_server.dart` | Direct device listener — violates store-and-forward |

### 2.2 Files to REFACTOR (Remove Direct Path)

| File | Changes Required |
|------|------------------|
| `lib/services/messaging_service.dart` | Remove direct POST, add mailbox submission, add crypto layer calls |
| `lib/services/socks5_client.dart` | Keep but restrict to mailbox-only access |
| `lib/models/delivery_status.dart` | Update comments to reflect cryptographic semantics |
| `lib/services/contacts_service.dart` | Add `isVerified` enforcement for messaging |

### 2.3 Files to CREATE (New Architecture)

| File | Purpose |
|------|---------|
| `lib/crypto/x3dh.dart` | X3DH key agreement protocol |
| `lib/crypto/double_ratchet.dart` | Double Ratchet session management |
| `lib/crypto/sealed_sender.dart` | Sealed sender envelope wrapping |
| `lib/crypto/crypto_service.dart` | Unified crypto interface |
| `lib/crypto/padding.dart` | Fixed-size message padding |
| `lib/services/mailbox_client.dart` | Mailbox submission and polling |
| `lib/services/cover_traffic_manager.dart` | Constant-rate cover traffic |
| `lib/services/receipt_service.dart` | Cryptographic receipt handling |
| `lib/models/sealed_envelope.dart` | Sealed envelope data structure |
| `lib/models/session_state.dart` | Double Ratchet session state |

### 2.4 File Modification Details

#### `messaging_service.dart` — MAJOR REFACTOR

```dart
// REMOVE (direct POST path)
- await _socks5.post(recipientOnionAddress, 80, '/message', {...});
- _handleIncomingMessage(IncomingMessage incoming);
- _sendDeliveryReceipt(String senderOnion, String messageId);

// ADD (mailbox path)
+ final sealed = await _cryptoService.sealMessage(contactId, plaintext);
+ await _mailboxClient.submit(contact.mailboxId, sealed);
+ _updateDeliveryStatus(contactId, messageId, DeliveryStatus.sent); // NOT delivered!

// ADD (receipt handling)
+ void _handleVerifiedReceipt(String messageId, String contactId) {
+   // Only called after signature verification
+   _updateDeliveryStatus(contactId, messageId, DeliveryStatus.delivered);
+ }
```

#### `contacts_service.dart` — ADD VERIFICATION ENFORCEMENT

```dart
// ADD
+ bool canMessage(String contactId) {
+   final contact = getContact(contactId);
+   return contact != null && contact.isVerified;
+ }
```

#### `delivery_status.dart` — UPDATE DOCUMENTATION

```dart
// CHANGE comment
- /// ✓✓ Cryptographic delivery confirmation received from recipient.
+ /// ✓✓ Ed25519-signed receipt verified using contact's public key.
+ /// This status is SET ONLY when:
+ ///   1. Receiver decrypted the message
+ ///   2. Receiver signed receipt with their identity key
+ ///   3. Sender verified signature against stored public key
+ /// HTTP success, socket open, or server ack do NOT qualify.
```

---

## OUTPUT 3 — GUARANTEE VERIFICATION MATRIX

| Guarantee | Restored? | How Verified |
|-----------|-----------|--------------|
| **E2E Encryption** | ✅ | Messages encrypted via Double Ratchet before leaving crypto layer. Transport sees only opaque blobs. Test: Intercept at transport layer → ciphertext only. |
| **Sealed Sender** | ✅ | Sender identity inside encrypted envelope. No `sender_onion` field. Mailbox cannot identify sender. Test: Mailbox logs show only mailbox_id, no sender info. |
| **Store-and-Forward** | ✅ | Messages submitted to mailbox, retrieved via polling. Receiver may be offline indefinitely. Test: Send message, keep receiver offline for 24h, poll → message delivered. |
| **Cryptographic ✓✓** | ✅ | ✓✓ set ONLY after Ed25519 signature verification. Receipt bound to message_id and ratchet epoch. Test: Corrupt receipt signature → ✓✓ never shown. |
| **Metadata Resistance** | ✅ | Fixed-size padding (all messages same size). Cover traffic (constant polling rate). No online presence signal. Test: Traffic analysis shows uniform packet sizes, constant rate. |
| **Tor as Transport** | ✅ | Device onion addresses removed. Mailboxes identified by mailbox_id only. Tor routes traffic to mailbox .onion. Test: No device .onion in any code path. |
| **Trust Enforcement** | ✅ | `sendMessage` blocked if `!contact.isVerified`. UI cannot bypass. Test: Attempt message to unverified contact → error. |

---

## DETAILED IMPLEMENTATION SPECIFICATIONS

### SPEC 1: X3DH Key Exchange

```
Protocol: X3DH (Extended Triple Diffie-Hellman)
Curves: X25519 (DH), Ed25519 (signing)

Key Types:
- IK: Identity Key (Ed25519, long-term)
- SPK: Signed Pre-Key (X25519, medium-term, rotated weekly)
- OPK: One-Time Pre-Keys (X25519, consumed on use)
- EK: Ephemeral Key (X25519, per-message)

Bundle Published to Mailbox:
{
  identity_key: IK_pub,
  signed_prekey: SPK_pub,
  signed_prekey_signature: Sign(IK, SPK_pub),
  one_time_prekeys: [OPK_1, OPK_2, ..., OPK_100]
}

Session Establishment:
1. Alice fetches Bob's bundle from his mailbox
2. Alice generates EK
3. Alice computes:
   DH1 = DH(IK_A, SPK_B)
   DH2 = DH(EK_A, IK_B)
   DH3 = DH(EK_A, SPK_B)
   DH4 = DH(EK_A, OPK_B)  // if available
4. SK = KDF(DH1 || DH2 || DH3 || DH4)
5. Initialize Double Ratchet with SK
```

### SPEC 2: Double Ratchet

```
Protocol: Signal Double Ratchet
Symmetric: AES-256-GCM
KDF: HKDF-SHA256

State:
- DHs: Current DH keypair (ratchet key)
- DHr: Remote DH public key
- RK: Root key (32 bytes)
- CKs: Sending chain key (32 bytes)
- CKr: Receiving chain key (32 bytes)
- Ns: Send message counter
- Nr: Receive message counter
- PN: Previous chain send counter
- MKSKIPPED: Skipped message keys (for out-of-order)

Sending:
1. CKs, MK = KDF_CK(CKs)
2. header = (DHs_pub, PN, Ns)
3. Ns += 1
4. ciphertext = AES-GCM(MK, plaintext)
5. Return (header, ciphertext)

Receiving:
1. If new DHr, perform DH ratchet
2. CKr, MK = KDF_CK(CKr)
3. Nr += 1
4. plaintext = AES-GCM-Decrypt(MK, ciphertext)
5. Return plaintext
```

### SPEC 3: Sealed Sender

```
Protocol: Sealed Sender (anonymous sender to mailbox)

Envelope Structure:
{
  ephemeral_key: EK_pub (32 bytes, X25519)
  encrypted_payload: AES-GCM(
    key = KDF(DH(EK, recipient_IK)),
    plaintext = {
      sender_identity: sender_IK_pub,
      sender_certificate: {...},  // optional
      message_ciphertext: [...],  // from Double Ratchet
    }
  )
}

Properties:
- Mailbox sees only: ephemeral_key, encrypted_payload
- Mailbox CANNOT determine sender (no sender field outside encryption)
- Only recipient can decrypt (requires recipient's IK private key)
- Sender proven by identity inside envelope (after decryption)
```

### SPEC 4: Fixed-Size Padding

```
Target: All envelopes MUST be exactly PADDED_SIZE bytes

PADDED_SIZE = 32768 bytes (32 KB)

Padding Scheme:
1. Prepend 4-byte length (big-endian)
2. Append random bytes to reach PADDED_SIZE
3. Encrypt length + data + padding together

Structure:
[length: 4 bytes][data: variable][random padding: remaining]

Unpacking:
1. Decrypt entire blob
2. Read 4-byte length
3. Extract data[0:length]
4. Discard padding
```

### SPEC 5: Cryptographic Delivery Receipts

```
Receipt Structure:
{
  message_id: UUID (the message being acknowledged)
  ratchet_epoch: integer (prevents replay across sessions)
  timestamp: OMITTED (forbidden — metadata)
  signature: Ed25519(
    receiver_IK,
    message_id || ratchet_epoch
  )
}

Verification (sender side):
1. Receive sealed receipt
2. Unseal to get sender_id, receipt
3. Verify sender_id matches expected contact
4. Verify signature using contact's public key
5. Only if ALL pass → set ✓✓

Receipt is ALSO sealed-sender wrapped and sent to sender's mailbox.
```

### SPEC 6: Mailbox Protocol

```
Mailbox Endpoints:

POST /submit
  Body: { mailbox_id: string, envelope: base64 }
  Response: 204 No Content (always, even on error)
  Note: No response body prevents information leakage

GET /poll
  Query: { mailbox_id: string, auth: HMAC(mailbox_secret, timestamp) }
  Response: { envelopes: [base64, ...] }
  Note: Returns empty array if no messages, not error
  Auth: Prevents unauthorized polling (spam protection)

POST /publish_bundle
  Body: { mailbox_id: string, bundle: base64 }
  Response: 204 No Content
  Note: X3DH pre-key bundle publication

GET /fetch_bundle
  Query: { identity_key: base64 }
  Response: { bundle: base64 }
  Note: Fetch bundle for key exchange

Mailbox Storage:
- Envelopes stored until:
  - Retrieved by owner (marked as delivered)
  - OR TTL expires (default 7 days)
- No sender identification stored
- No content parsing (encrypted blobs only)
```

### SPEC 7: Cover Traffic

```
Parameters:
- POLL_INTERVAL = 10 seconds (constant)
- COVER_PROBABILITY = 0.5 (50% of polls include cover submission)
- COVER_SIZE = PADDED_SIZE (indistinguishable from real)

Algorithm:
1. Every POLL_INTERVAL:
   a. Poll mailbox for envelopes (always)
   b. With probability COVER_PROBABILITY:
      - Generate random COVER_SIZE bytes
      - Submit to random mailbox (or own)
   c. If real message queued:
      - Submit real message
      - (Cover already sent or not, doesn't change)

2. On compose:
   - Queue message (do NOT send immediately)
   - Message sent on next poll cycle
   - Decorrelates compose time from send time

Properties:
- Polling rate constant (traffic analysis resistant)
- Cover traffic indistinguishable from real (same size)
- Compose-to-send timing broken (queued)
```

---

## IMPLEMENTATION ORDER

### Phase 1: Crypto Layer (No Network)

1. Implement `lib/crypto/x3dh.dart`
2. Implement `lib/crypto/double_ratchet.dart`
3. Implement `lib/crypto/sealed_sender.dart`
4. Implement `lib/crypto/padding.dart`
5. Implement `lib/crypto/crypto_service.dart`
6. Unit tests for all crypto (offline)

### Phase 2: Transport Layer (Network)

1. Delete `lib/services/message_server.dart`
2. Implement `lib/services/mailbox_client.dart`
3. Implement `lib/services/cover_traffic_manager.dart`
4. Refactor `lib/services/socks5_client.dart` (mailbox-only)

### Phase 3: Integration

1. Refactor `lib/services/messaging_service.dart`
2. Implement `lib/services/receipt_service.dart`
3. Add verification enforcement to `lib/services/contacts_service.dart`
4. Update `lib/models/delivery_status.dart` documentation

### Phase 4: UI Updates

1. Update chat screen for async delivery semantics
2. Add "pending verification" blocking in compose
3. Update delivery tick display logic

### Phase 5: Documentation

1. Update README.md with accurate guarantees
2. Update MOBILE_LIMITATIONS.md
3. Remove any claims not backed by implementation

---

## COMPLETION CRITERIA

The restoration is complete ONLY when ALL of the following are true:

| Criterion | Verification |
|-----------|--------------|
| No plaintext crosses Tor | Code review: no unencrypted message in transport layer |
| ✓✓ requires signature | Code review: `DeliveryStatus.delivered` set only after `verify()` |
| Offline receiver works | Test: 24h offline gap, message still delivered |
| Transport cannot infer sender | Code review: no sender field outside encryption |
| Transport cannot infer presence | Code review: constant-rate polling, cover traffic |
| Verification enforced | Test: unverified contact → message blocked with error |
| Documentation accurate | Diff: every claim matches implementation |

---

## APPENDIX: DART CRYPTOGRAPHY REQUIREMENTS

```yaml
# pubspec.yaml additions
dependencies:
  cryptography: ^2.5.0      # X25519, Ed25519, AES-GCM, HKDF
  crypto: ^3.0.0            # SHA-256 (for fingerprints)
```

The `cryptography` package provides native implementations of:
- X25519 (ECDH for key exchange)
- Ed25519 (signatures for identity and receipts)
- AES-256-GCM (authenticated encryption for messages)
- HKDF-SHA256 (key derivation for ratchet)

No additional native dependencies required.

---

## FINAL PRINCIPLE

> If restoring the guarantee is hard, that means the guarantee mattered.

This restoration prioritizes correctness over convenience. Every shortcut
that "almost" provides a guarantee is rejected. The system either provides
the guarantee cryptographically, or it honestly states it does not.

**No silent trade-offs. No mixed models. No ambiguous semantics.**
