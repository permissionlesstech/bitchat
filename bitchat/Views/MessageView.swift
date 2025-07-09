
//
//  MessageView.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct MessageView: View {
    let message: BitchatMessage
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.sender == "system" {
                systemMessage
            } else {
                userMessage
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var systemMessage: some View {
        Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                // Single text view for natural wrapping
                Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Delivery status indicator for private messages
                if message.isPrivate && message.sender == viewModel.nickname,
                   let status = message.deliveryStatus {
                    DeliveryStatusView(status: status, colorScheme: colorScheme)
                        .padding(.leading, 4)
                }
            }

            // Check for links and show preview
            if let markdownLink = message.content.extractMarkdownLink() {
                // Don't show link preview if the message is just the emoji
                let cleanContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanContent.hasPrefix("👇") {
                    LinkPreviewView(url: markdownLink.url, title: markdownLink.title)
                        .padding(.top, 4)
                }
            } else {
                // Check for plain URLs
                let urls = message.content.extractURLs()
                ForEach(urls.prefix(3), id: \.url) { urlInfo in
                    LinkPreviewView(url: urlInfo.url, title: nil)
                        .padding(.top, 4)
                }
            }
        }
    }
}
