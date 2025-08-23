import Foundation

struct CommandMeta {
    let id: String
    let tokens: [String] // e.g., ["/m", "/msg"]
    let titleKey: String // e.g., "cmd.msg.title"
    let helpKey: String  // e.g., "cmd.msg.help"
}

enum CommandRegistry {
    static let all: [CommandMeta] = [
        CommandMeta(id: "block", tokens: ["/block"], titleKey: "cmd.block.title", helpKey: "cmd.block.help"),
        CommandMeta(id: "clear", tokens: ["/clear"], titleKey: "cmd.clear.title", helpKey: "cmd.clear.help"),
        CommandMeta(id: "fav", tokens: ["/fav"], titleKey: "cmd.fav.title", helpKey: "cmd.fav.help"),
        CommandMeta(id: "help", tokens: ["/help"], titleKey: "cmd.help.title", helpKey: "cmd.help.help"),
        CommandMeta(id: "hug", tokens: ["/hug"], titleKey: "cmd.hug.title", helpKey: "cmd.hug.help"),
        CommandMeta(id: "msg", tokens: ["/m", "/msg"], titleKey: "cmd.msg.title", helpKey: "cmd.msg.help"),
        CommandMeta(id: "slap", tokens: ["/slap"], titleKey: "cmd.slap.title", helpKey: "cmd.slap.help"),
        CommandMeta(id: "unblock", tokens: ["/unblock"], titleKey: "cmd.unblock.title", helpKey: "cmd.unblock.help"),
        CommandMeta(id: "unfav", tokens: ["/unfav"], titleKey: "cmd.unfav.title", helpKey: "cmd.unfav.help"),
        CommandMeta(id: "who", tokens: ["/w", "/who"], titleKey: "cmd.who.title", helpKey: "cmd.who.help")
    ]
}

