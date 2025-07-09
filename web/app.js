// Main Bitchat Web IRC Application
class BitchatApp {
    constructor() {
        this.crypto = new BitchatCrypto();
        this.networking = new BitchatNetworking();
        
        // UI state
        this.currentChannel = null;
        this.selectedPeer = null;
        this.messages = [];
        this.channelMessages = new Map();
        this.privateMessages = new Map();
        this.unreadCounts = new Map();
        this.joinedChannels = new Set();
        this.channelKeys = new Map();
        this.blockedUsers = new Set();
        this.favorites = new Set();
        
        // UI elements
        this.messageInput = document.getElementById('message-input');
        this.messagesContainer = document.getElementById('messages');
        this.nicknameInput = document.getElementById('nickname');
        this.connectedCountEl = document.getElementById('connected-count');
        this.currentLocationEl = document.getElementById('current-location');
        this.sidebar = document.getElementById('sidebar');
        this.overlay = document.getElementById('overlay');
        this.autocompleteEl = document.getElementById('autocomplete');
        
        // Initialize
        this.init();
    }

    init() {
        // Set up event listeners
        this.setupEventListeners();
        
        // Set up networking callbacks
        this.networking.onMessage((message) => this.handleIncomingMessage(message));
        this.networking.onPeerUpdate((peers) => this.updatePeerList(peers));
        
        // Initialize UI
        this.nicknameInput.value = this.networking.nickname;
        this.updateUI();
        
        // Show welcome message
        this.addSystemMessage("Welcome to Bitchat Web IRC! Type /help for commands.");
        
        // Simulate some demo peers after a delay
        setTimeout(() => {
            this.networking.simulateBotPeers();
        }, 2000);
        
        // Load saved state
        this.loadState();
    }

    setupEventListeners() {
        // Message input
        this.messageInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                this.sendMessage();
            } else if (e.key === 'Tab') {
                e.preventDefault();
                this.handleTabCompletion();
            } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
                this.handleAutocomplete(e);
            } else if (e.key === 'Escape') {
                this.hideAutocomplete();
            }
        });

        this.messageInput.addEventListener('input', () => {
            this.handleInputChange();
        });

        // Nickname input
        this.nicknameInput.addEventListener('change', () => {
            this.networking.setNickname(this.nicknameInput.value);
        });

        // Header click for sidebar
        document.getElementById('peer-count').addEventListener('click', () => {
            this.toggleSidebar();
        });

        // Window beforeunload to clean up
        window.addEventListener('beforeunload', () => {
            this.saveState();
        });
    }

    // Message handling
    sendMessage() {
        const content = this.messageInput.value.trim();
        if (!content) return;

        this.messageInput.value = '';
        this.hideAutocomplete();

        // Check if it's a command
        if (content.startsWith('/')) {
            this.handleCommand(content);
        } else {
            // Regular message
            if (this.selectedPeer) {
                // Private message
                this.networking.sendMessage(content, this.selectedPeer, null, true);
                this.addPrivateMessage(this.networking.nickname, content, this.selectedPeer, true);
            } else if (this.currentChannel) {
                // Channel message
                this.networking.sendMessage(content, null, this.currentChannel, false);
                this.addChannelMessage(this.networking.nickname, content, this.currentChannel, false);
            } else {
                // Public message
                this.networking.sendMessage(content);
                this.addMessage(this.networking.nickname, content, false);
            }
        }
    }

    handleIncomingMessage(message) {
        // Check if sender is blocked
        if (this.blockedUsers.has(message.sender)) {
            return;
        }

        if (message.isPrivate && message.target === this.networking.nickname) {
            // Private message for us
            this.addPrivateMessage(message.sender, message.content, message.peerID, false);
            this.showNotification(`Private message from ${message.sender}`, message.content);
        } else if (message.channel) {
            // Channel message
            this.addChannelMessage(message.sender, message.content, message.channel, true);
        } else {
            // Public message
            this.addMessage(message.sender, message.content, true);
        }
    }

    // Command handling
    handleCommand(command) {
        const parts = command.split(' ');
        const cmd = parts[0].toLowerCase();
        const args = parts.slice(1);

        switch (cmd) {
            case '/help':
                this.showHelp();
                break;
            
            case '/j':
            case '/join':
                if (args.length > 0) {
                    this.joinChannel(args[0], args[1]); // channel, optional password
                } else {
                    this.addSystemMessage("Usage: /j #channel [password]");
                }
                break;
            
            case '/leave':
                if (this.currentChannel) {
                    this.leaveChannel(this.currentChannel);
                } else {
                    this.addSystemMessage("You're not in a channel.");
                }
                break;
            
            case '/m':
            case '/msg':
                if (args.length >= 2) {
                    const target = args[0].replace('@', '');
                    const message = args.slice(1).join(' ');
                    this.sendPrivateMessage(target, message);
                } else {
                    this.addSystemMessage("Usage: /m @nickname message");
                }
                break;
            
            case '/w':
            case '/who':
                this.listUsers();
                break;
            
            case '/channels':
                this.listChannels();
                break;
            
            case '/clear':
                this.clearMessages();
                break;
            
            case '/nick':
                if (args.length > 0) {
                    this.networking.setNickname(args[0]);
                    this.nicknameInput.value = args[0];
                    this.addSystemMessage(`Nickname changed to ${args[0]}`);
                } else {
                    this.addSystemMessage("Usage: /nick newnickname");
                }
                break;
            
            case '/block':
                if (args.length > 0) {
                    this.blockUser(args[0].replace('@', ''));
                } else {
                    this.listBlockedUsers();
                }
                break;
            
            case '/unblock':
                if (args.length > 0) {
                    this.unblockUser(args[0].replace('@', ''));
                } else {
                    this.addSystemMessage("Usage: /unblock @nickname");
                }
                break;
            
            case '/favorite':
            case '/fav':
                if (args.length > 0) {
                    this.toggleFavorite(args[0].replace('@', ''));
                } else {
                    this.listFavorites();
                }
                break;
            
            case '/back':
                this.backToPublic();
                break;
            
            case '/pass':
            case '/password':
                if (this.currentChannel && args.length > 0) {
                    this.setChannelPassword(this.currentChannel, args[0]);
                } else {
                    this.addSystemMessage("Usage: /pass password (must be in a channel)");
                }
                break;
            
            default:
                this.addSystemMessage(`Unknown command: ${cmd}. Type /help for available commands.`);
        }
    }

    // Command implementations
    showHelp() {
        const commands = [
            "/help - Show this help message",
            "/j #channel [password] - Join or create a channel",
            "/leave - Leave current channel",
            "/m @user message - Send private message",
            "/w - List online users",
            "/channels - Show all channels",
            "/clear - Clear chat messages",
            "/nick nickname - Change your nickname",
            "/block @user - Block a user",
            "/unblock @user - Unblock a user",
            "/favorite @user - Toggle user as favorite",
            "/back - Return to public chat",
            "/pass password - Set channel password (channel creator only)"
        ];
        
        this.addSystemMessage("Available commands:");
        commands.forEach(cmd => this.addSystemMessage("  " + cmd));
    }

    joinChannel(channelName, password = null) {
        if (!channelName.startsWith('#')) {
            channelName = '#' + channelName;
        }
        
        this.currentChannel = channelName;
        this.selectedPeer = null;
        this.joinedChannels.add(channelName);
        this.networking.joinChannel(channelName);
        
        if (password) {
            // Derive and store channel key
            this.crypto.deriveChannelKey(password, channelName).then(key => {
                if (key) {
                    this.channelKeys.set(channelName, key);
                    this.networking.setChannelKey(channelName, key);
                }
            });
        }
        
        this.addSystemMessage(`Joined channel ${channelName}`);
        this.updateUI();
        this.saveState();
    }

    leaveChannel(channelName) {
        this.joinedChannels.delete(channelName);
        this.channelKeys.delete(channelName);
        this.networking.leaveChannel(channelName);
        
        if (this.currentChannel === channelName) {
            this.currentChannel = null;
        }
        
        this.addSystemMessage(`Left channel ${channelName}`);
        this.updateUI();
        this.saveState();
    }

    sendPrivateMessage(nickname, message) {
        const peer = this.networking.getPeerByNickname(nickname);
        if (peer) {
            this.networking.sendMessage(message, nickname, null, true);
            this.addPrivateMessage(this.networking.nickname, message, peer.id, true);
            this.addSystemMessage(`Private message sent to ${nickname}`);
        } else {
            this.addSystemMessage(`User ${nickname} not found`);
        }
    }

    listUsers() {
        const peers = this.networking.getConnectedPeers();
        if (peers.length === 0) {
            this.addSystemMessage("No other users online");
        } else {
            this.addSystemMessage("Online users:");
            peers.forEach(peer => {
                const status = this.favorites.has(peer.nickname) ? " ⭐" : "";
                const channels = peer.channels.length > 0 ? ` (${peer.channels.join(', ')})` : "";
                this.addSystemMessage(`  @${peer.nickname}${status}${channels}`);
            });
        }
    }

    listChannels() {
        if (this.joinedChannels.size === 0) {
            this.addSystemMessage("No channels joined");
        } else {
            this.addSystemMessage("Joined channels:");
            this.joinedChannels.forEach(channel => {
                const current = channel === this.currentChannel ? " (current)" : "";
                const protected = this.channelKeys.has(channel) ? " 🔒" : "";
                this.addSystemMessage(`  ${channel}${protected}${current}`);
            });
        }
    }

    clearMessages() {
        if (this.currentChannel) {
            this.channelMessages.set(this.currentChannel, []);
        } else if (this.selectedPeer) {
            this.privateMessages.set(this.selectedPeer, []);
        } else {
            this.messages = [];
        }
        this.renderMessages();
    }

    blockUser(nickname) {
        this.blockedUsers.add(nickname);
        this.addSystemMessage(`Blocked user ${nickname}`);
        this.saveState();
    }

    unblockUser(nickname) {
        this.blockedUsers.delete(nickname);
        this.addSystemMessage(`Unblocked user ${nickname}`);
        this.saveState();
    }

    listBlockedUsers() {
        if (this.blockedUsers.size === 0) {
            this.addSystemMessage("No blocked users");
        } else {
            this.addSystemMessage("Blocked users:");
            this.blockedUsers.forEach(user => {
                this.addSystemMessage(`  @${user}`);
            });
        }
    }

    toggleFavorite(nickname) {
        if (this.favorites.has(nickname)) {
            this.favorites.delete(nickname);
            this.addSystemMessage(`Removed ${nickname} from favorites`);
        } else {
            this.favorites.add(nickname);
            this.addSystemMessage(`Added ${nickname} to favorites`);
        }
        this.updatePeerList(this.networking.getConnectedPeers());
        this.saveState();
    }

    listFavorites() {
        if (this.favorites.size === 0) {
            this.addSystemMessage("No favorite users");
        } else {
            this.addSystemMessage("Favorite users:");
            this.favorites.forEach(user => {
                this.addSystemMessage(`  @${user} ⭐`);
            });
        }
    }

    backToPublic() {
        this.currentChannel = null;
        this.selectedPeer = null;
        this.updateUI();
        this.addSystemMessage("Returned to public chat");
    }

    setChannelPassword(channel, password) {
        this.crypto.deriveChannelKey(password, channel).then(key => {
            if (key) {
                this.channelKeys.set(channel, key);
                this.networking.setChannelKey(channel, key);
                this.addSystemMessage(`Password set for channel ${channel}`);
                this.saveState();
            } else {
                this.addSystemMessage("Failed to set channel password");
            }
        });
    }

    // Message display
    addMessage(sender, content, isRelay = false) {
        const message = {
            id: Date.now() + Math.random(),
            sender,
            content,
            timestamp: new Date(),
            isRelay,
            type: 'public'
        };
        
        if (!this.currentChannel && !this.selectedPeer) {
            this.messages.push(message);
            this.renderMessages();
        }
    }

    addChannelMessage(sender, content, channel, isRelay = false) {
        const message = {
            id: Date.now() + Math.random(),
            sender,
            content,
            timestamp: new Date(),
            isRelay,
            type: 'channel',
            channel
        };
        
        if (!this.channelMessages.has(channel)) {
            this.channelMessages.set(channel, []);
        }
        
        this.channelMessages.get(channel).push(message);
        
        // Update unread count if not current channel
        if (this.currentChannel !== channel) {
            const count = this.unreadCounts.get(channel) || 0;
            this.unreadCounts.set(channel, count + 1);
        }
        
        if (this.currentChannel === channel) {
            this.renderMessages();
        }
        
        this.updateUI();
    }

    addPrivateMessage(sender, content, peerID, isSent = false) {
        const message = {
            id: Date.now() + Math.random(),
            sender,
            content,
            timestamp: new Date(),
            isSent,
            type: 'private'
        };
        
        if (!this.privateMessages.has(peerID)) {
            this.privateMessages.set(peerID, []);
        }
        
        this.privateMessages.get(peerID).push(message);
        
        // Update unread count if not current chat
        if (this.selectedPeer !== peerID && !isSent) {
            const count = this.unreadCounts.get(peerID) || 0;
            this.unreadCounts.set(peerID, count + 1);
        }
        
        if (this.selectedPeer === peerID) {
            this.renderMessages();
        }
        
        this.updateUI();
    }

    addSystemMessage(content) {
        const message = {
            id: Date.now() + Math.random(),
            sender: 'system',
            content,
            timestamp: new Date(),
            type: 'system'
        };
        
        if (this.currentChannel) {
            if (!this.channelMessages.has(this.currentChannel)) {
                this.channelMessages.set(this.currentChannel, []);
            }
            this.channelMessages.get(this.currentChannel).push(message);
        } else if (this.selectedPeer) {
            if (!this.privateMessages.has(this.selectedPeer)) {
                this.privateMessages.set(this.selectedPeer, []);
            }
            this.privateMessages.get(this.selectedPeer).push(message);
        } else {
            this.messages.push(message);
        }
        
        this.renderMessages();
    }

    renderMessages() {
        let messages = [];
        
        if (this.currentChannel) {
            messages = this.channelMessages.get(this.currentChannel) || [];
            this.unreadCounts.delete(this.currentChannel);
        } else if (this.selectedPeer) {
            messages = this.privateMessages.get(this.selectedPeer) || [];
            this.unreadCounts.delete(this.selectedPeer);
        } else {
            messages = this.messages;
        }
        
        this.messagesContainer.innerHTML = '';
        
        messages.forEach(message => {
            const messageEl = document.createElement('div');
            messageEl.className = `message ${message.type}`;
            
            if (message.sender === 'system') {
                messageEl.innerHTML = `<span class="content">${this.escapeHtml(message.content)}</span>`;
            } else {
                const timestamp = this.formatTimestamp(message.timestamp);
                const senderClass = message.isSent ? 'sent' : 'received';
                const relayIndicator = message.isRelay ? ' (relayed)' : '';
                
                messageEl.innerHTML = `
                    <span class="timestamp">${timestamp}</span>
                    <span class="sender ${senderClass}">@${this.escapeHtml(message.sender)}${relayIndicator}:</span>
                    <span class="content">${this.formatMessageContent(message.content)}</span>
                `;
            }
            
            this.messagesContainer.appendChild(messageEl);
        });
        
        // Scroll to bottom
        this.messagesContainer.scrollTop = this.messagesContainer.scrollHeight;
        this.updateUI();
    }

    formatMessageContent(content) {
        let formatted = this.escapeHtml(content);
        
        // Format @mentions
        formatted = formatted.replace(/@(\w+)/g, '<span class="mention">@$1</span>');
        
        // Format URLs
        formatted = formatted.replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" target="_blank" class="link">$1</a>');
        
        return formatted;
    }

    formatTimestamp(date) {
        return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // UI updates
    updateUI() {
        // Update header
        if (this.currentChannel) {
            this.currentLocationEl.textContent = `channel: ${this.currentChannel}`;
            this.currentLocationEl.style.color = '#0088ff';
        } else if (this.selectedPeer) {
            const peer = this.networking.getConnectedPeers().find(p => p.id === this.selectedPeer);
            this.currentLocationEl.textContent = `private: @${peer ? peer.nickname : 'unknown'}`;
            this.currentLocationEl.style.color = '#ff8800';
        } else {
            this.currentLocationEl.textContent = 'public chat';
            this.currentLocationEl.style.color = '#00ff00';
        }
        
        // Update peer count
        this.connectedCountEl.textContent = this.networking.getConnectedPeers().length;
        
        // Update channel count
        const channelCountEl = document.getElementById('channel-count');
        const joinedChannelsCountEl = document.getElementById('joined-channels-count');
        if (this.joinedChannels.size > 0) {
            channelCountEl.style.display = 'inline';
            joinedChannelsCountEl.textContent = this.joinedChannels.size;
        } else {
            channelCountEl.style.display = 'none';
        }
        
        // Update unread indicator
        const unreadIndicator = document.getElementById('unread-indicator');
        if (this.unreadCounts.size > 0) {
            unreadIndicator.style.display = 'inline';
        } else {
            unreadIndicator.style.display = 'none';
        }
    }

    updatePeerList(peers) {
        const peerListEl = document.getElementById('peer-list');
        peerListEl.innerHTML = '';
        
        peers.forEach(peer => {
            const peerEl = document.createElement('div');
            peerEl.className = 'peer-item';
            if (this.favorites.has(peer.nickname)) {
                peerEl.classList.add('favorite');
            }
            
            const unreadCount = this.unreadCounts.get(peer.id) || 0;
            const unreadIndicator = unreadCount > 0 ? ` (${unreadCount})` : '';
            
            peerEl.innerHTML = `
                <span class="status-indicator ${this.isOnline(peer) ? 'online' : 'offline'}"></span>
                @${peer.nickname}${unreadIndicator}
            `;
            
            peerEl.addEventListener('click', () => {
                this.startPrivateChat(peer.id, peer.nickname);
            });
            
            peerListEl.appendChild(peerEl);
        });
        
        this.updateChannelList();
        this.updateUI();
    }

    updateChannelList() {
        const channelListEl = document.getElementById('channel-list');
        channelListEl.innerHTML = '';
        
        this.joinedChannels.forEach(channel => {
            const channelEl = document.createElement('div');
            channelEl.className = 'channel-item';
            if (channel === this.currentChannel) {
                channelEl.classList.add('current');
            }
            
            const unreadCount = this.unreadCounts.get(channel) || 0;
            const unreadIndicator = unreadCount > 0 ? ` (${unreadCount})` : '';
            const lockIndicator = this.channelKeys.has(channel) ? ' 🔒' : '';
            
            channelEl.innerHTML = `${channel}${lockIndicator}${unreadIndicator}`;
            
            channelEl.addEventListener('click', () => {
                this.switchToChannel(channel);
            });
            
            channelListEl.appendChild(channelEl);
        });
    }

    startPrivateChat(peerID, nickname) {
        this.selectedPeer = peerID;
        this.currentChannel = null;
        this.updateUI();
        this.renderMessages();
        this.closeSidebar();
        this.addSystemMessage(`Started private chat with @${nickname}`);
    }

    switchToChannel(channel) {
        this.currentChannel = channel;
        this.selectedPeer = null;
        this.updateUI();
        this.renderMessages();
        this.closeSidebar();
    }

    isOnline(peer) {
        return Date.now() - peer.lastSeen < 30000;
    }

    // Autocomplete
    handleInputChange() {
        const input = this.messageInput.value;
        const cursorPos = this.messageInput.selectionStart;
        
        // Find the word at cursor position
        const beforeCursor = input.substring(0, cursorPos);
        const words = beforeCursor.split(/\s+/);
        const currentWord = words[words.length - 1];
        
        if (currentWord.startsWith('@') || currentWord.startsWith('#') || currentWord.startsWith('/')) {
            this.showAutocomplete(currentWord);
        } else {
            this.hideAutocomplete();
        }
    }

    showAutocomplete(prefix) {
        const suggestions = this.getAutocompleteSuggestions(prefix);
        
        if (suggestions.length > 0) {
            this.autocompleteEl.innerHTML = '';
            
            suggestions.forEach((suggestion, index) => {
                const item = document.createElement('div');
                item.className = 'autocomplete-item';
                if (index === 0) item.classList.add('selected');
                item.textContent = suggestion;
                
                item.addEventListener('click', () => {
                    this.completeInput(suggestion);
                });
                
                this.autocompleteEl.appendChild(item);
            });
            
            this.autocompleteEl.style.display = 'block';
        } else {
            this.hideAutocomplete();
        }
    }

    getAutocompleteSuggestions(prefix) {
        const suggestions = [];
        
        if (prefix.startsWith('@')) {
            const search = prefix.substring(1).toLowerCase();
            this.networking.getConnectedPeers().forEach(peer => {
                if (peer.nickname.toLowerCase().startsWith(search)) {
                    suggestions.push('@' + peer.nickname);
                }
            });
        } else if (prefix.startsWith('#')) {
            const search = prefix.substring(1).toLowerCase();
            this.joinedChannels.forEach(channel => {
                if (channel.toLowerCase().startsWith('#' + search)) {
                    suggestions.push(channel);
                }
            });
        } else if (prefix.startsWith('/')) {
            const commands = ['/help', '/join', '/leave', '/msg', '/who', '/channels', '/clear', '/nick', '/block', '/unblock', '/favorite', '/back', '/pass'];
            const search = prefix.toLowerCase();
            commands.forEach(cmd => {
                if (cmd.startsWith(search)) {
                    suggestions.push(cmd);
                }
            });
        }
        
        return suggestions.slice(0, 10);
    }

    completeInput(suggestion) {
        const input = this.messageInput.value;
        const cursorPos = this.messageInput.selectionStart;
        
        const beforeCursor = input.substring(0, cursorPos);
        const afterCursor = input.substring(cursorPos);
        
        const words = beforeCursor.split(/\s+/);
        words[words.length - 1] = suggestion;
        
        const newValue = words.join(' ') + afterCursor;
        this.messageInput.value = newValue;
        
        const newCursorPos = words.join(' ').length;
        this.messageInput.setSelectionRange(newCursorPos, newCursorPos);
        
        this.hideAutocomplete();
        this.messageInput.focus();
    }

    hideAutocomplete() {
        this.autocompleteEl.style.display = 'none';
    }

    handleTabCompletion() {
        const selectedItem = this.autocompleteEl.querySelector('.autocomplete-item.selected');
        if (selectedItem) {
            this.completeInput(selectedItem.textContent);
        }
    }

    handleAutocomplete(e) {
        const items = this.autocompleteEl.querySelectorAll('.autocomplete-item');
        const currentSelected = this.autocompleteEl.querySelector('.autocomplete-item.selected');
        
        if (items.length === 0) return;
        
        e.preventDefault();
        
        let newIndex = 0;
        if (currentSelected) {
            const currentIndex = Array.from(items).indexOf(currentSelected);
            newIndex = e.key === 'ArrowDown' 
                ? (currentIndex + 1) % items.length 
                : (currentIndex - 1 + items.length) % items.length;
        }
        
        items.forEach(item => item.classList.remove('selected'));
        items[newIndex].classList.add('selected');
    }

    // Sidebar
    toggleSidebar() {
        this.sidebar.classList.toggle('open');
        this.overlay.classList.toggle('show');
    }

    closeSidebar() {
        this.sidebar.classList.remove('open');
        this.overlay.classList.remove('show');
    }

    // Notifications
    showNotification(title, body) {
        if ('Notification' in window && Notification.permission === 'granted') {
            new Notification(title, { body, icon: '/favicon.ico' });
        }
    }

    // State persistence
    saveState() {
        const state = {
            joinedChannels: Array.from(this.joinedChannels),
            blockedUsers: Array.from(this.blockedUsers),
            favorites: Array.from(this.favorites),
            currentChannel: this.currentChannel,
            selectedPeer: this.selectedPeer
        };
        
        localStorage.setItem('bitchat-app-state', JSON.stringify(state));
    }

    loadState() {
        const stored = localStorage.getItem('bitchat-app-state');
        if (stored) {
            try {
                const state = JSON.parse(stored);
                this.joinedChannels = new Set(state.joinedChannels || []);
                this.blockedUsers = new Set(state.blockedUsers || []);
                this.favorites = new Set(state.favorites || []);
                this.currentChannel = state.currentChannel || null;
                this.selectedPeer = state.selectedPeer || null;
                
                // Re-join channels in networking
                this.joinedChannels.forEach(channel => {
                    this.networking.joinChannel(channel);
                });
                
                this.updateUI();
            } catch (error) {
                console.error('Error loading app state:', error);
            }
        }
        
        // Request notification permission
        if ('Notification' in window && Notification.permission === 'default') {
            Notification.requestPermission();
        }
    }
}

// Global functions for HTML onclick handlers
function sendMessage() {
    if (window.app) {
        window.app.sendMessage();
    }
}

function showAppInfo() {
    document.getElementById('app-info-modal').style.display = 'flex';
}

function closeAppInfo() {
    document.getElementById('app-info-modal').style.display = 'none';
}

function toggleSidebar() {
    if (window.app) {
        window.app.toggleSidebar();
    }
}

function closeSidebar() {
    if (window.app) {
        window.app.closeSidebar();
    }
}

function executeCommand(command) {
    if (window.app) {
        window.app.messageInput.value = command;
        window.app.sendMessage();
    }
}

// Initialize app when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.crypto = new BitchatCrypto();
    window.app = new BitchatApp();
});