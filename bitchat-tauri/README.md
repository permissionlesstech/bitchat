# BitChat - Quantum-Resistant Decentralized Messaging

BitChat is a revolutionary peer-to-peer messaging application that operates over Bluetooth LE mesh networks with comprehensive quantum-resistant security. Built with Rust and Tauri, it provides secure, decentralized communication without requiring internet connectivity or central servers.

## Features

### Core Functionality
- **Decentralized Mesh Networking**: Bluetooth LE mesh for peer-to-peer communication
- **End-to-End Encryption**: Noise Protocol XX pattern for secure messaging
- **Channel Support**: Password-protected group channels with encryption
- **Offline Operation**: No internet or cellular connection required
- **Cross-Platform**: Desktop support via Tauri framework

### Security Architecture
- **Post-Quantum Cryptography**: ML-KEM-768 and Falcon-512/1024 algorithms
- **File Protection**: Tamper detection and integrity verification
- **Threat Analysis**: STRIDE framework for security monitoring
- **Audit Logging**: Immutable security event chronicles
- **Hybrid Cryptography**: Classical + post-quantum protection

### Advanced Security Suite
- **Quantum-Resistant Engine**: NIST-standardized post-quantum algorithms
- **File Protection Service**: Self-protecting application with tamper detection
- **Threat Analyzer**: Real-time security monitoring with STRIDE methodology
- **Security Auditor**: Comprehensive audit trails with compliance reporting
- **Emergency Response**: Automated lockdown and threat mitigation

## Quick Start

### Prerequisites
- Rust (latest stable)
- Node.js (for Tauri)
- Bluetooth LE capability

### Installation

```bash
# Clone the repository
git clone https://github.com/permissionlesstech/bitchat/bitchat-tauri.git
cd bitchat-tauri

# Install dependencies
npm install

# Run in development mode
cargo tauri dev
```

### Building for Production

```bash
# Build the application
cargo tauri build
```

## Architecture

### Module Structure

```
src/
├── main.rs                 # Tauri application entry point
├── bluetooth/              # Bluetooth LE mesh networking
│   ├── mesh_service.rs     # Core mesh service
│   ├── peer_manager.rs     # Peer discovery and management
│   └── protocol.rs         # BitChat protocol implementation
├── crypto/                 # Cryptographic systems
│   ├── noise_protocol.rs   # Noise XX implementation
│   ├── channel_crypto.rs   # Channel encryption
│   └── enhanced_crypto.rs  # Advanced cryptography
├── security/               # Quantum-resistant security suite
│   ├── pqc_engine.rs      # Post-quantum cryptography
│   ├── file_protection.rs # File integrity and protection
│   ├── threat_analysis.rs # STRIDE threat modeling
│   ├── audit_system.rs    # Security audit logging
│   └── hybrid_crypto.rs   # Classical + PQC integration
├── message/               # Message handling
│   ├── message_types.rs   # Message data structures
│   ├── router.rs          # Message routing logic
│   └── storage.rs         # Message persistence
└── ui_state/              # User interface state
    ├── chat_state.rs      # Chat interface state
    └── preferences.rs     # User preferences
```

### Security Features

#### Post-Quantum Cryptography
- **ML-KEM-768**: NIST-standardized key encapsulation mechanism
- **Falcon-512/1024**: Digital signature algorithms
- **Algorithm Discovery**: Automatic capability detection
- **Performance Benchmarking**: Real-time algorithm optimization

#### File Protection
- **Tamper Detection**: Cryptographic integrity verification
- **Self-Protection**: Application files automatically protected
- **Seal Creation**: Immutable protection records
- **Threat Response**: Automatic protection escalation

#### Threat Analysis
- **STRIDE Framework**: Comprehensive threat modeling
- **Real-Time Monitoring**: Continuous security assessment
- **Alert Escalation**: Automatic threat level management
- **Incident Tracking**: Complete threat lifecycle management

## Usage

### Basic Messaging
1. Launch BitChat on multiple devices with Bluetooth enabled
2. Devices automatically discover nearby peers
3. Send messages through the decentralized mesh network
4. Messages route through intermediate peers when needed

### Channel Creation
1. Create password-protected channels for group communication
2. Share channel passwords through secure out-of-band methods
3. All channel messages are automatically encrypted
4. Channel membership is managed through peer announcements

### Security Management
1. Security suite initializes automatically on startup
2. View security status through application interface
3. Emergency lockdown available for threat response
4. Audit logs track all security events

## Technical Specifications

### Networking
- **Protocol**: Bluetooth Low Energy 4.0+
- **Range**: 30-100 meters per hop
- **Mesh Topology**: Self-organizing peer-to-peer network
- **Message Routing**: TTL-based flood routing with deduplication

### Cryptography
- **End-to-End**: Noise Protocol XX pattern
- **Channel Encryption**: Password-based AES-256-GCM
- **Post-Quantum**: ML-KEM-768, Falcon-512/1024
- **Key Management**: Automatic rotation and derivation

### Performance
- **Connection Limit**: 8 concurrent peer connections
- **Message Size**: 512 bytes maximum payload
- **Throughput**: Limited by Bluetooth LE bandwidth
- **Latency**: 100ms-1s depending on mesh depth

## Development

### Adding Features
1. Follow AI Guidance Protocol for ethical development
2. Implement security-first design principles
3. Add comprehensive error handling
4. Include audit logging for security events

### Testing
```bash
# Run unit tests
cargo test

# Run integration tests
cargo test --test integration

# Check code quality
cargo clippy
cargo fmt
```

### Contributing
1. Fork the repository
2. Create feature branch following security guidelines
3. Implement with comprehensive error handling
4. Add tests and documentation
5. Submit pull request with security review

## Legal and Compliance

### Regulatory Compliance
- **Export Controls**: Post-quantum cryptography subject to export regulations
- **Privacy Laws**: GDPR/CCPA compliant data handling
- **Telecommunications**: May require regulatory approval in some jurisdictions
- **Cryptography**: Uses only approved algorithms and implementations

### Security Disclaimers
- **Prototype Status**: Current implementation is for demonstration purposes
- **Security Review**: Production use requires independent security audit
- **Quantum Readiness**: Post-quantum algorithms provide future protection
- **Mesh Limitations**: Security depends on honest peer participation

### User Responsibilities
- **Key Management**: Users responsible for secure key storage
- **Channel Passwords**: Secure password sharing is user responsibility
- **Device Security**: Physical device security affects overall system security
- **Update Management**: Regular security updates are critical

## Post-Quantum Cryptography Compliance

BitChat implements NIST-standardized post-quantum cryptographic algorithms to provide protection against future quantum computer attacks. This forward-looking security ensures long-term message confidentiality and integrity.

### Supported Algorithms
- **ML-KEM-768** (Module Lattice-Based Key Encapsulation Mechanism)
- **Falcon-512/1024** (Fast Fourier Lattice-based Compact Signatures)

### Compliance Standards
- NIST Post-Quantum Cryptography Standardization
- FIPS 140-2 Level 1 equivalent (when available)
- Common Criteria evaluation ready

### Migration Strategy
- Hybrid classical + post-quantum implementation
- Gradual migration path from classical algorithms
- Backward compatibility during transition period
- Performance optimization for resource-constrained devices

## Support

### Documentation
- Technical specifications in `/docs` directory
- API documentation via `cargo doc`
- Security analysis reports available
- Architecture decision records maintained

### Community
- GitHub Issues for bug reports
- Security vulnerabilities via responsible disclosure
- Feature requests through community discussion
- Development coordination through project channels

### Professional Support
- Security consulting available for enterprise deployment
- Custom implementation services for specialized requirements
- Regulatory compliance assistance for commercial use
- Training and education programs for development teams

## License

BitChat is licensed under the MIT License. See LICENSE file for details.

Post-quantum cryptographic implementations may be subject to additional licensing terms and export control regulations.

---

**Security Notice**: This implementation includes experimental post-quantum cryptography. While based on NIST-standardized algorithms, the implementation should undergo independent security review before production deployment.

**Regulatory Notice**: Use of cryptographic software may be restricted in some jurisdictions. Users are responsible for compliance with applicable laws and regulations.