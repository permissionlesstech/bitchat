from dataclasses import dataclass, field


@dataclass
class SessionState:
    current_chat: str = "mesh"
    undo_stack: list[str] = field(default_factory=list)
    redo_stack: list[str] = field(default_factory=list)

    def select_chat(self, chat_id: str) -> str:
        if chat_id != self.current_chat:
            self.undo_stack.append(self.current_chat)
            self.current_chat = chat_id
            self.redo_stack.clear()
        return self.current_chat

    def undo(self) -> str:
        if not self.undo_stack:
            return self.current_chat
        self.redo_stack.append(self.current_chat)
        self.current_chat = self.undo_stack.pop()
        return self.current_chat

    def redo(self) -> str:
        if not self.redo_stack:
            return self.current_chat
        self.undo_stack.append(self.current_chat)
        self.current_chat = self.redo_stack.pop()
        return self.current_chat
