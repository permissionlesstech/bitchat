//
// ContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var showSidebar = false
    
    
    
    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        ZStack {
            // Main content
            GeometryReader { geometry in
                ZStack {
                    VStack(spacing: 0) {
                        HeaderView(showSidebar: $showSidebar, showAppInfo: $viewModel.showAppInfo)
                        Divider()
                        MessagesView()
                        Divider()
                        InputView()
                    }
                    .background(colorPalette.backgroundColor)
                    .foregroundColor(colorPalette.textColor)
                    
                    // Sidebar overlay
                    HStack(spacing: 0) {
                        // Tap to dismiss area
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showSidebar = false
                                }
                            }
                        
                        SidebarView(showSidebar: $showSidebar)
                            #if os(macOS)
                            .frame(width: min(300, geometry.size.width * 0.4))
                            #else
                            .frame(width: geometry.size.width * 0.7)
                            #endif
                            .transition(.move(edge: .trailing))
                    }
                    .offset(x: showSidebar ? 0 : geometry.size.width)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSidebar)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .sheet(isPresented: $viewModel.showAppInfo) {
            AppInfoView()
        }
        .alert("Set Channel Password", isPresented: $viewModel.showPasswordInput) {
            SecureField("Password", text: $viewModel.passwordInput)
            Button("Cancel", role: .cancel) {
                viewModel.passwordInput = ""
                viewModel.passwordInputChannel = nil
            }
            Button("Set Password") {
                if let channel = viewModel.passwordInputChannel, !viewModel.passwordInput.isEmpty {
                    viewModel.setChannelPassword(viewModel.passwordInput, for: channel)
                    viewModel.passwordInput = ""
                    viewModel.passwordInputChannel = nil
                }
            }
        } message: {
            Text("Enter a password to protect \(viewModel.passwordInputChannel ?? "channel"). Others will need this password to read messages.")
        }
        .alert("Enter Channel Password", isPresented: $viewModel.showPasswordPrompt) {
            SecureField("Password", text: $viewModel.passwordPromptInput)
            Button("Cancel", role: .cancel) {
                viewModel.passwordPromptInput = ""
                viewModel.passwordPromptChannel = nil
            }
            Button("Join") {
                if let channel = viewModel.passwordPromptChannel, !viewModel.passwordPromptInput.isEmpty {
                    let success = viewModel.joinChannel(channel, password: viewModel.passwordPromptInput)
                    if success {
                        viewModel.passwordPromptInput = ""
                    } else {
                        // Wrong password - show error
                        viewModel.passwordPromptInput = ""
                        viewModel.showPasswordError = true
                    }
                }
            }
        } message: {
            Text("Channel \(viewModel.passwordPromptChannel ?? "") is password protected. Enter the password to join.")
        }
        .alert("Wrong Password", isPresented: $viewModel.showPasswordError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The password you entered is incorrect. Please try again.")
        }
        .alert("leave channel?", isPresented: $viewModel.showLeaveChannelAlert) {
            Button("cancel", role: .cancel) { }
            Button("leave", role: .destructive) {
                if let channel = viewModel.currentChannel {
                    viewModel.leaveChannel(channel)
                }
            }
        } message: {
            Text("sure you want to leave \(viewModel.currentChannel ?? "")?")
        }
    }
    
    
    
    
    
    
    
    
    
    
}

// Helper view for rendering message content with clickable hashtags
struct MessageContentView: View {
    let message: BitchatMessage
    let viewModel: ChatViewModel
    let colorScheme: ColorScheme
    let isMentioned: Bool
    
    var body: some View {
        let content = message.content
        let hashtagPattern = "#([a-zA-Z0-9_]+)"
        let mentionPattern = "@([a-zA-Z0-9_]+)"
        
        let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
        
        let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        // Combine all matches and sort by location
        var allMatches: [(range: NSRange, type: String)] = []
        for match in hashtagMatches {
            allMatches.append((match.range(at: 0), "hashtag"))
        }
        for match in mentionMatches {
            allMatches.append((match.range(at: 0), "mention"))
        }
        allMatches.sort { $0.range.location < $1.range.location }
        
        // Build the text as a concatenated Text view for natural wrapping
        let segments = buildTextSegments()
        var result = Text("")
        
        for segment in segments {
            if segment.type == "hashtag" {
                // Note: We can't have clickable links in concatenated Text, so hashtags won't be clickable
                result = result + Text(segment.text)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.blue)
                    .underline()
            } else if segment.type == "mention" {
                result = result + Text(segment.text)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.orange)
            } else {
                result = result + Text(segment.text)
                    .font(.system(size: 14, design: .monospaced))
                    .fontWeight(isMentioned ? .bold : .regular)
            }
        }
        
        return result
            .textSelection(.enabled)
    }
    
    private func buildTextSegments() -> [(text: String, type: String)] {
        var segments: [(text: String, type: String)] = []
        let content = message.content
        var lastEnd = content.startIndex
        
        let hashtagPattern = "#([a-zA-Z0-9_]+)"
        let mentionPattern = "@([a-zA-Z0-9_]+)"
        
        let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
        
        let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        // Combine all matches and sort by location
        var allMatches: [(range: NSRange, type: String)] = []
        for match in hashtagMatches {
            allMatches.append((match.range(at: 0), "hashtag"))
        }
        for match in mentionMatches {
            allMatches.append((match.range(at: 0), "mention"))
        }
        allMatches.sort { $0.range.location < $1.range.location }
        
        for (matchRange, matchType) in allMatches {
            if let range = Range(matchRange, in: content) {
                // Add text before the match
                if lastEnd < range.lowerBound {
                    let beforeText = String(content[lastEnd..<range.lowerBound])
                    if !beforeText.isEmpty {
                        segments.append((beforeText, "text"))
                    }
                }
                
                // Add the match
                let matchText = String(content[range])
                segments.append((matchText, matchType))
                
                lastEnd = range.upperBound
            }
        }
        
        // Add any remaining text
        if lastEnd < content.endIndex {
            let remainingText = String(content[lastEnd...])
            if !remainingText.isEmpty {
                segments.append((remainingText, "text"))
            }
        }
        
        return segments
    }
}

// Delivery status indicator view
struct DeliveryStatusView: View {
    let status: DeliveryStatus
    let colorScheme: ColorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        switch status {
        case .sending:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            
        case .delivered(let nickname, _):
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
            }
            .foregroundColor(textColor.opacity(0.8))
            .help("Delivered to \(nickname)")
            
        case .read(let nickname, _):
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(Color(red: 0.0, green: 0.478, blue: 1.0))  // Bright blue
            .help("Read by \(nickname)")
            
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(Color.red.opacity(0.8))
                .help("Failed: \(reason)")
            
        case .partiallyDelivered(let reached, let total):
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
                Text("\(reached)/\(total)")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(secondaryTextColor.opacity(0.6))
            .help("Delivered to \(reached) of \(total) members")
        }
    }
}
