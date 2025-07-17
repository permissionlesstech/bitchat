// Simple crypto utilities for Bitchat Web IRC
class BitchatCrypto {
    constructor() {
        this.encoder = new TextEncoder();
        this.decoder = new TextDecoder();
    }

    // Generate a random peer ID
    generatePeerID() {
        return 'peer_' + Array.from(crypto.getRandomValues(new Uint8Array(8)))
            .map(b => b.toString(16).padStart(2, '0'))
            .join('');
    }

    // Generate a random nickname
    generateNickname() {
        const adjectives = ['swift', 'bright', 'clever', 'brave', 'quick', 'wise', 'bold', 'keen'];
        const nouns = ['fox', 'owl', 'hawk', 'wolf', 'bear', 'eagle', 'lion', 'tiger'];
        const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
        const noun = nouns[Math.floor(Math.random() * nouns.length)];
        const num = Math.floor(Math.random() * 1000);
        return `${adj}${noun}${num}`;
    }

    // Simple hash function for message IDs
    async simpleHash(text) {
        const msgUint8 = this.encoder.encode(text);
        const hashBuffer = await crypto.subtle.digest('SHA-256', msgUint8);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        return hashArray.map(b => b.toString(16).padStart(2, '0')).join('').substring(0, 16);
    }

    // Derive a key from password for channel encryption
    async deriveChannelKey(password, channelName) {
        try {
            const keyMaterial = await crypto.subtle.importKey(
                'raw',
                this.encoder.encode(password + channelName),
                'PBKDF2',
                false,
                ['deriveBits', 'deriveKey']
            );

            const key = await crypto.subtle.deriveKey(
                {
                    name: 'PBKDF2',
                    salt: this.encoder.encode('bitchat-' + channelName),
                    iterations: 100000,
                    hash: 'SHA-256',
                },
                keyMaterial,
                { name: 'AES-GCM', length: 256 },
                true,
                ['encrypt', 'decrypt']
            );

            return key;
        } catch (error) {
            console.error('Key derivation failed:', error);
            return null;
        }
    }

    // Encrypt a message for a channel
    async encryptChannelMessage(message, key) {
        try {
            const iv = crypto.getRandomValues(new Uint8Array(12));
            const encodedMessage = this.encoder.encode(message);
            
            const encrypted = await crypto.subtle.encrypt(
                { name: 'AES-GCM', iv: iv },
                key,
                encodedMessage
            );

            // Combine IV and encrypted data
            const combined = new Uint8Array(iv.length + encrypted.byteLength);
            combined.set(iv);
            combined.set(new Uint8Array(encrypted), iv.length);

            return Array.from(combined).map(b => b.toString(16).padStart(2, '0')).join('');
        } catch (error) {
            console.error('Encryption failed:', error);
            return null;
        }
    }

    // Decrypt a channel message
    async decryptChannelMessage(encryptedHex, key) {
        try {
            // Convert hex string back to bytes
            const encrypted = new Uint8Array(encryptedHex.match(/.{1,2}/g).map(byte => parseInt(byte, 16)));
            
            // Extract IV and encrypted data
            const iv = encrypted.slice(0, 12);
            const data = encrypted.slice(12);

            const decrypted = await crypto.subtle.decrypt(
                { name: 'AES-GCM', iv: iv },
                key,
                data
            );

            return this.decoder.decode(decrypted);
        } catch (error) {
            console.error('Decryption failed:', error);
            return null;
        }
    }

    // Generate a commitment for a key (for verification)
    async generateKeyCommitment(key) {
        try {
            const keyData = await crypto.subtle.exportKey('raw', key);
            const hash = await crypto.subtle.digest('SHA-256', keyData);
            return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, '0')).join('');
        } catch (error) {
            console.error('Key commitment generation failed:', error);
            return null;
        }
    }

    // Simple XOR encryption for private messages (demo purposes)
    simpleEncrypt(message, key) {
        const messageBytes = this.encoder.encode(message);
        const keyBytes = this.encoder.encode(key);
        const encrypted = new Uint8Array(messageBytes.length);
        
        for (let i = 0; i < messageBytes.length; i++) {
            encrypted[i] = messageBytes[i] ^ keyBytes[i % keyBytes.length];
        }
        
        return Array.from(encrypted).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    // Simple XOR decryption
    simpleDecrypt(encryptedHex, key) {
        try {
            const encrypted = new Uint8Array(encryptedHex.match(/.{1,2}/g).map(byte => parseInt(byte, 16)));
            const keyBytes = this.encoder.encode(key);
            const decrypted = new Uint8Array(encrypted.length);
            
            for (let i = 0; i < encrypted.length; i++) {
                decrypted[i] = encrypted[i] ^ keyBytes[i % keyBytes.length];
            }
            
            return this.decoder.decode(decrypted);
        } catch (error) {
            console.error('Simple decryption failed:', error);
            return null;
        }
    }
}

// Export for use in other modules
window.BitchatCrypto = BitchatCrypto;