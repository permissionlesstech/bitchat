// Production Configuration for Bitchat Live
const BITCHAT_CONFIG = {
    // Production URLs
    APP_URL: 'https://bitchat.live',
    IRC_SERVER: 'wss://irc.bitchat.xyz',
    BLOCK_SERVER: 'https://block.xyz',
    
    // WebSocket IRC Connection
    IRC_CONFIG: {
        host: 'irc.bitchat.xyz',
        port: 6697,
        secure: true,
        nick: null, // Will be set dynamically
        channels: ['#general', '#tech', '#random'],
        reconnect: true,
        retryCount: 5,
        retryDelay: 3000
    },
    
    // Backend API endpoints
    API_ENDPOINTS: {
        auth: '/api/auth',
        messages: '/api/messages',
        channels: '/api/channels',
        users: '/api/users',
        block: '/api/block'
    },
    
    // Swift app reference - maintain compatibility
    SWIFT_FEATURES: {
        // Features from original BitchatApp.swift
        MESH_NETWORKING: true,
        ENCRYPTION: true,
        CHANNELS: true,
        PRIVATE_MESSAGES: true,
        USER_BLOCKING: true,
        MESSAGE_RETENTION: true,
        EMERGENCY_WIPE: true,
        
        // Commands from Swift ChatViewModel
        COMMANDS: [
            '/help', '/j', '/join', '/leave', '/m', '/msg', 
            '/w', '/who', '/channels', '/clear', '/nick', 
            '/block', '/unblock', '/favorite', '/back', '/pass'
        ]
    },
    
    // Security settings matching Swift implementation
    SECURITY: {
        ENCRYPTION_ALGORITHM: 'AES-256-GCM',
        KEY_DERIVATION: 'PBKDF2',
        ITERATIONS: 100000,
        TTL_MAX_HOPS: 7,
        SESSION_TIMEOUT: 3600000, // 1 hour
        MESSAGE_EXPIRY: 86400000  // 24 hours
    },
    
    // Production flags
    PRODUCTION: true,
    DEBUG: false,
    ANALYTICS: true,
    
    // Rate limiting
    RATE_LIMITS: {
        MESSAGES_PER_MINUTE: 30,
        JOINS_PER_HOUR: 10,
        CONNECTIONS_PER_IP: 5
    }
};

// Export for both Node.js and browser
if (typeof module !== 'undefined' && module.exports) {
    module.exports = BITCHAT_CONFIG;
} else {
    window.BITCHAT_CONFIG = BITCHAT_CONFIG;
}