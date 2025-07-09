// Production Networking for Bitchat Live using IRC
class BitchatNetworking {
    constructor() {
        this.peerID = null;
        this.nickname = null;
        this.connectedPeers = new Map();
        this.messageHandlers = [];
        this.peerHandlers = [];
        this.channels = new Set();
        this.channelKeys = new Map();
        this.privateChats = new Map();
        
        // Use IRC client for live connections
        this.ircClient = new BitchatIRCClient();
        
        // Fallback: Use BroadcastChannel for local tab communication
        this.broadcastChannel = new BroadcastChannel('bitchat-mesh');
        this.broadcastChannel.onmessage = (event) => this.handleBroadcastMessage(event);
        
        // Initialize
        this.init();
        
        // Heartbeat to announce presence
        setInterval(() => this.announcePresence(), 5000);
        
        // Check for new peers periodically
        setInterval(() => this.discoverPeers(), 3000);
        
        // Clean up old peers
        setInterval(() => this.cleanupPeers(), 10000);
    }

    init() {
        // Generate or restore peer ID
        this.peerID = localStorage.getItem('bitchat-peer-id');
        if (!this.peerID) {
            this.peerID = window.crypto.generatePeerID();
            localStorage.setItem('bitchat-peer-id', this.peerID);
        }

        // Set up IRC client callbacks
        this.ircClient.onMessage((message) => this.handleIRCMessage(message));
        this.ircClient.onUserUpdate((peers) => this.handleIRCPeerUpdate(peers));
        this.ircClient.onConnectionChange((connected, error) => this.handleConnectionChange(connected, error));
        
        // Get nickname from IRC client
        this.nickname = this.ircClient.nickname || this.generateNickname();
    }

    // IRC Message Handlers
    handleIRCMessage(message) {
        // Forward IRC messages to app handlers
        this.notifyMessage(message);
        
        // Also broadcast locally for multi-tab sync
        this.broadcastChannel.postMessage({
            type: 'irc_message',
            data: message
        });
    }

    handleIRCPeerUpdate(peers) {
        // Update local peer list
        this.connectedPeers.clear();
        peers.forEach(peer => {
            this.connectedPeers.set(peer.nickname, peer);
        });
        
        this.notifyPeerUpdate();
        
        // Broadcast peer update to other tabs
        this.broadcastChannel.postMessage({
            type: 'peer_update',
            data: peers
        });
    }

    handleConnectionChange(connected, error) {
        console.log(`IRC connection ${connected ? 'established' : 'lost'}`, error);
        
        // Notify connection status change
        this.broadcastChannel.postMessage({
            type: 'connection_change',
            data: { connected, error }
        });
    }

    generateNickname() {
        // Use same logic as IRC client for consistency
        const adjectives = ['swift', 'bright', 'clever', 'brave', 'quick', 'wise', 'bold', 'keen'];
        const nouns = ['fox', 'owl', 'hawk', 'wolf', 'bear', 'eagle', 'lion', 'tiger'];
        const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
        const noun = nouns[Math.floor(Math.random() * nouns.length)];
        const num = Math.floor(Math.random() * 1000);
        return `${adj}${noun}${num}`;
    }

    // Event handlers
    onMessage(handler) {
        this.messageHandlers.push(handler);
    }

    onPeerUpdate(handler) {
        this.peerHandlers.push(handler);
    }

    // Announce our presence to the network
    announcePresence() {
        const announcement = {
            type: 'announce',
            peerID: this.peerID,
            nickname: this.nickname,
            timestamp: Date.now(),
            channels: Array.from(this.channels)
        };

        // Broadcast to other tabs
        this.broadcastChannel.postMessage(announcement);

        // Store in localStorage for persistence
        this.updatePeerStorage(this.peerID, {
            nickname: this.nickname,
            lastSeen: Date.now(),
            channels: Array.from(this.channels)
        });
    }

    // Discover peers from localStorage
    discoverPeers() {
        const stored = localStorage.getItem(this.storageKey);
        if (stored) {
            try {
                const peers = JSON.parse(stored);
                let hasChanges = false;

                for (const [peerID, peerInfo] of Object.entries(peers)) {
                    if (peerID !== this.peerID) {
                        // Check if peer is recent (within last 30 seconds)
                        if (Date.now() - peerInfo.lastSeen < 30000) {
                            if (!this.connectedPeers.has(peerID)) {
                                this.connectedPeers.set(peerID, peerInfo);
                                hasChanges = true;
                                this.notifyPeerConnected(peerID, peerInfo.nickname);
                            } else {
                                // Update existing peer info
                                this.connectedPeers.set(peerID, peerInfo);
                            }
                        }
                    }
                }

                if (hasChanges) {
                    this.notifyPeerUpdate();
                }
            } catch (error) {
                console.error('Error parsing peer storage:', error);
            }
        }
    }

    // Clean up old peers
    cleanupPeers() {
        let hasChanges = false;
        const now = Date.now();

        for (const [peerID, peerInfo] of this.connectedPeers.entries()) {
            if (now - peerInfo.lastSeen > 30000) {
                this.connectedPeers.delete(peerID);
                hasChanges = true;
                this.notifyPeerDisconnected(peerID, peerInfo.nickname);
            }
        }

        if (hasChanges) {
            this.notifyPeerUpdate();
        }

        // Also clean up localStorage
        this.cleanupPeerStorage();
    }

    // Update peer in localStorage
    updatePeerStorage(peerID, peerInfo) {
        const stored = localStorage.getItem(this.storageKey);
        let peers = {};
        
        if (stored) {
            try {
                peers = JSON.parse(stored);
            } catch (error) {
                console.error('Error parsing peer storage:', error);
            }
        }

        peers[peerID] = peerInfo;
        localStorage.setItem(this.storageKey, JSON.stringify(peers));
    }

    // Clean up old peers from localStorage
    cleanupPeerStorage() {
        const stored = localStorage.getItem(this.storageKey);
        if (stored) {
            try {
                const peers = JSON.parse(stored);
                const now = Date.now();
                let hasChanges = false;

                for (const [peerID, peerInfo] of Object.entries(peers)) {
                    if (now - peerInfo.lastSeen > 60000) { // 1 minute for storage cleanup
                        delete peers[peerID];
                        hasChanges = true;
                    }
                }

                if (hasChanges) {
                    localStorage.setItem(this.storageKey, JSON.stringify(peers));
                }
            } catch (error) {
                console.error('Error cleaning peer storage:', error);
            }
        }
    }

    // Handle broadcast messages from other tabs
    handleBroadcastMessage(event) {
        const message = event.data;
        
        switch (message.type) {
            case 'announce':
                if (message.peerID !== this.peerID) {
                    const wasConnected = this.connectedPeers.has(message.peerID);
                    
                    this.connectedPeers.set(message.peerID, {
                        nickname: message.nickname,
                        lastSeen: message.timestamp,
                        channels: message.channels || []
                    });

                    if (!wasConnected) {
                        this.notifyPeerConnected(message.peerID, message.nickname);
                    }
                    
                    this.notifyPeerUpdate();
                }
                break;
                
            case 'message':
                if (message.peerID !== this.peerID) {
                    this.handleIncomingMessage(message);
                }
                break;
        }
    }

    // Send a message
    sendMessage(content, target = null, channel = null, isPrivate = false) {
        const messageID = this.peerID + '_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
        
        // Use IRC client for live messaging
        const success = this.ircClient.sendMessage(content, target, channel);
        
        if (success) {
            // Create message object for local display
            const message = {
                type: 'message',
                id: messageID,
                peerID: this.peerID,
                sender: this.nickname,
                content: content,
                timestamp: Date.now(),
                target: target,
                channel: channel,
                isPrivate: isPrivate,
                ttl: 7
            };

            // Notify local handlers
            this.notifyMessage(message);
            
            // Broadcast to other tabs
            this.broadcastChannel.postMessage(message);
        }

        return messageID;
    }

    // Handle incoming messages
    handleIncomingMessage(message) {
        // Check TTL
        if (message.ttl <= 0) {
            return;
        }

        // Check if we've seen this message before
        if (this.hasSeenMessage(message.id)) {
            return;
        }

        // Store message
        this.storeMessage(message);

        // Relay message with decreased TTL (simulating mesh forwarding)
        if (message.ttl > 1) {
            setTimeout(() => {
                const relayMessage = { ...message, ttl: message.ttl - 1 };
                this.broadcastChannel.postMessage(relayMessage);
            }, Math.random() * 1000); // Random delay to prevent broadcast storms
        }

        // Notify handlers
        this.notifyMessage(message);
    }

    // Store message for deduplication
    storeMessage(message) {
        const stored = localStorage.getItem(this.messageStorageKey);
        let messages = [];
        
        if (stored) {
            try {
                messages = JSON.parse(stored);
            } catch (error) {
                console.error('Error parsing message storage:', error);
            }
        }

        // Keep only recent messages (last 1000 or last hour)
        const now = Date.now();
        messages = messages.filter(m => now - m.timestamp < 3600000); // 1 hour
        messages = messages.slice(-1000); // Keep last 1000

        // Add new message if not duplicate
        if (!messages.find(m => m.id === message.id)) {
            messages.push(message);
            localStorage.setItem(this.messageStorageKey, JSON.stringify(messages));
        }
    }

    // Check if we've seen a message
    hasSeenMessage(messageID) {
        const stored = localStorage.getItem(this.messageStorageKey);
        if (stored) {
            try {
                const messages = JSON.parse(stored);
                return messages.some(m => m.id === messageID);
            } catch (error) {
                console.error('Error checking message storage:', error);
            }
        }
        return false;
    }

    // Join a channel
    joinChannel(channel) {
        this.channels.add(channel);
        this.ircClient.joinChannel(channel);
    }

    // Leave a channel
    leaveChannel(channel) {
        this.channels.delete(channel);
        this.channelKeys.delete(channel);
        this.ircClient.leaveChannel(channel);
    }

    // Set channel encryption key
    setChannelKey(channel, key) {
        this.channelKeys.set(channel, key);
    }

    // Get connected peers
    getConnectedPeers() {
        return this.ircClient.getConnectedPeers();
    }

    // Get peer by nickname
    getPeerByNickname(nickname) {
        return this.ircClient.getPeerByNickname(nickname);
    }

    // Update nickname
    setNickname(nickname) {
        this.nickname = nickname;
        localStorage.setItem('bitchat-nickname', nickname);
        this.ircClient.changeNickname(nickname);
    }

    // Notification methods
    notifyMessage(message) {
        this.messageHandlers.forEach(handler => {
            try {
                handler(message);
            } catch (error) {
                console.error('Message handler error:', error);
            }
        });
    }

    notifyPeerUpdate() {
        this.peerHandlers.forEach(handler => {
            try {
                handler(this.getConnectedPeers());
            } catch (error) {
                console.error('Peer handler error:', error);
            }
        });
    }

    notifyPeerConnected(peerID, nickname) {
        console.log(`Peer connected: ${nickname} (${peerID})`);
    }

    notifyPeerDisconnected(peerID, nickname) {
        console.log(`Peer disconnected: ${nickname} (${peerID})`);
    }

    // Get our peer info
    getMyInfo() {
        return {
            id: this.peerID,
            nickname: this.nickname
        };
    }

    // Simulate some bot peers for demo
    simulateBotPeers() {
        const bots = [
            { nickname: 'alice_bot', channels: ['#general', '#tech'] },
            { nickname: 'bob_helper', channels: ['#general', '#random'] },
            { nickname: 'charlie_dev', channels: ['#tech', '#dev'] }
        ];

        bots.forEach((bot, index) => {
            setTimeout(() => {
                const botPeerID = 'bot_' + bot.nickname;
                this.updatePeerStorage(botPeerID, {
                    nickname: bot.nickname,
                    lastSeen: Date.now(),
                    channels: bot.channels
                });

                // Send a welcome message from bot
                setTimeout(() => {
                    const welcomeMsg = {
                        type: 'message',
                        id: botPeerID + '_welcome_' + Date.now(),
                        peerID: botPeerID,
                        sender: bot.nickname,
                        content: `Hello! I'm ${bot.nickname}, a demo bot. Type /help for commands.`,
                        timestamp: Date.now(),
                        target: null,
                        channel: null,
                        isPrivate: false,
                        ttl: 1
                    };
                    this.handleIncomingMessage(welcomeMsg);
                }, 2000 + index * 1000);
            }, 1000 + index * 500);
        });
    }
}

// Export for use in other modules
window.BitchatNetworking = BitchatNetworking;