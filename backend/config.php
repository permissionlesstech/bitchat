<?php
/**
 * Bitchat Live Backend Configuration
 * Production settings for bitchat.live deployment
 */

// Database Configuration
define('DB_HOST', getenv('DB_HOST') ?: 'mysql-service');
define('DB_NAME', getenv('DB_NAME') ?: 'bitchat');
define('DB_USER', getenv('DB_USER') ?: 'bitchat_user');
define('DB_PASS', getenv('DB_PASS') ?: 'secure_password_here');
define('DB_PORT', getenv('DB_PORT') ?: 3306);

// IRC Server Configuration
define('IRC_HOST', 'irc.bitchat.xyz');
define('IRC_PORT', 6697);
define('IRC_SSL', true);

// Block.xyz Integration
define('BLOCK_XYZ_URL', 'https://block.xyz');
define('BLOCK_XYZ_API_KEY', getenv('BLOCK_XYZ_API_KEY') ?: '');

// Security Settings - matching Swift app
define('AES_KEY_LENGTH', 256);
define('PBKDF2_ITERATIONS', 100000);
define('SESSION_TIMEOUT', 3600); // 1 hour
define('MESSAGE_EXPIRY', 86400); // 24 hours
define('MAX_MESSAGE_LENGTH', 4096);
define('MAX_NICKNAME_LENGTH', 32);

// Rate Limiting - based on Swift app's performance settings
define('RATE_LIMIT_MESSAGES_PER_MINUTE', 30);
define('RATE_LIMIT_JOINS_PER_HOUR', 10);
define('RATE_LIMIT_CONNECTIONS_PER_IP', 5);

// Swift App Feature Flags - maintain compatibility
define('FEATURE_MESH_NETWORKING', true);
define('FEATURE_ENCRYPTION', true);
define('FEATURE_CHANNELS', true);
define('FEATURE_PRIVATE_MESSAGES', true);
define('FEATURE_USER_BLOCKING', true);
define('FEATURE_MESSAGE_RETENTION', true);
define('FEATURE_EMERGENCY_WIPE', true);

// Logging
define('LOG_LEVEL', getenv('LOG_LEVEL') ?: 'INFO');
define('LOG_FILE', '/var/log/bitchat/app.log');

// Production Settings
define('ENVIRONMENT', getenv('ENVIRONMENT') ?: 'production');
define('DEBUG', ENVIRONMENT === 'development');
define('API_VERSION', '1.0.0');

// CORS Settings
define('ALLOWED_ORIGINS', [
    'https://bitchat.live',
    'https://www.bitchat.live',
    'https://app.bitchat.live'
]);

// Swift App Command Mapping - for API compatibility
define('SWIFT_COMMANDS', [
    'help' => '/help',
    'join' => '/j',
    'leave' => '/leave',
    'message' => '/m',
    'who' => '/w',
    'channels' => '/channels',
    'clear' => '/clear',
    'nick' => '/nick',
    'block' => '/block',
    'unblock' => '/unblock',
    'favorite' => '/favorite',
    'back' => '/back',
    'pass' => '/pass'
]);

// Database Schema - matching Swift app's data models
$DB_SCHEMA = [
    'users' => [
        'id' => 'INT AUTO_INCREMENT PRIMARY KEY',
        'nickname' => 'VARCHAR(32) UNIQUE NOT NULL',
        'fingerprint' => 'VARCHAR(64)',
        'last_seen' => 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
        'created_at' => 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
        'is_blocked' => 'BOOLEAN DEFAULT FALSE'
    ],
    'channels' => [
        'id' => 'INT AUTO_INCREMENT PRIMARY KEY',
        'name' => 'VARCHAR(64) UNIQUE NOT NULL',
        'creator_id' => 'INT',
        'password_hash' => 'VARCHAR(255)',
        'is_password_protected' => 'BOOLEAN DEFAULT FALSE',
        'retention_enabled' => 'BOOLEAN DEFAULT FALSE',
        'created_at' => 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP'
    ],
    'messages' => [
        'id' => 'INT AUTO_INCREMENT PRIMARY KEY',
        'message_id' => 'VARCHAR(64) UNIQUE NOT NULL',
        'sender_id' => 'INT',
        'channel_id' => 'INT NULL',
        'content' => 'TEXT NOT NULL',
        'is_private' => 'BOOLEAN DEFAULT FALSE',
        'is_encrypted' => 'BOOLEAN DEFAULT FALSE',
        'ttl' => 'INT DEFAULT 7',
        'timestamp' => 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
        'expires_at' => 'TIMESTAMP NULL'
    ],
    'channel_members' => [
        'channel_id' => 'INT',
        'user_id' => 'INT',
        'joined_at' => 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
        'PRIMARY KEY' => '(channel_id, user_id)'
    ],
    'blocked_users' => [
        'blocker_id' => 'INT',
        'blocked_id' => 'INT',
        'blocked_at' => 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
        'PRIMARY KEY' => '(blocker_id, blocked_id)'
    ]
];

// Error handling
function handleError($errno, $errstr, $errfile, $errline) {
    if (!(error_reporting() & $errno)) {
        return false;
    }
    
    $message = "Error: [$errno] $errstr in $errfile on line $errline";
    error_log($message);
    
    if (DEBUG) {
        echo $message . "\n";
    }
    
    return true;
}

set_error_handler('handleError');

// Database connection helper
function getDatabase() {
    static $pdo = null;
    
    if ($pdo === null) {
        try {
            $dsn = "mysql:host=" . DB_HOST . ";dbname=" . DB_NAME . ";port=" . DB_PORT . ";charset=utf8mb4";
            $options = [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false
            ];
            
            $pdo = new PDO($dsn, DB_USER, DB_PASS, $options);
        } catch (PDOException $e) {
            error_log("Database connection failed: " . $e->getMessage());
            throw new Exception("Database connection failed");
        }
    }
    
    return $pdo;
}

// Logging helper
function logMessage($level, $message, $context = []) {
    $levels = ['DEBUG', 'INFO', 'WARNING', 'ERROR'];
    
    if (array_search($level, $levels) < array_search(LOG_LEVEL, $levels)) {
        return;
    }
    
    $logEntry = [
        'timestamp' => date('Y-m-d H:i:s'),
        'level' => $level,
        'message' => $message,
        'context' => $context
    ];
    
    $logLine = json_encode($logEntry) . "\n";
    
    if (DEBUG) {
        echo $logLine;
    } else {
        error_log($logLine, 3, LOG_FILE);
    }
}
?>