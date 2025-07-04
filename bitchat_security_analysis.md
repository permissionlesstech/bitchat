# BitChat Security and Encryption Analysis

## Executive Summary

BitChat is a Bluetooth mesh networking app that implements a mix of encrypted and unencrypted communications. While private messages are properly encrypted using Curve25519 and AES-GCM, public broadcast messages are sent in plaintext with optional signatures. The app has several security strengths but also notable vulnerabilities that could compromise user privacy and security.

## 1. Message Encryption

### 1.1 Encrypted Messages
- **Private Messages**: Properly encrypted using Curve25519 key agreement and AES-GCM
  - Uses ephemeral key pairs for forward secrecy
  - Implements proper authenticated encryption (AEAD)
  - Encrypted payload includes the full message content

### 1.2 Unencrypted Messages  
- **Public/Broadcast Messages**: Sent in **PLAINTEXT**
  - Message content, sender nickname, timestamps are all visible
  - Only protected by optional signatures (not encryption)
  - Anyone within Bluetooth range can read these messages
- **Announce Messages**: Sent in plaintext containing nicknames
- **Key Exchange Messages**: Public keys sent in plaintext (this is acceptable)

### 1.3 Partially Protected Data
- **Fragments**: Large messages are fragmented but fragments themselves are not encrypted unless the original message was private
- **Metadata**: TTL, timestamps, sender/recipient IDs are always in plaintext

## 2. Key Management

### 2.1 Key Types
The app uses three types of keys per peer:
1. **Ephemeral Encryption Key** (Curve25519 KeyAgreement) - Changes each session
2. **Ephemeral Signing Key** (Curve25519 Signing) - Changes each session  
3. **Persistent Identity Key** (Curve25519 Signing) - Stored in UserDefaults

### 2.2 Key Exchange Process
```
1. On connection, peers exchange 96 bytes containing:
   - 32 bytes: Ephemeral encryption public key
   - 32 bytes: Ephemeral signing public key
   - 32 bytes: Persistent identity public key

2. Shared secrets are derived using HKDF with:
   - Salt: "bitchat-v1"
   - Info: empty
   - Output: 32-byte symmetric key for AES-GCM
```

### 2.3 Key Storage Vulnerabilities
- **Persistent identity keys** stored in UserDefaults (not secure storage)
- No key rotation mechanism for persistent keys
- No key expiration or revocation support
- Ephemeral keys provide forward secrecy but are lost on app restart

## 3. Authentication & Signatures

### 3.1 Message Authentication
- Messages can be signed using ephemeral signing keys
- Signatures use Curve25519 (Ed25519) - cryptographically strong
- **CRITICAL ISSUE**: Signatures are optional, not mandatory
  - Broadcast messages often sent without signatures
  - No enforcement of signature verification

### 3.2 Identity Verification
- No mechanism to verify persistent identity keys
- Peer IDs are random 8-character hex strings (ephemeral per session)
- Nicknames are self-assigned and not authenticated
- **Impersonation Risk**: Anyone can claim any nickname

### 3.3 Anti-Replay Protection
- Basic timestamp validation (5-minute window)
- Message deduplication based on timestamp + sender ID
- **Weakness**: Deduplication cache cleared after 1000 messages

## 4. Privacy Analysis

### 4.1 Metadata Exposure
The following metadata is **always exposed** in plaintext:
- Message type (broadcast, private, announce, etc.)
- Timestamp (exact time of message)
- TTL (time-to-live) value
- Sender ID (8-character ephemeral ID)
- Recipient ID (for private messages)
- Message exists (traffic analysis possible)

### 4.2 User Tracking
- **Session Tracking**: Ephemeral peer IDs change per session (good)
- **Long-term Tracking**: Persistent identity keys enable tracking favorites across sessions
- **Nickname Tracking**: Self-assigned nicknames can be tracked
- **RSSI Tracking**: Signal strength logged, enabling location tracking

### 4.3 Traffic Analysis Vulnerabilities
- Message sizes not padded (reveals content length)
- Timing patterns not obscured
- Relay behavior reveals network topology
- Fragment reassembly reveals large message senders

## 5. Security Vulnerabilities

### 5.1 MITM (Man-in-the-Middle) Attacks
- **Key Exchange Vulnerable**: No authentication during initial key exchange
- Anyone can intercept and replace public keys
- No certificate pinning or trust verification
- **Mitigation**: Only persistent identity keys provide some continuity

### 5.2 Replay Attack Protection
- **Partial Protection**: 5-minute timestamp window
- **Weakness**: Attacker can replay within window
- **Weakness**: Cache-based deduplication can be overwhelmed

### 5.3 Key Compromise Impact
- **Ephemeral Key Compromise**: Only affects current session
- **Identity Key Compromise**: Affects all future favorite communications
- **No Perfect Forward Secrecy** for identity-based communications

### 5.4 Message Integrity
- **Private Messages**: Protected by AES-GCM authentication tag
- **Public Messages**: Only protected if signed (optional)
- **Fragments**: No integrity protection during reassembly

### 5.5 Denial of Service
- No rate limiting on messages
- Fragment reassembly can consume memory
- Message cache can be filled with spam
- TTL-based flooding possible

## 6. Protocol-Specific Vulnerabilities

### 6.1 Binary Protocol Issues
- No protocol version negotiation
- Fixed-size fields can lead to truncation
- No extension mechanism for future security features

### 6.2 Bluetooth-Specific Risks
- BLE advertisements reveal app usage
- Connection attempts logged by OS
- RSSI measurements enable physical tracking
- No protection against Bluetooth protocol attacks

## 7. Implementation Issues

### 7.1 Cryptographic Issues
- Using SHA256 for fingerprints (should use key-specific hashing)
- No constant-time comparisons for signatures
- Error messages may leak timing information

### 7.2 Memory Safety
- Message cache stores decrypted content
- No secure memory wiping after use
- Crash dumps may contain sensitive data

## 8. Recommendations

### 8.1 Critical Fixes
1. **Encrypt all messages** including broadcasts
2. **Mandatory signatures** on all messages
3. **Authenticated key exchange** (e.g., using SMP or custom protocol)
4. **Secure key storage** using Keychain instead of UserDefaults

### 8.2 Privacy Enhancements
1. **Pad message sizes** to fixed buckets
2. **Add decoy traffic** to obscure patterns
3. **Randomize timing** of message relay
4. **Implement onion routing** for multi-hop messages

### 8.3 Security Improvements
1. **Add perfect forward secrecy** for all messages
2. **Implement key rotation** for long-term keys
3. **Add replay protection** with sequence numbers
4. **Rate limiting** to prevent DoS attacks

### 8.4 Protocol Enhancements
1. **Version negotiation** for protocol upgrades
2. **Capability advertisement** for feature discovery
3. **Extension fields** for future features
4. **Formal security audit** of protocol design

## 9. Threat Model Considerations

### 9.1 Local Adversary (Within Bluetooth Range)
- Can read all broadcast messages
- Can perform traffic analysis
- Can attempt MITM during key exchange
- Can track users via RSSI

### 9.2 Network Adversary (Multiple Nodes)
- Can correlate messages across the mesh
- Can map network topology
- Can perform timing correlation attacks
- Can identify high-value targets (favorites)

### 9.3 Persistent Adversary
- Can track users across sessions via identity keys
- Can build social graphs from message patterns
- Can perform long-term traffic analysis
- Can compromise stored keys from UserDefaults

## 10. Conclusion

BitChat implements basic encryption for private messages but has significant security and privacy vulnerabilities. The lack of encryption for broadcast messages, optional signatures, vulnerable key exchange, and metadata exposure make it unsuitable for high-security scenarios. While the app provides some protection against casual eavesdropping, it would not withstand targeted attacks by motivated adversaries.

For activist or high-risk use cases, the current implementation poses serious risks including:
- Message content exposure (broadcasts)
- User tracking and identification  
- Social graph analysis
- Physical location tracking via RSSI

Major architectural changes would be needed to provide adequate security for sensitive communications.