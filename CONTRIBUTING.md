# Contributing to BitChat

Thank you for your interest in contributing to BitChat! This guide will help you get started with contributing to our decentralized, privacy-focused messaging application.

## 🎯 What is BitChat?

BitChat is a decentralized peer-to-peer messaging app with dual transport architecture:
- **Bluetooth Mesh Network**: Local offline communication
- **Nostr Protocol**: Global internet-based messaging
- **Noise Protocol**: End-to-end encryption
- **Location-Based Channels**: Geographic chat rooms

## 🚀 Getting Started

### Prerequisites

- **macOS**: For iOS/macOS development
- **Xcode**: Latest version from App Store
- **Homebrew**: For installing development tools
- **Git**: Version control

### Setup Development Environment

1. **Fork and Clone**
   ```bash
   git clone https://github.com/yourusername/Freechat.git
   cd Freechat
   ```

2. **Install Tools**
   ```bash
   brew install xcodegen just
   ```

3. **Generate Xcode Project**
   ```bash
   xcodegen generate
   open bitchat.xcodeproj
   ```

4. **Alternative Setup with Just**
   ```bash
   just run    # Sets up and runs from source
   just clean  # Restores original state
   ```

## 🔧 Areas to Contribute

### 🟢 Beginner-Friendly

- **Documentation**: Improve README, add tutorials, create user guides
- **UI/UX**: Polish SwiftUI interfaces, improve accessibility
- **Testing**: Write unit tests, improve test coverage
- **Localization**: Add support for multiple languages
- **Error Handling**: Better user-friendly error messages

### 🟡 Intermediate

- **New Features**: Implement privacy enhancements, add new message types
- **Performance**: Optimize Bluetooth mesh networking, improve battery life
- **Security**: Audit encryption implementation, add security features
- **Platform Support**: Help port to Android, web, or other platforms

### 🔴 Advanced

- **Protocol Extensions**: Add new transport protocols, enhance mesh routing
- **Cryptography**: Implement post-quantum algorithms, improve Noise protocol
- **Architecture**: Refactor core components, improve modularity
- **Cross-Platform**: Create unified codebase for multiple platforms

## 🎯 Current Priority Areas

Based on our privacy assessment, these areas need immediate attention:

1. **Add optional coalesced READ behavior** for large backlogs
2. **Implement "low-visibility mode"** to reduce scanning aggressiveness
3. **User-configurable Nostr relay set** with "private relays only" toggle
4. **Enhanced logging controls** for different privacy levels

## 📝 Contribution Guidelines

### Code Style

- Follow existing Swift/SwiftUI patterns
- Use meaningful variable and function names
- Add comments for complex logic
- Follow Swift API Design Guidelines

### Testing

- Write tests for new features
- Ensure existing tests pass
- Test on both iOS and macOS
- Consider edge cases and error conditions

### Documentation

- Update relevant documentation
- Add inline code comments
- Update README if adding new features
- Document API changes

### Privacy First

- Always consider privacy implications
- Minimize metadata exposure
- Follow the principle of least privilege
- Test privacy features thoroughly

## 🔍 Finding Issues to Work On

1. **Check the Codebase**: Look for `TODO`, `FIXME`, or `HACK` comments
2. **Review Privacy Assessment**: Address recommendations in `docs/privacy-assessment.md`
3. **Test the App**: Use it and identify bugs or missing features
4. **Security Review**: Audit the Noise protocol implementation

## 📋 Pull Request Process

1. **Fork the Repository**: Create your own fork
2. **Create a Branch**: Use descriptive branch names
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make Changes**: Implement your feature or fix
4. **Test Thoroughly**: Ensure everything works on both platforms
5. **Commit Changes**: Use clear, descriptive commit messages
   ```bash
   git commit -m "feat: add low-visibility mode for privacy"
   ```
6. **Push and Create PR**: Submit your pull request
7. **Code Review**: Address feedback and iterate

### Commit Message Format

We use conventional commit format:
- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `style:` Code style changes
- `refactor:` Code refactoring
- `test:` Adding or updating tests
- `chore:` Maintenance tasks

## 🧪 Testing Your Changes

### Unit Tests
```bash
# Run all tests
xcodebuild test -project bitchat.xcodeproj -scheme "bitchat (iOS)" -destination 'platform=iOS Simulator,name=iPhone 15'

# Run specific test target
xcodebuild test -project bitchat.xcodeproj -scheme "bitchatTests" -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Manual Testing
- Test on both iOS and macOS
- Test Bluetooth mesh functionality
- Test Nostr internet messaging
- Test privacy features
- Test error conditions

## 🐛 Reporting Issues

When reporting bugs, please include:

- **Device**: iOS/macOS version, device model
- **Steps**: Clear steps to reproduce
- **Expected vs Actual**: What you expected vs what happened
- **Logs**: Any relevant error messages or logs
- **Privacy Impact**: If the issue affects privacy

## 💡 Feature Requests

For feature requests:

- **Use Case**: Describe the problem you're solving
- **Privacy Impact**: How does this affect user privacy?
- **Implementation**: Any thoughts on how to implement?
- **Alternatives**: Are there existing solutions?

## 🤝 Getting Help

- **GitHub Issues**: For bugs and feature requests
- **Discussions**: For questions and ideas
- **Code Review**: Ask questions in PR reviews
- **Documentation**: Check existing docs first

## 🏆 Recognition

Contributors are recognized in:
- Project README
- Release notes
- Contributor hall of fame
- Special thanks in documentation

## 📚 Learning Resources

- **Swift Documentation**: [developer.apple.com/swift](https://developer.apple.com/swift/)
- **SwiftUI Tutorials**: [developer.apple.com/tutorials/swiftui](https://developer.apple.com/tutorials/swiftui)
- **Noise Protocol**: [noiseprotocol.org](http://www.noiseprotocol.org/)
- **Nostr Protocol**: [github.com/nostr-protocol/nostr](https://github.com/nostr-protocol/nostr)
- **Bluetooth LE**: [developer.apple.com/bluetooth](https://developer.apple.com/bluetooth/)

## 🎉 Thank You!

Thank you for contributing to BitChat! Your contributions help build tools for privacy, decentralization, and resilient communication. Whether you're fixing a small bug or implementing a major feature, every contribution makes a difference.

---

**Remember**: BitChat is released into the public domain. By contributing, you're helping create tools that can work in protests, disasters, remote areas, and anywhere people need private, decentralized communication.

Happy coding! 🚀
