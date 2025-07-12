
# Contributing to bitchat

Thank you for your interest in contributing to **bitchat**, a decentralized Bluetooth mesh chat app. Your help—whether it's code, documentation, design, bug reports, or suggestions—is valuable!

This guide will help you get started with contributing effectively and consistently.

---

## 📦 Getting Started

### Clone the Repository

```bash
git clone https://github.com/Diksha-3905/bitchat.git
cd bitchat
```

---

## 🚀 Setup & Build

### Option 1: Using XcodeGen (Recommended)

```bash
brew install xcodegen
xcodegen generate
open bitchat.xcodeproj
```

### Option 2: Swift Package Manager

```bash
open Package.swift
```

### Option 3: Manual Setup

1. Open Xcode and create a new iOS/macOS App.
2. Copy all Swift files from the `bitchat/` directory.
3. Set Bluetooth permissions in `Info.plist`.
4. Set the deployment target to iOS 16.0 or macOS 13.0.

---

## 🧠 Branch Naming Convention

Use this format:
```
<type>/<short-description>
```

**Examples:**
- `fix/crash-on-join`
- `feat/debug-mode`
- `docs/add-contributing-guide`
- `test/encryption-unit-tests`

---

## 🧪 How to Contribute

### 1. Fork the repository

Click the **Fork** button on the top right.

### 2. Create a new branch

```bash
git checkout -b feat/your-feature-name
```

### 3. Make your changes

Add or edit code, documentation, tests, or configs.

### 4. Commit your changes

```bash
git add .
git commit -m "feat: add debug command for peer tracking"
```

### 5. Push to your fork

```bash
git push origin feat/your-feature-name
```

### 6. Open a Pull Request

Go to your fork on GitHub and click **“Compare & pull request.”**  
Include:
- A clear title and description of your changes
- Screenshots if applicable
- Linked issues (e.g., `Closes #5`)

---

## 💬 Opening Issues

Before opening an issue:
- Search the [Issues tab](../../issues) to avoid duplicates.
- If it's a new bug or feature request, include:
  - A clear title and summary
  - Steps to reproduce (if a bug)
  - Expected vs actual behavior
  - Logs, screenshots, or videos if helpful

---

## 🧼 Code Formatting & Style

### Swift Formatting

Use `swiftformat` to auto-format code:

```bash
brew install swiftformat
swiftformat .
```

### SwiftLint (optional)

```bash
brew install swiftlint
swiftlint
```

Follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/).

---

## 🔐 Security Contributions

This project uses cryptographic algorithms. If your contribution affects:

- X25519 key exchange
- AES-256-GCM encryption
- Ed25519 signature verification
- Argon2id password derivation

Then please:

- Include test coverage for those changes
- Describe your cryptographic reasoning in the PR

---

## 🔍 Suggested Contribution Areas

- Improve Bluetooth scanning or relay efficiency
- Add new commands (`/debug`, `/uptime`, `/ping`)
- Draft the `WHITEPAPER.md` with protocol details
- Add screenshots or GIFs to the README
- Create an Android-compatible client stub
- Improve installation/setup scripts
- Write unit tests for encryption, relay, or message store

---

## 👀 Code Reviews

At the moment, there may not be full-time maintainers. If active maintainers are listed, you can @mention them on your pull request.

Otherwise, PRs are reviewed on a rolling basis. Be patient and feel free to politely follow up if needed.

---

## 🙌 Thank You

Your contributions make **bitchat** better for everyone!  
Whether it's a single typo fix or a new feature — it matters.  
Together, we're building a privacy-first, serverless communication network.

Happy hacking! 🚀
