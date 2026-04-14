import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct ChatMessageTests {

    @Test
    func withDeliveryStatus_returnsUpdatedCopyWithoutMutatingOriginal() {
        let original = BitchatMessage(
            id: "msg-1",
            sender: "Alice",
            content: "hello",
            timestamp: .now,
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Bob",
            senderPeerID: PeerID(str: "0011223344556677"),
            deliveryStatus: .sending
        )

        let updated = original.withDeliveryStatus(.delivered(to: "Bob", at: .now))

        #expect(original.deliveryStatus == .sending)
        #expect(updated.deliveryStatus != original.deliveryStatus)
    }

    @Test
    func formattedTextCache_isScopedByMessageIdentityAndPresentationFlags() {
        let message = BitchatMessage(
            id: "msg-cache",
            sender: "Alice",
            content: "cached",
            timestamp: .now,
            isRelay: false
        )

        let light = AttributedString("light")
        let dark = AttributedString("dark")

        message.setCachedFormattedText(light, isDark: false, isSelf: false)
        message.setCachedFormattedText(dark, isDark: true, isSelf: false)

        #expect(message.getCachedFormattedText(isDark: false, isSelf: false) == light)
        #expect(message.getCachedFormattedText(isDark: true, isSelf: false) == dark)
        #expect(message.getCachedFormattedText(isDark: false, isSelf: true) == nil)
    }
}
