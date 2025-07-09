// Networking simulation for Bitchat Web IRC
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
        
        // Use BroadcastChannel for inter-tab communication
        this.broadcastChannel = new BroadcastChannel('bitchat-mesh');
        this.broadcastChannel.onmessage = (event) => this.handleBroadcastMessage(event);
        
        // Use localStorage for persistence and cross-tab discovery
        this.storageKey = 'bitchat-peers';
        this.messageStorageKey = 'bitchat-messages';
        
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

        // Restore nickname
        this.nickname = localStorage.getItem('bitchat-nickname');
        if (!this.nickname) {
            this.nickname = window.crypto.generateNickname();
            localStorage.setItem('bitchat-nickname', this.nickname);
        }

        // Announce presence immediately
        this.announcePresence();
        
        // Discover existing peers
        this.discoverPeers();
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

        // Broadcast the message
        this.broadcastChannel.postMessage(message);

        // Store message locally for persistence
        this.storeMessage(message);

        // Notify local handlers
        this.notifyMessage(message);

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
        this.announcePresence(); // Re-announce with updated channels
    }

    // Leave a channel
    leaveChannel(channel) {
        this.channels.delete(channel);
        this.channelKeys.delete(channel);
        this.announcePresence(); // Re-announce with updated channels
    }

    // Set channel encryption key
    setChannelKey(channel, key) {
        this.channelKeys.set(channel, key);
    }

    // Get connected peers
    getConnectedPeers() {
        return Array.from(this.connectedPeers.entries()).map(([id, info]) => ({
            id,
            nickname: info.nickname,
            lastSeen: info.lastSeen,
            channels: info.channels || []
        }));
    }

    // Get peer by nickname
    getPeerByNickname(nickname) {
        for (const [id, info] of this.connectedPeers.entries()) {
            if (info.nickname === nickname) {
                return { id, ...info };
            }
        }
        return null;
    }

    // Update nickname
    setNickname(nickname) {
        this.nickname = nickname;
        localStorage.setItem('bitchat-nickname', nickname);
        this.announcePresence();
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