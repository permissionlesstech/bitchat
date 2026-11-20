//
// TerminalCLI.swift
// bitchat
//
// Native terminal (CLI) mode for macOS, backed by the full AppRuntime
// (two-way BLE mesh, Noise E2E private DMs, and Nostr fallback).
// Includes interactive slash-command & peer autosuggest when attached to a TTY.
//

#if os(macOS)
import AppKit
import BitFoundation
import Combine
import Darwin
import Foundation

// MARK: - Terminal Sanitization

enum TerminalSanitizer {
    /// Strips ANSI escape sequences and neutralizes control characters from
    /// untrusted text (e.g. remote messages, nicknames, geohashes) before
    /// writing it to the terminal so remote peers cannot inject control
    /// sequences or spoof prompts/status lines.
    static func sanitize(_ text: String, allowNewlines: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value

            // Strip ANSI escape sequences beginning with ESC (0x1B).
            if v == 0x1B {
                i += 1
                if i < scalars.count {
                    let next = scalars[i].value
                    if next == 0x5B { // CSI: ESC [ ... (0x40...0x7E)
                        i += 1
                        while i < scalars.count {
                            let c = scalars[i].value
                            i += 1
                            if c >= 0x40 && c <= 0x7E { break }
                        }
                    } else if next == 0x5D { // OSC: ESC ] ... (BEL or ESC \)
                        i += 1
                        while i < scalars.count {
                            let c = scalars[i].value
                            if c == 0x07 {
                                i += 1
                                break
                            }
                            if c == 0x1B, i + 1 < scalars.count, scalars[i + 1].value == 0x5C {
                                i += 2
                                break
                            }
                            i += 1
                        }
                    } else if next >= 0x40 && next <= 0x5F {
                        // Two-byte Fe escape sequence
                        i += 1
                    }
                }
                continue
            }

            // Strip C1 CSI (0x9B ... 0x40-0x7E).
            if v == 0x9B {
                i += 1
                while i < scalars.count {
                    let c = scalars[i].value
                    i += 1
                    if c >= 0x40 && c <= 0x7E { break }
                }
                continue
            }

            if v == 0x0A { // LF
                result.append(allowNewlines ? "\n" : " ")
                i += 1
                continue
            }
            if v == 0x09 { // TAB
                result.append(" ")
                i += 1
                continue
            }
            // Drop remaining C0 (including CR 0x0D), DEL (0x7F), and C1 (0x80...0x9F) control chars.
            if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
                i += 1
                continue
            }

            result.unicodeScalars.append(scalars[i])
            i += 1
        }
        return result
    }
}

// MARK: - Command Catalog & Autosuggest

struct TerminalCommandSpec: Equatable {
    let command: String
    let usage: String
    let summary: String
    let insertsTrailingSpace: Bool
}

struct TerminalSuggestion: Equatable {
    /// Full input string that replaces the current buffer when accepted with Tab.
    let completion: String
    /// Left column shown in the suggestion menu (e.g. `/dm <nick|id> [msg]` or `@alice`).
    let label: String
    /// Right column description shown in dim text.
    let detail: String
}

struct TerminalPeerEntry: Equatable {
    let name: String
    let peerID: String
    let status: String
}

enum TerminalPeerMatchResult<Peer> {
    case unique(Peer)
    case ambiguous([Peer])
    case none
}

enum TerminalCommandCatalog {
    static let commands: [TerminalCommandSpec] = [
        TerminalCommandSpec(
            command: "/peers",
            usage: "/peers",
            summary: "List discovered peers & transport status",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/w",
            usage: "/w",
            summary: "Alias for /peers",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/dm",
            usage: "/dm <nick|id> [msg]",
            summary: "Start Noise-encrypted private chat (or send a DM)",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/msg",
            usage: "/msg @<nick> <msg>",
            summary: "Send a one-off private DM",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/mesh",
            usage: "/mesh",
            summary: "Return to public #mesh chat",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/back",
            usage: "/back",
            summary: "Alias for /mesh",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/nick",
            usage: "/nick <name>",
            summary: "Change your nickname",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/who",
            usage: "/who",
            summary: "Show who is currently in the channel",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/slap",
            usage: "/slap @<nick>",
            summary: "Slap someone with a large trout",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/hug",
            usage: "/hug @<nick>",
            summary: "Send a warm hug",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/block",
            usage: "/block @<nick>",
            summary: "Block a peer",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/unblock",
            usage: "/unblock @<nick>",
            summary: "Unblock a peer",
            insertsTrailingSpace: true
        ),
        TerminalCommandSpec(
            command: "/clear",
            usage: "/clear",
            summary: "Clear current chat history",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/help",
            usage: "/help",
            summary: "Show available commands",
            insertsTrailingSpace: false
        ),
        TerminalCommandSpec(
            command: "/quit",
            usage: "/quit",
            summary: "Disconnect and exit",
            insertsTrailingSpace: false
        )
    ]

    /// Resolves a peer query against a list of peers, rejecting ambiguous matches
    /// instead of silently picking the first colliding peer.
    static func resolvePeer<Peer>(
        matching query: String,
        in peers: [Peer],
        names: (Peer) -> [String],
        peerID: (Peer) -> String
    ) -> TerminalPeerMatchResult<Peer> {
        let lower = query.lowercased()
        guard !lower.isEmpty else { return .none }

        // Exact peer ID match is always unique.
        let exactIDMatches = peers.filter { peerID($0).lowercased() == lower }
        if exactIDMatches.count == 1 { return .unique(exactIDMatches[0]) }
        if exactIDMatches.count > 1 { return .ambiguous(exactIDMatches) }

        // Exact nickname / petname match.
        let exactNameMatches = peers.filter { peer in
            names(peer).contains { $0.lowercased() == lower }
        }
        if exactNameMatches.count == 1 { return .unique(exactNameMatches[0]) }
        if exactNameMatches.count > 1 { return .ambiguous(exactNameMatches) }

        // Prefix match fallback across names and peer ID.
        let prefixMatches = peers.filter { peer in
            peerID(peer).lowercased().hasPrefix(lower) ||
            names(peer).contains { $0.lowercased().hasPrefix(lower) }
        }
        if prefixMatches.count == 1 { return .unique(prefixMatches[0]) }
        if prefixMatches.count > 1 { return .ambiguous(prefixMatches) }

        return .none
    }

    /// Computes live command and peer suggestions for the current input buffer.
    static func suggestions(
        for input: String,
        peers: [TerminalPeerEntry]
    ) -> [TerminalSuggestion] {
        guard input.hasPrefix("/") else { return [] }

        // Peer argument completion for `/dm <query>` or `/msg @<query>` / `/slap @<query>` etc.
        if let spaceIdx = input.firstIndex(of: " ") {
            let cmd = String(input[..<spaceIdx]).lowercased()
            let afterSpace = String(input[input.index(after: spaceIdx)...])
            // Only complete the first argument (no second space yet).
            guard !afterSpace.contains(" ") else { return [] }

            let peerCommands: Set<String> = ["/dm", "/msg", "/slap", "/hug", "/block", "/unblock"]
            guard peerCommands.contains(cmd) else { return [] }

            let useAtPrefix = cmd != "/dm"
            let rawQuery = afterSpace.hasPrefix("@") ? String(afterSpace.dropFirst()) : afterSpace
            let lowerQuery = rawQuery.lowercased()

            // Count duplicate display names so `/dm` disambiguates collisions using peer IDs.
            var nameCounts: [String: Int] = [:]
            for peer in peers {
                nameCounts[peer.name.lowercased(), default: 0] += 1
            }

            let matched = peers.filter { peer in
                lowerQuery.isEmpty ||
                peer.name.lowercased().hasPrefix(lowerQuery) ||
                peer.peerID.lowercased().hasPrefix(lowerQuery)
            }
            return matched.map { peer in
                let safeName = TerminalSanitizer.sanitize(peer.name)
                let safeID = TerminalSanitizer.sanitize(peer.peerID)
                let isDuplicateName = (nameCounts[peer.name.lowercased()] ?? 0) > 1
                let completionToken: String
                let label: String
                if useAtPrefix {
                    completionToken = "@\(safeName)"
                    label = "\(cmd) @\(safeName)"
                } else if isDuplicateName {
                    completionToken = safeID
                    label = "\(cmd) \(safeName) (\(safeID))"
                } else {
                    completionToken = safeName
                    label = "\(cmd) \(safeName)"
                }
                return TerminalSuggestion(
                    completion: "\(cmd) \(completionToken) ",
                    label: label,
                    detail: "\(peer.status) (\(safeID))"
                )
            }
        }

        // Slash-command completion (e.g. `/`, `/d`, `/pe`).
        let lower = input.lowercased()
        let prefixMatches = commands.filter { $0.command.hasPrefix(lower) }
        let substringMatches = commands.filter { !$0.command.hasPrefix(lower) && $0.command.contains(lower.dropFirst()) }
        let ordered = prefixMatches + (lower.count > 1 ? substringMatches : [])

        return ordered.map { spec in
            let completion = spec.insertsTrailingSpace ? "\(spec.command) " : spec.command
            return TerminalSuggestion(
                completion: completion,
                label: spec.usage,
                detail: spec.summary
            )
        }
    }
}

// MARK: - Raw-mode Termios State (Global for atexit safety)

private final class TermiosGuard {
    nonisolated(unsafe) static var original: termios?

    static func enableRawMode() -> Bool {
        // Require both stdin and stdout to be TTYs so redirected output
        // (e.g. `bitchat --cli >log`) doesn't disable terminal echo blindly.
        guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else { return false }
        var orig = termios()
        guard tcgetattr(STDIN_FILENO, &orig) == 0 else { return false }
        original = orig
        atexit {
            TermiosGuard.restore()
        }

        var raw = orig
        // Disable canonical line buffering and echo; handle Ctrl+C in our reader
        // while keeping OPOST enabled so \n still translates cleanly to \r\n.
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
        raw.c_iflag &= ~UInt(IXON | ICRNL)
        withUnsafeMutablePointer(to: &raw.c_cc) { ccPtr in
            ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buf in
                buf[Int(VMIN)] = 1
                buf[Int(VTIME)] = 0
            }
        }
        return tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0
    }

    static func restore() {
        guard var orig = original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &orig)
        original = nil
    }
}

// MARK: - Terminal CLI

@MainActor
final class TerminalCLI {
    private let runtime: AppRuntime
    private var cancellables = Set<AnyCancellable>()
    private var knownConnectedPeerIDs: Set<PeerID> = []
    private var printedMessageIDs: Set<String> = []
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var isShuttingDown = false

    // Interactive TTY editor state
    private var isInteractiveTTY = false
    private var inputChars: [Character] = []
    private var cursorIndex = 0
    private var suggestions: [TerminalSuggestion] = []
    private var selectedSuggestionIndex = 0
    private var menuDismissed = false
    private var history: [String] = []
    private var historyIndex: Int?
    private var savedDraftBeforeHistory = ""

    private let maxVisibleSuggestions = 6

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // ANSI color helpers
    private let reset = "\u{001B}[0m"
    private let dim = "\u{001B}[2m"
    private let bold = "\u{001B}[1m"
    private let green = "\u{001B}[32m"
    private let cyan = "\u{001B}[36m"
    private let magenta = "\u{001B}[35m"
    private let yellow = "\u{001B}[33m"

    private init() {
        self.runtime = AppRuntime()
    }

    static func run() {
        // Keep the app completely headless (no Dock icon, no window).
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let cli = TerminalCLI()
        cli.start()

        // Keep the main RunLoop alive for CoreBluetooth, Combine, and Nostr.
        RunLoop.main.run()
    }

    private func start() {
        installSignalHandlers()
        isInteractiveTTY = TermiosGuard.enableRawMode()

        bindObservers()
        runtime.start()

        let nick = TerminalSanitizer.sanitize(runtime.chatViewModel.nickname)
        let peerID = TerminalSanitizer.sanitize(runtime.chatViewModel.meshService.myPeerID.id)
        let hint = isInteractiveTTY
            ? "Type a message for #mesh, or / for live command suggestions (Tab to autocomplete, ↑/↓ to select)."
            : "Type a message to broadcast on #mesh, or /help for commands (/peers, /dm, /mesh, /quit)."
        printRaw("""
        \(bold)\(green)bitchat terminal\(reset) \(dim)(native BLE mesh + Noise E2E DMs + Nostr)\(reset)
        \(dim)you:\(reset) \(bold)\(nick)\(reset)  \(dim)peer:\(reset) \(peerID)
        \(dim)\(hint)\(reset)
        """)
        redrawInput()

        if isInteractiveTTY {
            startInteractiveInputLoop()
        } else {
            startPipedInputLoop()
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in self?.shutdown() }
        intSource.resume()
        sigintSource = intSource

        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in self?.shutdown() }
        termSource.resume()
        sigtermSource = termSource
    }

    private func bindObservers() {
        runtime.conversations.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self else { return }
                if case .appended(let conversationID, let message) = change {
                    self.handleAppendedMessage(conversationID: conversationID, message: message)
                }
            }
            .store(in: &cancellables)

        // Keep the prompt aligned with the store's selected conversation
        // (covers `/msg @nick`, `/dm`, `/mesh`, and rejected blocked peers).
        runtime.conversations.$selectedConversationID
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.redrawInput()
            }
            .store(in: &cancellables)

        runtime.chatViewModel.$allPeers
            .receive(on: RunLoop.main)
            .sink { [weak self] peers in
                guard let self else { return }
                let connected = peers.filter { $0.isConnected }
                let connectedIDs = Set(connected.map(\.peerID))

                for peer in connected where !self.knownConnectedPeerIDs.contains(peer.peerID) {
                    let name = TerminalSanitizer.sanitize(peer.localPetname ?? peer.nickname)
                    let safeID = TerminalSanitizer.sanitize(peer.peerID.id)
                    self.printLine("\(self.green)● peer connected:\(self.reset) \(self.bold)\(name)\(self.reset) \(self.dim)(\(safeID))\(self.reset)")
                }
                for oldID in self.knownConnectedPeerIDs where !connectedIDs.contains(oldID) {
                    let rawName = peers.first(where: { $0.peerID == oldID }).map { $0.localPetname ?? $0.nickname } ?? oldID.id
                    let name = TerminalSanitizer.sanitize(rawName)
                    let safeID = TerminalSanitizer.sanitize(oldID.id)
                    self.printLine("\(self.yellow)○ peer disconnected:\(self.reset) \(name) \(self.dim)(\(safeID))\(self.reset)")
                }
                self.knownConnectedPeerIDs = connectedIDs

                // Refresh live peer suggestions if the user is mid-typing `/dm ...`.
                if self.isInteractiveTTY, !self.suggestions.isEmpty || String(self.inputChars).hasPrefix("/") {
                    self.refreshSuggestions()
                    self.redrawInput()
                }
            }
            .store(in: &cancellables)
    }

    private func handleAppendedMessage(conversationID: ConversationID, message: BitchatMessage) {
        guard printedMessageIDs.insert(message.id).inserted else { return }

        let ts = timeFormatter.string(from: message.timestamp)
        let tag: String
        switch conversationID {
        case .mesh:
            tag = "\(cyan)[mesh]\(reset)"
        case .geohash(let gh):
            let safeGH = TerminalSanitizer.sanitize(gh)
            tag = "\(yellow)[#\(safeGH)]\(reset)"
        case .direct(let handle):
            let peerName = displayName(for: handle.routingPeerID)
            tag = "\(magenta)[DM \(peerName)]\(reset)"
        }

        let safeSender = TerminalSanitizer.sanitize(message.sender)
        let safeContent = TerminalSanitizer.sanitize(message.content, allowNewlines: true)

        if message.sender == "system" {
            printLine("\(dim)[\(ts)]\(reset) \(tag) \(dim)* \(safeContent)\(reset)")
        } else {
            let isSelf = runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID, displayName: message.sender)
            let senderColor = isSelf ? green : bold
            printLine("\(dim)[\(ts)]\(reset) \(tag) \(senderColor)\(safeSender)\(reset): \(safeContent)")
        }
    }

    private func displayName(for peerID: PeerID) -> String {
        if let peer = runtime.chatViewModel.allPeers.first(where: { $0.peerID == peerID }) {
            return TerminalSanitizer.sanitize(peer.localPetname ?? peer.nickname)
        }
        return TerminalSanitizer.sanitize(peerID.id)
    }

    // MARK: - Input Loops

    private func startPipedInputLoop() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async {
                    self?.handleSubmittedLine(line)
                }
            }
            DispatchQueue.main.async {
                self?.shutdown()
            }
        }
    }

    private enum KeyEvent: Sendable {
        case char(Character)
        case enter
        case tab
        case backspace
        case deleteForward
        case escape
        case up
        case down
        case left
        case right
        case home
        case end
        case ctrlC
        case ctrlD
        case ctrlU
        case ctrlW
    }

    private func startInteractiveInputLoop() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let event = Self.readNextKeyEvent() {
                DispatchQueue.main.async {
                    self?.handleKeyEvent(event)
                }
            }
            DispatchQueue.main.async {
                self?.shutdown()
            }
        }
    }

    nonisolated private static func readByte(timeoutMs: Int32? = nil) -> UInt8? {
        if let timeoutMs {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, timeoutMs)
            guard ready > 0 else { return nil }
        }
        var b: UInt8 = 0
        let n = Darwin.read(STDIN_FILENO, &b, 1)
        return n == 1 ? b : nil
    }

    nonisolated private static func readNextKeyEvent() -> KeyEvent? {
        guard let first = readByte() else { return nil }

        switch first {
        case 0x03: return .ctrlC
        case 0x04: return .ctrlD
        case 0x01: return .home
        case 0x05: return .end
        case 0x15: return .ctrlU
        case 0x17: return .ctrlW
        case 0x09: return .tab
        case 0x0D, 0x0A: return .enter
        case 0x7F, 0x08: return .backspace
        case 0x1B:
            guard let second = readByte(timeoutMs: 25) else { return .escape }
            guard second == 0x5B else { return .escape } // '['
            guard let third = readByte(timeoutMs: 25) else { return .escape }
            switch third {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            case 0x48: return .home
            case 0x46: return .end
            case 0x33:
                _ = readByte(timeoutMs: 25) // consume '~'
                return .deleteForward
            default:
                return .escape
            }
        default:
            // Ignore other non-printable control characters.
            if first < 0x20 { return readNextKeyEvent() }

            // Assemble multi-byte UTF-8 sequence if needed.
            var bytes: [UInt8] = [first]
            let expectedLength: Int
            if first & 0x80 == 0 {
                expectedLength = 1
            } else if first & 0xE0 == 0xC0 {
                expectedLength = 2
            } else if first & 0xF0 == 0xE0 {
                expectedLength = 3
            } else if first & 0xF8 == 0xF0 {
                expectedLength = 4
            } else {
                return readNextKeyEvent()
            }
            while bytes.count < expectedLength, let next = readByte(timeoutMs: 25) {
                bytes.append(next)
            }
            if let str = String(bytes: bytes, encoding: .utf8), let ch = str.first {
                return .char(ch)
            }
            return readNextKeyEvent()
        }
    }

    private func handleKeyEvent(_ event: KeyEvent) {
        switch event {
        case .ctrlC:
            shutdown()
            return

        case .ctrlD:
            if inputChars.isEmpty {
                shutdown()
                return
            }
            if cursorIndex < inputChars.count {
                inputChars.remove(at: cursorIndex)
                menuDismissed = false
                refreshSuggestions()
            }

        case .enter:
            let line = String(inputChars)
            // Clear suggestion menu and echo the submitted line cleanly.
            fputs("\r\u{001B}[J\(promptString())\(line)\n", stdout)
            fflush(stdout)

            inputChars.removeAll()
            cursorIndex = 0
            suggestions.removeAll()
            selectedSuggestionIndex = 0
            menuDismissed = false
            historyIndex = nil

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, history.last != trimmed {
                history.append(trimmed)
            }
            handleSubmittedLine(line)
            return

        case .tab:
            if !suggestions.isEmpty {
                let chosen = suggestions[selectedSuggestionIndex]
                inputChars = Array(chosen.completion)
                cursorIndex = inputChars.count
                menuDismissed = false
                refreshSuggestions()
            }

        case .escape:
            if !suggestions.isEmpty {
                menuDismissed = true
                suggestions.removeAll()
                selectedSuggestionIndex = 0
            }

        case .up:
            if !suggestions.isEmpty {
                selectedSuggestionIndex = (selectedSuggestionIndex - 1 + suggestions.count) % suggestions.count
            } else if !history.isEmpty {
                if let idx = historyIndex {
                    historyIndex = max(0, idx - 1)
                } else {
                    savedDraftBeforeHistory = String(inputChars)
                    historyIndex = history.count - 1
                }
                if let idx = historyIndex {
                    inputChars = Array(history[idx])
                    cursorIndex = inputChars.count
                    refreshSuggestions()
                }
            }

        case .down:
            if !suggestions.isEmpty {
                selectedSuggestionIndex = (selectedSuggestionIndex + 1) % suggestions.count
            } else if let idx = historyIndex {
                if idx + 1 < history.count {
                    historyIndex = idx + 1
                    inputChars = Array(history[idx + 1])
                } else {
                    historyIndex = nil
                    inputChars = Array(savedDraftBeforeHistory)
                }
                cursorIndex = inputChars.count
                refreshSuggestions()
            }

        case .left:
            if cursorIndex > 0 { cursorIndex -= 1 }

        case .right:
            if cursorIndex < inputChars.count {
                cursorIndex += 1
            } else if !suggestions.isEmpty {
                // Accept inline ghost completion with Right Arrow at end of line.
                let chosen = suggestions[selectedSuggestionIndex]
                inputChars = Array(chosen.completion)
                cursorIndex = inputChars.count
                menuDismissed = false
                refreshSuggestions()
            }

        case .home:
            cursorIndex = 0

        case .end:
            cursorIndex = inputChars.count

        case .backspace:
            if cursorIndex > 0 {
                cursorIndex -= 1
                inputChars.remove(at: cursorIndex)
                menuDismissed = false
                refreshSuggestions()
            }

        case .deleteForward:
            if cursorIndex < inputChars.count {
                inputChars.remove(at: cursorIndex)
                menuDismissed = false
                refreshSuggestions()
            }

        case .ctrlU:
            inputChars.removeAll()
            cursorIndex = 0
            menuDismissed = false
            refreshSuggestions()

        case .ctrlW:
            while cursorIndex > 0 && inputChars[cursorIndex - 1] == " " {
                cursorIndex -= 1
                inputChars.remove(at: cursorIndex)
            }
            while cursorIndex > 0 && inputChars[cursorIndex - 1] != " " {
                cursorIndex -= 1
                inputChars.remove(at: cursorIndex)
            }
            menuDismissed = false
            refreshSuggestions()

        case .char(let ch):
            inputChars.insert(ch, at: cursorIndex)
            cursorIndex += 1
            menuDismissed = false
            historyIndex = nil
            refreshSuggestions()
        }

        redrawInput()
    }

    private func refreshSuggestions() {
        guard !menuDismissed else {
            suggestions = []
            selectedSuggestionIndex = 0
            return
        }
        let current = String(inputChars)
        let peerEntries = runtime.chatViewModel.allPeers.map { peer in
            TerminalPeerEntry(
                name: peer.localPetname ?? peer.nickname,
                peerID: peer.peerID.id,
                status: peerStatusLabel(peer.connectionState)
            )
        }
        let next = TerminalCommandCatalog.suggestions(for: current, peers: peerEntries)
        suggestions = next
        if selectedSuggestionIndex >= next.count {
            selectedSuggestionIndex = 0
        }
    }

    private func peerStatusLabel(_ state: BitchatPeer.ConnectionState) -> String {
        switch state {
        case .bluetoothConnected: return "BLE connected"
        case .meshReachable: return "mesh reachable"
        case .nostrAvailable: return "nostr available"
        case .offline: return "offline"
        }
    }

    // MARK: - Command Dispatch

    private func handleSubmittedLine(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            redrawInput()
            return
        }

        if trimmed == "/quit" || trimmed == "/exit" || trimmed == "/q" {
            shutdown()
            return
        }

        if trimmed == "/help" || trimmed == "/h" {
            printHelp()
            redrawInput()
            return
        }

        if trimmed == "/peers" || trimmed == "/w" {
            printPeers()
            redrawInput()
            return
        }

        if trimmed == "/mesh" || trimmed == "/back" {
            if runtime.chatViewModel.selectedPrivateChatPeer != nil {
                runtime.chatViewModel.endPrivateChat()
                printRaw("\(dim)Switched back to #mesh public chat.\(reset)")
            } else {
                printRaw("\(dim)Already in #mesh public chat.\(reset)")
            }
            redrawInput()
            return
        }

        if trimmed.hasPrefix("/nick ") {
            let newNick = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !newNick.isEmpty {
                runtime.chatViewModel.nickname = newNick
                let safeNick = TerminalSanitizer.sanitize(newNick)
                printRaw("\(dim)Nickname set to \(bold)\(safeNick)\(reset)")
            }
            redrawInput()
            return
        }

        if trimmed == "/dm" || trimmed.hasPrefix("/dm ") {
            handleDMCommand(trimmed)
            redrawInput()
            return
        }

        // Plain messages + built-in BitChat IRC commands (/msg, /who, /slap, /hug, /clear, /block, /unblock).
        runtime.chatViewModel.sendMessage(trimmed)
        redrawInput()
    }

    private func handleDMCommand(_ command: String) {
        let rest = String(command.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else {
            printRaw("\(yellow)Usage:\(reset) /dm <nickname-or-peerID> [optional message]")
            return
        }

        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let targetQuery = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let inlineMessage = parts.count > 1 ? String(parts[1]) : nil

        let resolution = TerminalCommandCatalog.resolvePeer(
            matching: targetQuery,
            in: runtime.chatViewModel.allPeers,
            names: { peer in
                var list = [peer.nickname]
                if let petname = peer.localPetname { list.append(petname) }
                return list
            },
            peerID: { $0.peerID.id }
        )

        let peer: BitchatPeer
        switch resolution {
        case .unique(let matched):
            peer = matched
        case .ambiguous(let matches):
            let safeQuery = TerminalSanitizer.sanitize(targetQuery)
            printRaw("\(yellow)Ambiguous peer '\(safeQuery)'. Specify a peer ID instead:\(reset)")
            for candidate in matches {
                let name = TerminalSanitizer.sanitize(candidate.localPetname ?? candidate.nickname)
                let id = TerminalSanitizer.sanitize(candidate.peerID.id)
                printRaw("  • \(bold)\(name)\(reset) \(dim)(\(id))\(reset)")
            }
            return
        case .none:
            let safeQuery = TerminalSanitizer.sanitize(targetQuery)
            printRaw("\(yellow)No peer matching '\(safeQuery)'. Use /peers to list visible peers.\(reset)")
            return
        }

        runtime.chatViewModel.startPrivateChat(with: peer.peerID)

        // Only report DM mode and send an inline message if the model actually selected the peer
        // (e.g. startPrivateChat rejects blocked peers).
        guard runtime.chatViewModel.selectedPrivateChatPeer == peer.peerID else {
            let peerName = TerminalSanitizer.sanitize(peer.localPetname ?? peer.nickname)
            printRaw("\(yellow)Could not start private chat with \(peerName) (peer may be blocked).\(reset)")
            return
        }

        let peerName = TerminalSanitizer.sanitize(peer.localPetname ?? peer.nickname)
        let safeID = TerminalSanitizer.sanitize(peer.peerID.id)
        printRaw("\(magenta)Private encrypted chat (Noise) with \(bold)\(peerName)\(reset)\(magenta) (\(safeID)). Type /mesh to return.\(reset)")

        if let inlineMessage, !inlineMessage.isEmpty {
            runtime.chatViewModel.sendMessage(inlineMessage)
        }
    }

    private func printPeers() {
        let peers = runtime.chatViewModel.allPeers
        if peers.isEmpty {
            printRaw("\(dim)No peers discovered yet. Keep Bluetooth on and BitChat open on your phone.\(reset)")
            return
        }
        printRaw("\(bold)Peers (\(peers.count)):\(reset)")
        for peer in peers {
            let name = TerminalSanitizer.sanitize(peer.localPetname ?? peer.nickname)
            let safeID = TerminalSanitizer.sanitize(peer.peerID.id)
            let status: String
            switch peer.connectionState {
            case .bluetoothConnected: status = "\(green)BLE connected\(reset)"
            case .meshReachable: status = "\(cyan)mesh reachable\(reset)"
            case .nostrAvailable: status = "\(yellow)nostr available\(reset)"
            case .offline: status = "\(dim)offline\(reset)"
            }
            printRaw("  • \(bold)\(name)\(reset) \(dim)(\(safeID))\(reset) — \(status)")
        }
    }

    private func printHelp() {
        printRaw("\(bold)Commands:\(reset)")
        for spec in TerminalCommandCatalog.commands {
            let padded = spec.usage.padding(toLength: 24, withPad: " ", startingAt: 0)
            printRaw("  \(cyan)\(padded)\(reset)\(spec.summary)")
        }
        if isInteractiveTTY {
            printRaw("\(dim)Tip: Type / for live suggestions, ↑/↓ to select, Tab or → to autocomplete, Esc to dismiss.\(reset)")
        }
    }

    // MARK: - Terminal Rendering

    private func promptString() -> String {
        let nick = TerminalSanitizer.sanitize(runtime.chatViewModel.nickname)
        if let dmPeerID = runtime.chatViewModel.selectedPrivateChatPeer {
            let dmName = displayName(for: dmPeerID)
            return "\(magenta)[DM \(dmName)]\(reset) \(green)\(nick)\(reset) ❯ "
        }
        return "\(cyan)[mesh]\(reset) \(green)\(nick)\(reset) ❯ "
    }

    private func visiblePromptLength() -> Int {
        let nick = TerminalSanitizer.sanitize(runtime.chatViewModel.nickname)
        if let dmPeerID = runtime.chatViewModel.selectedPrivateChatPeer {
            let dmName = displayName(for: dmPeerID)
            return "[DM \(dmName)] \(nick) ❯ ".count
        }
        return "[mesh] \(nick) ❯ ".count
    }

    private func printLine(_ text: String) {
        // Clear current prompt + any suggestion dropdown below it, print message, then redraw.
        fputs("\r\u{001B}[J\(text)\n", stdout)
        redrawInput()
    }

    private func printRaw(_ text: String) {
        fputs("\(text)\n", stdout)
        fflush(stdout)
    }

    private func redrawInput() {
        guard isInteractiveTTY else {
            fputs(promptString(), stdout)
            fflush(stdout)
            return
        }

        let currentText = String(inputChars)
        var out = "\r\u{001B}[J"
        out += promptString()
        out += currentText

        // Inline ghost suffix when cursor is at the end and the selected suggestion extends the buffer.
        if cursorIndex == inputChars.count, !suggestions.isEmpty {
            let chosen = suggestions[selectedSuggestionIndex].completion
            if chosen.lowercased().hasPrefix(currentText.lowercased()), chosen.count > currentText.count {
                let suffix = chosen.dropFirst(currentText.count)
                out += "\(dim)\(suffix)\(reset)"
            }
        }

        // Render dropdown menu below the prompt line.
        var renderedMenuLines = 0
        if !suggestions.isEmpty {
            let total = suggestions.count
            let windowSize = min(maxVisibleSuggestions, total)
            let startIdx: Int
            if selectedSuggestionIndex < windowSize {
                startIdx = 0
            } else {
                startIdx = selectedSuggestionIndex - windowSize + 1
            }
            let endIdx = min(total, startIdx + windowSize)

            for i in startIdx..<endIdx {
                let item = suggestions[i]
                let paddedLabel = item.label.padding(toLength: 24, withPad: " ", startingAt: 0)
                if i == selectedSuggestionIndex {
                    out += "\n  \(cyan)\(bold)▸ \(paddedLabel)\(reset)\(dim)\(item.detail)\(reset)"
                } else {
                    out += "\n    \(dim)\(paddedLabel)\(item.detail)\(reset)"
                }
                renderedMenuLines += 1
            }

            if total > windowSize {
                out += "\n    \(dim)… \(total - windowSize) more (↑/↓ to scroll, Tab to accept)\(reset)"
                renderedMenuLines += 1
            }
        }

        // Restore cursor back to the exact column on the prompt line.
        if renderedMenuLines > 0 {
            out += "\u{001B}[\(renderedMenuLines)A"
        }
        let targetCol = visiblePromptLength() + cursorIndex
        out += "\r"
        if targetCol > 0 {
            out += "\u{001B}[\(targetCol)C"
        }

        fputs(out, stdout)
        fflush(stdout)
    }

    private func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        TermiosGuard.restore()
        fputs("\r\u{001B}[J\(dim)Disconnecting…\(reset)\n", stdout)
        fflush(stdout)
        runtime.applicationWillTerminate()
        exit(0)
    }
}
#endif
