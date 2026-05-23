const state = {
  chats: [],
  activeChatId: "mesh",
  events: null,
};

const els = {
  dot: document.querySelector("#service-dot"),
  backend: document.querySelector("#backend-mode"),
  nickname: document.querySelector("#nickname"),
  bluetooth: document.querySelector("#bluetooth-state"),
  peerCount: document.querySelector("#peer-count"),
  chats: document.querySelector("#chat-list"),
  peers: document.querySelector("#peer-list"),
  activeName: document.querySelector("#active-chat-name"),
  activeMeta: document.querySelector("#active-chat-meta"),
  messages: document.querySelector("#messages"),
};

async function refresh() {
  const [status, chats, peers] = await Promise.all([
    fetchJSON("/api/status"),
    fetchJSON("/api/chats"),
    fetchJSON("/api/peers"),
  ]);
  renderStatus(status);
  state.chats = chats;
  if (!state.chats.some((chat) => chat.id === state.activeChatId)) {
    state.activeChatId = state.chats[0]?.id || "mesh";
  }
  renderChats();
  renderPeers(peers);
  await loadMessages();
  connectEvents();
}

async function fetchJSON(path) {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path} returned ${response.status}`);
  return response.json();
}

function renderStatus(status) {
  const ready = status.service_status === "running";
  els.dot.className = `status-dot ${ready ? "ready" : "offline"}`;
  els.backend.textContent = status.backend_mode || "local";
  els.nickname.textContent = `nickname: ${status.nickname || "--"}`;
  els.bluetooth.textContent = `bluetooth: ${formatBluetooth(status.bluetooth_state)}`;
  els.peerCount.textContent = `peers: ${status.connected_peer_count ?? "--"}`;
}

function renderChats() {
  els.chats.replaceChildren();
  for (const chat of state.chats) {
    const button = document.createElement("button");
    button.className = `chat-item ${chat.id === state.activeChatId ? "active" : ""}`;
    button.type = "button";
    button.innerHTML = `<span>${escapeHTML(chat.name || chat.id)}</span><span class="count">${chat.message_count ?? 0}</span>`;
    button.addEventListener("click", async () => {
      state.activeChatId = chat.id;
      renderChats();
      await loadMessages();
      connectEvents();
    });
    els.chats.append(button);
  }
}

function renderPeers(peers) {
  els.peers.replaceChildren();
  if (!peers.length) {
    const empty = document.createElement("div");
    empty.className = "empty-line";
    empty.textContent = "no nearby peers discovered yet";
    els.peers.append(empty);
    return;
  }
  for (const peer of peers) {
    const item = document.createElement("div");
    item.className = "peer-item";
    item.innerHTML = `<span>${escapeHTML(peer.nickname || peer.id)}</span><span class="count">${peer.connected ? "online" : "seen"}</span>`;
    els.peers.append(item);
  }
}

async function loadMessages() {
  const chat = state.chats.find((item) => item.id === state.activeChatId);
  els.activeName.textContent = chat?.name || state.activeChatId;
  els.activeMeta.textContent = "view only";
  const messages = await fetchJSON(`/api/messages?chat_id=${encodeURIComponent(state.activeChatId)}&limit=200`);
  renderMessages(messages);
}

function renderMessages(messages) {
  els.messages.replaceChildren();
  if (!messages.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "No local history for this chat yet.";
    els.messages.append(empty);
    return;
  }
  for (const message of newestFirst(messages)) {
    appendMessage(message);
  }
  els.messages.scrollTop = 0;
}

function appendMessage(message, placement = "end") {
  const node = document.createElement("article");
  node.className = "message";
  node.dataset.messageId = message.id || "";
  node.innerHTML = `
    <div class="message-head">
      <div class="message-meta">
        <span>${escapeHTML(formatTime(message.created_at))}</span>
        <span class="sender">${escapeHTML(message.sender || "unknown")}</span>
        <span class="delivery">${escapeHTML(message.delivery || "received")}</span>
      </div>
      <button class="message-copy" type="button" aria-label="Copy message content">Copy</button>
    </div>
    <div class="message-text">${escapeHTML(message.text || "")}</div>
  `;
  node.querySelector(".message-copy").addEventListener("click", (event) => {
    copyMessageText(message.text || "", event.currentTarget);
  });
  if (placement === "start") {
    els.messages.prepend(node);
  } else {
    els.messages.append(node);
  }
}

function connectEvents() {
  if (state.events) state.events.close();
  state.events = new EventSource(`/api/events?chat_id=${encodeURIComponent(state.activeChatId)}`);
  state.events.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.chat_id !== state.activeChatId) return;
    if (message.id && els.messages.querySelector(`[data-message-id="${CSS.escape(message.id)}"]`)) return;
    if (els.messages.querySelector(".empty-state")) els.messages.replaceChildren();
    appendMessage(message, "start");
    els.messages.scrollTop = 0;
  };
}

function newestFirst(messages) {
  return messages
    .map((message, index) => ({ index, message }))
    .sort((left, right) => {
      const leftTime = Date.parse(left.message.created_at || "");
      const rightTime = Date.parse(right.message.created_at || "");
      const leftValue = Number.isNaN(leftTime) ? left.index : leftTime;
      const rightValue = Number.isNaN(rightTime) ? right.index : rightTime;
      return rightValue - leftValue;
    })
    .map((item) => item.message);
}

async function copyMessageText(text, button) {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      fallbackCopy(text);
    }
    flashCopyButton(button, "Copied");
  } catch {
    fallbackCopy(text);
    flashCopyButton(button, "Copied");
  }
}

function fallbackCopy(text) {
  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.left = "-9999px";
  document.body.append(area);
  area.select();
  document.execCommand("copy");
  area.remove();
}

function flashCopyButton(button, text) {
  const original = button.textContent;
  button.textContent = text;
  button.disabled = true;
  setTimeout(() => {
    button.textContent = original;
    button.disabled = false;
  }, 900);
}

function formatBluetooth(value) {
  if (!value) return "--";
  if (String(value).includes("rawValue: 5")) return "ready";
  return String(value);
}

function formatTime(value) {
  if (!value) return "--:--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[char]));
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

refresh().catch((error) => {
  renderStatus({ service_status: "unavailable", message: error.message });
  els.messages.innerHTML = `<div class="empty-state">Local web service unavailable: ${escapeHTML(error.message)}</div>`;
});

setInterval(() => {
  refresh().catch(() => {});
}, 10000);
