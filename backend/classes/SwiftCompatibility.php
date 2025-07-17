<?php
/**
 * Swift Compatibility Layer
 * Ensures PHP backend maintains feature parity with Swift BitchatApp
 * 
 * This class maps Swift app functionality to PHP equivalents
 * Based on BitchatApp.swift, ChatViewModel.swift, and other Swift components
 */

class SwiftCompatibility {
    
    // Mirror Swift app's message structure from BitchatMessage
    public static function createSwiftMessage($content, $sender, $channel = null, $isPrivate = false) {
        return [
            'id' => self::generateMessageId(), // Similar to Swift's UUID generation
            'sender' => $sender,
            'content' => $content,
            'timestamp' => time() * 1000, // Swift uses milliseconds
            'channel' => $channel,
            'isPrivate' => $isPrivate,
            'isRelay' => false,
            'ttl' => 7, // Max hops as in Swift BluetoothMeshService
            'encryptedContent' => null,
            'isEncrypted' => false,
            'deliveryStatus' => 'sent'
        ];
    }
    
    // Generate message ID like Swift app
    public static function generateMessageId() {
        return uniqid('msg_', true) . '_' . bin2hex(random_bytes(4));
    }
    
    // Generate peer ID like Swift BitchatCrypto
    public static function generatePeerID() {
        return 'peer_' . bin2hex(random_bytes(8));
    }
    
    // Generate nickname like Swift implementation
    public static function generateNickname() {
        $adjectives = ['swift', 'bright', 'clever', 'brave', 'quick', 'wise', 'bold', 'keen'];
        $nouns = ['fox', 'owl', 'hawk', 'wolf', 'bear', 'eagle', 'lion', 'tiger'];
        
        $adj = $adjectives[array_rand($adjectives)];
        $noun = $nouns[array_rand($nouns)];
        $num = rand(1000, 9999);
        
        return $adj . $noun . $num;
    }
    
    // Validate IRC commands like Swift ChatViewModel
    public static function isValidCommand($command) {
        $validCommands = [
            '/help', '/j', '/join', '/leave', '/m', '/msg', 
            '/w', '/who', '/channels', '/clear', '/nick', 
            '/block', '/unblock', '/favorite', '/back', '/pass'
        ];
        
        $cmd = explode(' ', trim($command))[0];
        return in_array($cmd, $validCommands);
    }
    
    // Parse IRC command like Swift implementation
    public static function parseCommand($command) {
        $parts = explode(' ', trim($command));
        $cmd = array_shift($parts);
        
        return [
            'command' => $cmd,
            'args' => $parts,
            'raw' => $command
        ];
    }
    
    // Channel validation like Swift app
    public static function validateChannelName($name) {
        // Must start with # and be reasonable length
        if (!preg_match('/^#[a-zA-Z0-9_-]{1,30}$/', $name)) {
            return false;
        }
        return true;
    }
    
    // Nickname validation like Swift app
    public static function validateNickname($nickname) {
        // No @ symbol, reasonable length, alphanumeric + underscore
        if (!preg_match('/^[a-zA-Z0-9_]{1,32}$/', $nickname)) {
            return false;
        }
        return true;
    }
    
    // Message content validation
    public static function validateMessageContent($content) {
        $length = strlen($content);
        return $length > 0 && $length <= MAX_MESSAGE_LENGTH;
    }
    
    // Encryption key derivation like Swift CryptoKit
    public static function deriveChannelKey($password, $channelName) {
        $salt = 'bitchat-' . $channelName;
        $keyLength = 32; // 256 bits
        
        return hash_pbkdf2('sha256', $password, $salt, PBKDF2_ITERATIONS, $keyLength, true);
    }
    
    // Compute key commitment like Swift implementation
    public static function computeKeyCommitment($key) {
        return hash('sha256', $key);
    }
    
    // Simple encryption for demo (Swift uses AES-256-GCM)
    public static function encryptMessage($message, $key) {
        $iv = random_bytes(16);
        $encrypted = openssl_encrypt($message, 'AES-256-CBC', $key, OPENSSL_RAW_DATA, $iv);
        return base64_encode($iv . $encrypted);
    }
    
    // Simple decryption
    public static function decryptMessage($encryptedData, $key) {
        $data = base64_decode($encryptedData);
        $iv = substr($data, 0, 16);
        $encrypted = substr($data, 16);
        
        return openssl_decrypt($encrypted, 'AES-256-CBC', $key, OPENSSL_RAW_DATA, $iv);
    }
    
    // Rate limiting like Swift app's performance optimizations
    public static function checkRateLimit($identifier, $action, $limit, $window = 60) {
        $key = "rate_limit_{$action}_{$identifier}";
        $current = apcu_fetch($key, $success);
        
        if (!$success) {
            $current = 0;
        }
        
        if ($current >= $limit) {
            return false;
        }
        
        apcu_store($key, $current + 1, $window);
        return true;
    }
    
    // User fingerprint generation like Swift app
    public static function generateUserFingerprint($nickname, $timestamp = null) {
        $timestamp = $timestamp ?: time();
        $data = $nickname . $timestamp . bin2hex(random_bytes(8));
        return hash('sha256', $data);
    }
    
    // Message TTL checking like Swift mesh routing
    public static function decrementTTL($message) {
        if (!isset($message['ttl'])) {
            $message['ttl'] = 7;
        }
        
        $message['ttl']--;
        return $message;
    }
    
    // Check if message should be relayed
    public static function shouldRelayMessage($message) {
        return isset($message['ttl']) && $message['ttl'] > 0;
    }
    
    // Convert timestamp formats between Swift and PHP
    public static function swiftTimestampToPhp($swiftTimestamp) {
        // Swift uses milliseconds since epoch
        return intval($swiftTimestamp / 1000);
    }
    
    public static function phpTimestampToSwift($phpTimestamp) {
        // Convert to milliseconds
        return $phpTimestamp * 1000;
    }
    
    // Emergency wipe functionality like Swift app
    public static function performEmergencyWipe($userId) {
        try {
            $pdo = getDatabase();
            
            // Begin transaction
            $pdo->beginTransaction();
            
            // Delete user's messages
            $stmt = $pdo->prepare("DELETE FROM messages WHERE sender_id = ?");
            $stmt->execute([$userId]);
            
            // Remove from channels
            $stmt = $pdo->prepare("DELETE FROM channel_members WHERE user_id = ?");
            $stmt->execute([$userId]);
            
            // Clear blocked users list
            $stmt = $pdo->prepare("DELETE FROM blocked_users WHERE blocker_id = ? OR blocked_id = ?");
            $stmt->execute([$userId, $userId]);
            
            // Mark user as wiped but keep minimal record
            $stmt = $pdo->prepare("UPDATE users SET nickname = ?, fingerprint = NULL, is_blocked = TRUE WHERE id = ?");
            $stmt->execute(['[WIPED]', $userId]);
            
            $pdo->commit();
            
            logMessage('INFO', 'Emergency wipe performed', ['user_id' => $userId]);
            return true;
            
        } catch (Exception $e) {
            $pdo->rollback();
            logMessage('ERROR', 'Emergency wipe failed', ['user_id' => $userId, 'error' => $e->getMessage()]);
            return false;
        }
    }
    
    // Channel ownership verification like Swift app
    public static function isChannelOwner($userId, $channelId) {
        try {
            $pdo = getDatabase();
            $stmt = $pdo->prepare("SELECT creator_id FROM channels WHERE id = ?");
            $stmt->execute([$channelId]);
            $channel = $stmt->fetch();
            
            return $channel && $channel['creator_id'] == $userId;
        } catch (Exception $e) {
            logMessage('ERROR', 'Channel ownership check failed', ['error' => $e->getMessage()]);
            return false;
        }
    }
    
    // Format message for display like Swift app
    public static function formatMessageForDisplay($message, $currentUser = null) {
        $timestamp = date('H:i', $message['timestamp'] / 1000);
        $sender = $message['sender'];
        $content = $message['content'];
        
        // Add relay indicator
        $relayIndicator = $message['isRelay'] ? ' (relayed)' : '';
        
        // Add encryption indicator
        $encryptionIndicator = $message['isEncrypted'] ? ' 🔒' : '';
        
        // Format mentions
        $content = preg_replace('/@(\w+)/', '<span class="mention">@$1</span>', $content);
        
        return [
            'timestamp' => $timestamp,
            'sender' => $sender . $relayIndicator . $encryptionIndicator,
            'content' => $content,
            'isOwn' => $currentUser && $sender === $currentUser,
            'isSystem' => $sender === 'system'
        ];
    }
    
    // Health check for Swift app compatibility
    public static function checkSwiftCompatibility() {
        $checks = [
            'encryption' => function_exists('openssl_encrypt'),
            'random_bytes' => function_exists('random_bytes'),
            'hash_pbkdf2' => function_exists('hash_pbkdf2'),
            'json_encode' => function_exists('json_encode'),
            'database' => class_exists('PDO'),
            'apcu' => extension_loaded('apcu')
        ];
        
        $results = [];
        foreach ($checks as $check => $result) {
            $results[$check] = is_callable($result) ? $result() : $result;
        }
        
        return $results;
    }
}
?>