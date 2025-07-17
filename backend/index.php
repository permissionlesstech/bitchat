<?php
/**
 * Bitchat Live Backend API
 * PHP implementation based on Swift BitchatApp.swift architecture
 * 
 * Provides REST API endpoints for the web frontend
 * Maintains compatibility with Swift app features
 */

header('Access-Control-Allow-Origin: https://bitchat.live');
header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With');
header('Content-Type: application/json');

// Handle preflight requests
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit();
}

require_once 'config.php';
require_once 'classes/SwiftCompatibility.php';
require_once 'classes/MessageHandler.php';
require_once 'classes/UserManager.php';
require_once 'classes/ChannelManager.php';
require_once 'classes/CryptoService.php';

// Route the request
$requestUri = $_SERVER['REQUEST_URI'];
$requestMethod = $_SERVER['REQUEST_METHOD'];

// Remove query string and decode
$path = parse_url($requestUri, PHP_URL_PATH);
$path = urldecode($path);

// Remove leading slash and split into segments
$segments = array_filter(explode('/', trim($path, '/')));

// API routing - mirroring Swift app's service structure
try {
    if (count($segments) >= 2 && $segments[0] === 'api') {
        $endpoint = $segments[1];
        
        switch ($endpoint) {
            case 'auth':
                handleAuth($requestMethod, $segments);
                break;
                
            case 'messages':
                handleMessages($requestMethod, $segments);
                break;
                
            case 'channels':
                handleChannels($requestMethod, $segments);
                break;
                
            case 'users':
                handleUsers($requestMethod, $segments);
                break;
                
            case 'block':
                handleBlock($requestMethod, $segments);
                break;
                
            case 'health':
                handleHealth();
                break;
                
            default:
                http_response_code(404);
                echo json_encode(['error' => 'Endpoint not found']);
        }
    } else {
        // Serve the web app
        serveWebApp();
    }
} catch (Exception $e) {
    error_log("API Error: " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['error' => 'Internal server error']);
}

// Auth endpoint - based on Swift app's peer authentication
function handleAuth($method, $segments) {
    switch ($method) {
        case 'POST':
            $input = json_decode(file_get_contents('php://input'), true);
            
            if (!isset($input['nickname'])) {
                http_response_code(400);
                echo json_encode(['error' => 'Nickname required']);
                return;
            }
            
            $userManager = new UserManager();
            $result = $userManager->authenticateUser($input['nickname'], $input['fingerprint'] ?? null);
            
            echo json_encode($result);
            break;
            
        default:
            http_response_code(405);
            echo json_encode(['error' => 'Method not allowed']);
    }
}

// Messages endpoint - based on Swift ChatViewModel message handling
function handleMessages($method, $segments) {
    switch ($method) {
        case 'GET':
            $messageHandler = new MessageHandler();
            $channel = $_GET['channel'] ?? null;
            $since = $_GET['since'] ?? null;
            $limit = min(100, $_GET['limit'] ?? 50);
            
            $messages = $messageHandler->getMessages($channel, $since, $limit);
            echo json_encode(['messages' => $messages]);
            break;
            
        case 'POST':
            $input = json_decode(file_get_contents('php://input'), true);
            
            $required = ['content', 'sender'];
            foreach ($required as $field) {
                if (!isset($input[$field])) {
                    http_response_code(400);
                    echo json_encode(['error' => "$field is required"]);
                    return;
                }
            }
            
            $messageHandler = new MessageHandler();
            $result = $messageHandler->sendMessage(
                $input['content'],
                $input['sender'],
                $input['channel'] ?? null,
                $input['isPrivate'] ?? false,
                $input['encrypted'] ?? false
            );
            
            echo json_encode($result);
            break;
            
        default:
            http_response_code(405);
            echo json_encode(['error' => 'Method not allowed']);
    }
}

// Channels endpoint - based on Swift app's channel management
function handleChannels($method, $segments) {
    switch ($method) {
        case 'GET':
            $channelManager = new ChannelManager();
            $channels = $channelManager->getChannels();
            echo json_encode(['channels' => $channels]);
            break;
            
        case 'POST':
            $input = json_decode(file_get_contents('php://input'), true);
            
            if (!isset($input['name'])) {
                http_response_code(400);
                echo json_encode(['error' => 'Channel name required']);
                return;
            }
            
            $channelManager = new ChannelManager();
            $result = $channelManager->createChannel(
                $input['name'],
                $input['creator'],
                $input['password'] ?? null
            );
            
            echo json_encode($result);
            break;
            
        default:
            http_response_code(405);
            echo json_encode(['error' => 'Method not allowed']);
    }
}

// Users endpoint - based on Swift app's peer management
function handleUsers($method, $segments) {
    switch ($method) {
        case 'GET':
            $userManager = new UserManager();
            $users = $userManager->getOnlineUsers();
            echo json_encode(['users' => $users]);
            break;
            
        default:
            http_response_code(405);
            echo json_encode(['error' => 'Method not allowed']);
    }
}

// Block endpoint - integrates with block.xyz
function handleBlock($method, $segments) {
    switch ($method) {
        case 'POST':
            $input = json_decode(file_get_contents('php://input'), true);
            
            $required = ['type', 'target', 'reporter'];
            foreach ($required as $field) {
                if (!isset($input[$field])) {
                    http_response_code(400);
                    echo json_encode(['error' => "$field is required"]);
                    return;
                }
            }
            
            // Forward to block.xyz
            $blockResult = forwardToBlockServer($input);
            
            // Also store locally
            $userManager = new UserManager();
            $localResult = $userManager->blockUser($input['target'], $input['reporter']);
            
            echo json_encode([
                'success' => true,
                'block_server' => $blockResult,
                'local' => $localResult
            ]);
            break;
            
        case 'GET':
            $userManager = new UserManager();
            $blocked = $userManager->getBlockedUsers($_GET['user'] ?? null);
            echo json_encode(['blocked' => $blocked]);
            break;
            
        default:
            http_response_code(405);
            echo json_encode(['error' => 'Method not allowed']);
    }
}

// Health check endpoint
function handleHealth() {
    $status = [
        'status' => 'healthy',
        'timestamp' => time(),
        'version' => '1.0.0',
        'services' => [
            'database' => checkDatabase(),
            'irc' => checkIRCConnection(),
            'block_xyz' => checkBlockXYZ()
        ]
    ];
    
    echo json_encode($status);
}

// Forward request to block.xyz
function forwardToBlockServer($data) {
    $blockUrl = 'https://block.xyz/api/report';
    
    $options = [
        'http' => [
            'header' => "Content-type: application/json\r\n",
            'method' => 'POST',
            'content' => json_encode($data)
        ]
    ];
    
    $context = stream_context_create($options);
    $result = file_get_contents($blockUrl, false, $context);
    
    return json_decode($result, true);
}

// Service health checks
function checkDatabase() {
    try {
        $pdo = new PDO(
            "mysql:host=" . DB_HOST . ";dbname=" . DB_NAME,
            DB_USER,
            DB_PASS
        );
        return 'connected';
    } catch (PDOException $e) {
        return 'error: ' . $e->getMessage();
    }
}

function checkIRCConnection() {
    // Check if IRC server is reachable
    $socket = @fsockopen('irc.bitchat.xyz', 6697, $errno, $errstr, 5);
    if ($socket) {
        fclose($socket);
        return 'reachable';
    }
    return 'unreachable: ' . $errstr;
}

function checkBlockXYZ() {
    $headers = @get_headers('https://block.xyz/api/health');
    return $headers && strpos($headers[0], '200') ? 'reachable' : 'unreachable';
}

// Serve web application files
function serveWebApp() {
    $webRoot = __DIR__ . '/../web/';
    $requestedFile = $_SERVER['REQUEST_URI'];
    
    // Default to index.html
    if ($requestedFile === '/') {
        $requestedFile = '/index.html';
    }
    
    $filePath = $webRoot . ltrim($requestedFile, '/');
    
    if (file_exists($filePath) && is_file($filePath)) {
        $mimeType = getMimeType($filePath);
        header("Content-Type: $mimeType");
        readfile($filePath);
    } else {
        // Fallback to index.html for SPA routing
        header("Content-Type: text/html");
        readfile($webRoot . 'index.html');
    }
}

function getMimeType($filename) {
    $extension = pathinfo($filename, PATHINFO_EXTENSION);
    
    $mimeTypes = [
        'html' => 'text/html',
        'css' => 'text/css',
        'js' => 'application/javascript',
        'json' => 'application/json',
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'svg' => 'image/svg+xml',
        'ico' => 'image/x-icon'
    ];
    
    return $mimeTypes[$extension] ?? 'application/octet-stream';
}
?>