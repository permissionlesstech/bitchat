// IRC WebSocket Client for Bitchat Live
// Based on Swift BluetoothMeshService.swift architecture
class BitchatIRCClient {
    constructor() {
        this.config = window.BITCHAT_CONFIG;
        this.ws = null;
        this.connected = false;
        this.nickname = null;
        this.channels = new Set();
        this.messageHandlers = [];
        this.userHandlers = [];
        this.connectionHandlers = [];
        this.reconnectAttempts = 0;
        this.messageQueue = [];
        this.rateLimiter = new Map(); // Track message rates per user
        
        // Swift app compatibility - mirror ChatViewModel structure
        this.peerList = new Map();
        this.channelMembers = new Map();
        this.blockedUsers = new Set();
        
        this.init();
    }

    init() {
        this.loadBlockedUsers();
        this.connect();
        
        // Heartbeat to maintain connection
        setInterval(() => {
            if (this.connected) {
                this.sendPing();
            }
        }, 30000);
    }

    // WebSocket IRC Connection
    connect() {
        try {
            const wsUrl = `${this.config.IRC_SERVER}`;
            console.log(`Connecting to IRC server: ${wsUrl}`);
            
            this.ws = new WebSocket(wsUrl);
            
            this.ws.onopen = () => {
                console.log('Connected to IRC server');
                this.connected = true;
                this.reconnectAttempts = 0;
                this.authenticate();
                this.notifyConnectionChange(true);
            };
            
            this.ws.onmessage = (event) => {
                this.handleIRCMessage(event.data);
            };
            
            this.ws.onclose = () => {
                console.log('Disconnected from IRC server');
                this.connected = false;
                this.notifyConnectionChange(false);
                this.handleReconnect();
            };
            
            this.ws.onerror = (error) => {
                console.error('IRC WebSocket error:', error);
                this.connected = false;
                this.notifyConnectionChange(false);
            };
            
        } catch (error) {
            console.error('Failed to connect to IRC server:', error);
            this.handleReconnect();
        }
    }

    handleReconnect() {
        if (this.reconnectAttempts < this.config.IRC_CONFIG.retryCount) {
            this.reconnectAttempts++;
            console.log(`Attempting to reconnect (${this.reconnectAttempts}/${this.config.IRC_CONFIG.retryCount})`);
            
            setTimeout(() => {
                this.connect();
            }, this.config.IRC_CONFIG.retryDelay * this.reconnectAttempts);
        } else {
            console.error('Max reconnection attempts reached');
            this.notifyConnectionChange(false, 'Connection failed');
        }
    }

    authenticate() {
        if (!this.nickname) {
            this.nickname = this.generateNickname();
        }
        
        // Send IRC authentication - mirroring Swift app's mesh announce
        this.sendRaw(`NICK ${this.nickname}`);
        this.sendRaw(`USER ${this.nickname} 0 * :Bitchat Live User`);
        
        // Auto-join default channels after authentication
        setTimeout(() => {
            this.config.IRC_CONFIG.channels.forEach(channel => {
                this.joinChannel(channel);
            });
        }, 2000);
    }

    generateNickname() {
        // Use same logic as Swift BitchatCrypto for consistency
        const adjectives = ['swift', 'bright', 'clever', 'brave', 'quick', 'wise', 'bold', 'keen'];
        const nouns = ['fox', 'owl', 'hawk', 'wolf', 'bear', 'eagle', 'lion', 'tiger'];
        const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
        const noun = nouns[Math.floor(Math.random() * nouns.length)];
        const num = Math.floor(Math.random() * 1000);
        return `${adj}${noun}${num}`;
    }

    // IRC Message Handling - based on Swift message parsing
    handleIRCMessage(rawMessage) {
        const message = this.parseIRCMessage(rawMessage);
        
        switch (message.command) {
            case 'PING':
                this.sendRaw(`PONG :${message.params[0]}`);
                break;
                
            case 'PRIVMSG':
                this.handlePrivateMessage(message);
                break;
                
            case 'JOIN':
                this.handleUserJoin(message);
                break;
                
            case 'PART':
            case 'QUIT':
                this.handleUserLeave(message);
                break;
                
            case 'NICK':
                this.handleNickChange(message);
                break;
                
            case '353': // NAMES reply
                this.handleNamesReply(message);
                break;
                
            case '001': // Welcome message
                console.log('Successfully authenticated with IRC server');
                break;
                
            case 'ERROR':
                console.error('IRC Error:', message.params.join(' '));
                break;
        }
    }

    parseIRCMessage(raw) {
        const parts = raw.trim().split(' ');
        let prefix = null;
        let command = null;
        let params = [];
        
        let i = 0;
        if (parts[0].startsWith(':')) {
            prefix = parts[0].substring(1);
            i = 1;
        }
        
        command = parts[i];
        i++;
        
        while (i < parts.length) {
            if (parts[i].startsWith(':')) {
                params.push(parts.slice(i).join(' ').substring(1));
                break;
            } else {
                params.push(parts[i]);
            }
            i++;
        }
        
        return { prefix, command, params, raw };
    }

    handlePrivateMessage(message) {
        const [channel, ...contentParts] = message.params;
        const content = contentParts.join(' ');
        const sender = this.extractNickname(message.prefix);
        
        // Check if sender is blocked (Swift app feature)
        if (this.blockedUsers.has(sender)) {
            return;
        }
        
        // Apply rate limiting
        if (this.isRateLimited(sender)) {
            console.warn(`Rate limited message from ${sender}`);
            return;
        }
        
        const isPrivate = channel === this.nickname;
        const messageObj = {
            id: this.generateMessageId(),
            sender: sender,
            content: content,
            channel: isPrivate ? null : channel,
            isPrivate: isPrivate,
            timestamp: new Date(),
            encrypted: false // TODO: Implement encryption like Swift app
        };
        
        this.notifyMessage(messageObj);
    }

    handleUserJoin(message) {
        const channel = message.params[0];
        const nickname = this.extractNickname(message.prefix);
        
        if (!this.channelMembers.has(channel)) {
            this.channelMembers.set(channel, new Set());
        }
        this.channelMembers.get(channel).add(nickname);
        
        this.updatePeerList();
    }

    handleUserLeave(message) {
        const nickname = this.extractNickname(message.prefix);
        
        // Remove from all channels
        for (const [channel, members] of this.channelMembers.entries()) {
            members.delete(nickname);
        }
        
        this.peerList.delete(nickname);
        this.updatePeerList();
    }

    handleNickChange(message) {
        const oldNick = this.extractNickname(message.prefix);
        const newNick = message.params[0];
        
        // Update in all channel member lists
        for (const [channel, members] of this.channelMembers.entries()) {
            if (members.has(oldNick)) {
                members.delete(oldNick);
                members.add(newNick);
            }
        }
        
        // Update peer list
        if (this.peerList.has(oldNick)) {
            const peerInfo = this.peerList.get(oldNick);
            this.peerList.delete(oldNick);
            this.peerList.set(newNick, { ...peerInfo, nickname: newNick });
        }
        
        this.updatePeerList();
    }

    handleNamesReply(message) {
        const channel = message.params[2];
        const names = message.params[3].split(' ').map(name => name.replace(/[@+%]/, ''));
        
        if (!this.channelMembers.has(channel)) {
            this.channelMembers.set(channel, new Set());
        }
        
        const members = this.channelMembers.get(channel);
        names.forEach(name => {
            if (name.trim()) {
                members.add(name.trim());
                this.peerList.set(name.trim(), {
                    nickname: name.trim(),
                    lastSeen: Date.now(),
                    channels: [channel]
                });
            }
        });
        
        this.updatePeerList();
    }

    extractNickname(prefix) {
        if (!prefix) return null;
        return prefix.split('!')[0];
    }

    // Rate limiting based on Swift app's performance optimizations
    isRateLimited(sender) {
        const now = Date.now();
        const limit = this.config.RATE_LIMITS.MESSAGES_PER_MINUTE;
        
        if (!this.rateLimiter.has(sender)) {
            this.rateLimiter.set(sender, []);
        }
        
        const timestamps = this.rateLimiter.get(sender);
        const oneMinuteAgo = now - 60000;
        
        // Remove old timestamps
        while (timestamps.length > 0 && timestamps[0] < oneMinuteAgo) {
            timestamps.shift();
        }
        
        if (timestamps.length >= limit) {
            return true;
        }
        
        timestamps.push(now);
        return false;
    }

    generateMessageId() {
        return Date.now().toString(36) + Math.random().toString(36).substr(2);
    }

    // Public API - matching Swift ChatViewModel interface
    sendMessage(content, target = null, channel = null) {
        if (!this.connected) {
            this.messageQueue.push({ content, target, channel });
            return false;
        }
        
        let destination = channel || target || this.channels.values().next().value || '#general';
        
        if (target && !channel) {
            // Private message
            destination = target;
        }
        
        this.sendRaw(`PRIVMSG ${destination} :${content}`);
        return true;
    }

    joinChannel(channel) {
        if (!channel.startsWith('#')) {
            channel = '#' + channel;
        }
        
        this.channels.add(channel);
        this.sendRaw(`JOIN ${channel}`);
        
        // Mirror Swift app behavior
        this.notifyMessage({
            id: this.generateMessageId(),
            sender: 'system',
            content: `Joined channel ${channel}`,
            channel: channel,
            isPrivate: false,
            timestamp: new Date(),
            encrypted: false
        });
    }

    leaveChannel(channel) {
        this.channels.delete(channel);
        this.sendRaw(`PART ${channel}`);
        
        if (this.channelMembers.has(channel)) {
            this.channelMembers.delete(channel);
        }
        
        this.updatePeerList();
    }

    changeNickname(newNick) {
        this.sendRaw(`NICK ${newNick}`);
        this.nickname = newNick;
    }

    sendPing() {
        if (this.connected) {
            this.sendRaw('PING :bitchat.live');
        }
    }

    sendRaw(message) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(message + '\r\n');
        }
    }

    // User blocking - from Swift app
    blockUser(nickname) {
        this.blockedUsers.add(nickname);
        this.saveBlockedUsers();
        
        // Notify block.xyz server
        this.reportToBlockServer(nickname);
    }

    unblockUser(nickname) {
        this.blockedUsers.delete(nickname);
        this.saveBlockedUsers();
    }

    async reportToBlockServer(nickname) {
        try {
            await fetch(`${this.config.BLOCK_SERVER}/api/report`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ 
                    type: 'block',
                    target: nickname,
                    reporter: this.nickname,
                    timestamp: Date.now()
                })
            });
        } catch (error) {
            console.error('Failed to report to block server:', error);
        }
    }

    // Storage - matching Swift UserDefaults pattern
    saveBlockedUsers() {
        localStorage.setItem('bitchat-blocked-users', JSON.stringify(Array.from(this.blockedUsers)));
    }

    loadBlockedUsers() {
        const stored = localStorage.getItem('bitchat-blocked-users');
        if (stored) {
            try {
                this.blockedUsers = new Set(JSON.parse(stored));
            } catch (error) {
                console.error('Failed to load blocked users:', error);
            }
        }
    }

    // Event handlers
    onMessage(handler) {
        this.messageHandlers.push(handler);
    }

    onUserUpdate(handler) {
        this.userHandlers.push(handler);
    }

    onConnectionChange(handler) {
        this.connectionHandlers.push(handler);
    }

    notifyMessage(message) {
        this.messageHandlers.forEach(handler => {
            try {
                handler(message);
            } catch (error) {
                console.error('Message handler error:', error);
            }
        });
    }

    updatePeerList() {
        const peers = Array.from(this.peerList.values()).filter(peer => peer.nickname !== this.nickname);
        
        this.userHandlers.forEach(handler => {
            try {
                handler(peers);
            } catch (error) {
                console.error('User handler error:', error);
            }
        });
    }

    notifyConnectionChange(connected, error = null) {
        this.connectionHandlers.forEach(handler => {
            try {
                handler(connected, error);
            } catch (error) {
                console.error('Connection handler error:', error);
            }
        });
    }

    // Getters - matching Swift interface
    getConnectedPeers() {
        return Array.from(this.peerList.values()).filter(peer => peer.nickname !== this.nickname);
    }

    getPeerByNickname(nickname) {
        return this.peerList.get(nickname) || null;
    }

    getMyInfo() {
        return {
            nickname: this.nickname,
            channels: Array.from(this.channels),
            connected: this.connected
        };
    }

    isConnected() {
        return this.connected;
    }
}

// Export for use in other modules
window.BitchatIRCClient = BitchatIRCClient;