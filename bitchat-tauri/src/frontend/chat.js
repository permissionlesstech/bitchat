/**
 * BitChat Frontend JavaScript
 * 
 * Handles UI interactions and communication with the Tauri backend.
 * Follows AI Guidance Protocol for ethical frontend development.
 */

// Tauri API imports
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// Application state
let appState = {
    isConnected: false,
    currentChannel: 'public',
    nickname: 'Anonymous',
    peers: [],
    messages: [],
    preferences: {},
    sidebarVisible: false,
    typingUsers: new Set(),
    unreadCounts: new Map(),
};

// DOM elements (cached for performance)
const elements = {};

// Initialize application
document.addEventListener('DOMContentLoaded', function() {
    initializeElements();
    initializeEventListeners();
    initializeApp();
});

// Cache DOM elements
function initializeElements() {
    elements.sidebarToggle = document.getElementById('sidebar-toggle');
    elements.sidebar = document.getElementById('sidebar');
    elements.connectionStatus = document.getElementById('connection-status');
    elements.peerCount = document.getElementById('peer-count');
    elements.channelList = document.getElementById('channel-list');
    elements.privateList = document.getElementById('private-list');
    elements.peerList = document.getElementById('peer-list');
    elements.chatTitle = document.getElementById('chat-title');
    elements.memberCount = document.getElementById('member-count');
    elements.messagesList = document.getElementById('messages-list');
    elements.messageInput = document.getElementById('message-input');
    elements.sendButton = document.getElementById('send-button');
    elements.typingIndicators = document.getElementById('typing-indicators');
    elements.loadingOverlay = document.getElementById('loading-overlay');
    elements.toastContainer = document.getElementById('toast-container');
    
    // Modal elements
    elements.joinChannelModal = document.getElementById('join-channel-modal');
    elements.settingsModal = document.getElementById('settings-modal');
    elements.searchModal = document.getElementById('search-modal');
    
    // Settings elements
    elements.nicknameInput = document.getElementById('nickname-input');
    elements.autoConnectCheckbox = document.getElementById('auto-connect-checkbox');
    elements.saveHistoryCheckbox = document.getElementById('save-history-checkbox');
    elements.themeSelect = document.getElementById('theme-select');
    elements.fontSizeSlider = document.getElementById('font-size-slider');
    elements.fontSizeValue = document.getElementById('font-size-value');
    elements.encryptionEnabledCheckbox = document.getElementById('encryption-enabled-checkbox');
    elements.enhancedCryptoCheckbox = document.getElementById('enhanced-crypto-checkbox');
}

// Initialize event listeners
function initializeEventListeners() {
    // Sidebar toggle
    elements.sidebarToggle.addEventListener('click', toggleSidebar);
    
    // Message input
    elements.messageInput.addEventListener('keydown', handleMessageInputKeydown);
    elements.messageInput.addEventListener('input', handleMessageInputChange);
    elements.sendButton.addEventListener('click', sendMessage);
    
    // Channel management
    document.getElementById('add-channel-btn').addEventListener('click', () => showModal('join-channel-modal'));
    document.getElementById('join-channel-confirm').addEventListener('click', joinChannel);
    
    // Settings
    document.getElementById('settings-button').addEventListener('click', () => showModal('settings-modal'));
    document.getElementById('save-settings-button').addEventListener('click', saveSettings);
    
    // Search
    document.getElementById('search-button').addEventListener('click', () => showModal('search-modal'));
    document.getElementById('search-execute-button').addEventListener('click', executeSearch);
    
    // Modal close buttons
    document.querySelectorAll('.close-button, [data-modal]').forEach(button => {
        button.addEventListener('click', (e) => {
            const modalId = button.getAttribute('data-modal') || button.closest('.modal').id;
            hideModal(modalId);
        });
    });
    
    // Settings tabs
    document.querySelectorAll('.tab-button').forEach(button => {
        button.addEventListener('click', (e) => {
            switchTab(button.getAttribute('data-tab'));
        });
    });
    
    // Font size slider
    elements.fontSizeSlider.addEventListener('input', (e) => {
        const size = e.target.value;
        elements.fontSizeValue.textContent = `${size}px`;
        document.documentElement.style.setProperty('--font-size-md', `${size}px`);
    });
    
    // Emergency wipe button
    document.getElementById('emergency-wipe-button').addEventListener('click', confirmEmergencyWipe);
    
    // Auto-resize message input
    elements.messageInput.addEventListener('input', autoResizeTextarea);
}

// Initialize the application
async function initializeApp() {
    showLoading('Initializing BitChat...');
    
    try {
        // Load application state
        await loadAppState();
        
        // Start Bluetooth service
        await startBluetoothService();
        
        // Load message history
        await loadMessageHistory();
        
        // Setup periodic updates
        setupPeriodicUpdates();
        
        hideLoading();
        showToast('BitChat initialized successfully', 'success');
        
    } catch (error) {
        console.error('Failed to initialize app:', error);
        hideLoading();
        showToast(`Initialization failed: ${error}`, 'error');
    }
}

// Load application state from backend
async function loadAppState() {
    try {
        const state = await invoke('get_app_state');
        
        if (state.preferences) {
            appState.preferences = state.preferences;
            applyPreferences(state.preferences);
        }
        
        if (state.chat) {
            appState.currentChannel = state.chat.current_channel || 'public';
            appState.sidebarVisible = state.chat.sidebar_open || false;
        }
        
        console.log('App state loaded:', state);
    } catch (error) {
        console.error('Failed to load app state:', error);
    }
}

// Apply user preferences to UI
function applyPreferences(preferences) {
    if (preferences.nickname) {
        appState.nickname = preferences.nickname;
        elements.nicknameInput.value = preferences.nickname;
    }
    
    if (preferences.appearance) {
        const appearance = preferences.appearance;
        
        // Apply theme
        if (appearance.theme) {
            document.body.className = `theme-${appearance.theme}`;
            elements.themeSelect.value = appearance.theme;
        }
        
        // Apply font size
        if (appearance.font_size) {
            document.documentElement.style.setProperty('--font-size-md', `${appearance.font_size}px`);
            elements.fontSizeSlider.value = appearance.font_size;
            elements.fontSizeValue.textContent = `${appearance.font_size}px`;
        }
    }
    
    // Apply boolean preferences
    elements.autoConnectCheckbox.checked = preferences.auto_connect || false;
    elements.saveHistoryCheckbox.checked = preferences.save_message_history || false;
    elements.encryptionEnabledCheckbox.checked = preferences.encryption_enabled || false;
    elements.enhancedCryptoCheckbox.checked = preferences.enhanced_crypto_enabled || false;
}

// Start Bluetooth mesh service
async function startBluetoothService() {
    try {
        const result = await invoke('start_bluetooth_service');
        console.log('Bluetooth service started:', result);
        
        updateConnectionStatus(true);
        
        // Start polling for peer updates
        startPeerPolling();
        
    } catch (error) {
        console.error('Failed to start Bluetooth service:', error);
        updateConnectionStatus(false);
        throw error;
    }
}

// Update connection status in UI
function updateConnectionStatus(connected) {
    appState.isConnected = connected;
    
    const statusIndicator = elements.connectionStatus.querySelector('.status-indicator');
    const statusText = elements.connectionStatus.querySelector('.status-text');
    
    if (connected) {
        statusIndicator.className = 'status-indicator online';
        statusText.textContent = 'Connected';
    } else {
        statusIndicator.className = 'status-indicator offline';
        statusText.textContent = 'Disconnected';
    }
}

// Start periodic peer list updates
function startPeerPolling() {
    setInterval(async () => {
        try {
            const peerList = await invoke('get_peer_list');
            updatePeerList(peerList);
            
            const stats = await invoke('get_statistics');
            updatePeerCount(stats);
            
        } catch (error) {
            console.error('Failed to update peer list:', error);
        }
    }, 5000); // Update every 5 seconds
}

// Update peer list in sidebar
function updatePeerList(peerList) {
    appState.peers = peerList;
    
    elements.peerList.innerHTML = '';
    
    if (Array.isArray(peerList)) {
        peerList.forEach(peer => {
            const peerElement = createPeerElement(peer);
            elements.peerList.appendChild(peerElement);
        });
    }
}

// Create peer list element
function createPeerElement(peer) {
    const div = document.createElement('div');
    div.className = 'peer-item';
    div.setAttribute('data-peer-id', peer.peer_id);
    
    const name = document.createElement('span');
    name.className = 'peer-name';
    name.textContent = peer.nickname || 'Anonymous';
    
    const status = document.createElement('span');
    status.className = `peer-status ${peer.is_online ? 'online' : 'offline'}`;
    status.textContent = peer.is_online ? '●' : '○';
    
    div.appendChild(name);
    div.appendChild(status);
    
    // Click to start private message
    div.addEventListener('click', () => {
        startPrivateMessage(peer.nickname);
    });
    
    return div;
}

// Update peer count display
function updatePeerCount(stats) {
    const count = stats.peer_statistics?.online_peers || 0;
    elements.peerCount.querySelector('.count').textContent = count;
}

// Load message history
async function loadMessageHistory() {
    try {
        const history = await invoke('get_message_history', {
            channel: appState.currentChannel === 'public' ? null : appState.currentChannel,
            limit: 50
        });
        
        if (history.messages) {
            appState.messages = history.messages;
            renderMessages();
        }
        
    } catch (error) {
        console.error('Failed to load message history:', error);
    }
}

// Render messages in the chat area
function renderMessages() {
    elements.messagesList.innerHTML = '';
    
    appState.messages.forEach(message => {
        const messageElement = createMessageElement(message);
        elements.messagesList.appendChild(messageElement);
    });
    
    // Scroll to bottom
    scrollToBottom();
}

// Create message element
function createMessageElement(message) {
    const div = document.createElement('div');
    div.className = `message ${getMessageClass(message)}`;
    div.setAttribute('data-message-id', message.id);
    
    const header = document.createElement('div');
    header.className = 'message-header';
    
    const sender = document.createElement('span');
    sender.className = 'sender-name';
    sender.textContent = message.sender || 'Anonymous';
    
    const time = document.createElement('span');
    time.className = 'message-time';
    time.textContent = formatMessageTime(message.timestamp);
    
    header.appendChild(sender);
    header.appendChild(time);
    
    const content = document.createElement('div');
    content.className = 'message-content';
    content.textContent = message.content;
    
    // Process mentions
    content.innerHTML = processMentions(content.innerHTML);
    
    div.appendChild(header);
    div.appendChild(content);
    
    return div;
}

// Get CSS class for message type
function getMessageClass(message) {
    let className = '';
    
    if (message.sender === appState.nickname) {
        className += 'own ';
    }
    
    if (message.type === 'Private') {
        className += 'private ';
    } else if (message.type === 'System') {
        className += 'system ';
    }
    
    return className.trim();
}

// Format message timestamp
function formatMessageTime(timestamp) {
    const date = new Date(timestamp);
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// Process @mentions in message content
function processMentions(content) {
    return content.replace(/@(\w+)/g, '<span class="mention">@$1</span>');
}

// Scroll messages to bottom
function scrollToBottom() {
    elements.messagesList.scrollTop = elements.messagesList.scrollHeight;
}

// Handle message input keydown
function handleMessageInputKeydown(e) {
    if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
    }
}

// Handle message input change (for typing indicators)
function handleMessageInputChange(e) {
    // TODO: Implement typing indicators
}

// Auto-resize textarea
function autoResizeTextarea() {
    const textarea = elements.messageInput;
    textarea.style.height = 'auto';
    textarea.style.height = Math.min(textarea.scrollHeight, 120) + 'px';
}

// Send message
async function sendMessage() {
    const content = elements.messageInput.value.trim();
    
    if (!content) {
        return;
    }
    
    if (!appState.isConnected) {
        showToast('Not connected to mesh network', 'error');
        return;
    }
    
    try {
        elements.sendButton.disabled = true;
        
        // Check if it's a command
        if (content.startsWith('/')) {
            await handleCommand(content);
        } else {
            // Send regular message
            const channel = appState.currentChannel === 'public' ? null : appState.currentChannel;
            await invoke('send_message', { content, channel });
            
            // Add to local messages immediately for responsive UI
            const message = {
                id: generateMessageId(),
                sender: appState.nickname,
                content: content,
                timestamp: new Date().toISOString(),
                type: channel ? 'Channel' : 'Broadcast'
            };
            
            appState.messages.push(message);
            const messageElement = createMessageElement(message);
            elements.messagesList.appendChild(messageElement);
            scrollToBottom();
        }
        
        // Clear input
        elements.messageInput.value = '';
        autoResizeTextarea();
        
    } catch (error) {
        console.error('Failed to send message:', error);
        showToast(`Failed to send message: ${error}`, 'error');
    } finally {
        elements.sendButton.disabled = false;
    }
}

// Handle chat commands
async function handleCommand(command) {
    const parts = command.split(' ');
    const cmd = parts[0].toLowerCase();
    
    try {
        switch (cmd) {
            case '/join':
            case '/j':
                if (parts[1]) {
                    const channelName = parts[1].replace('#', '');
                    await joinChannelByName(channelName);
                } else {
                    showToast('Usage: /join #channel', 'error');
                }
                break;
                
            case '/msg':
            case '/m':
                if (parts[1] && parts[2]) {
                    const recipient = parts[1].replace('@', '');
                    const content = parts.slice(2).join(' ');
                    await invoke('send_private_message', { recipient, content });
                    showToast(`Private message sent to ${recipient}`, 'success');
                } else {
                    showToast('Usage: /msg @user message', 'error');
                }
                break;
                
            case '/who':
            case '/w':
                showPeerList();
                break;
                
            case '/clear':
                clearMessages();
                break;
                
            case '/help':
                showHelp();
                break;
                
            default:
                showToast(`Unknown command: ${cmd}`, 'error');
                break;
        }
    } catch (error) {
        console.error('Command error:', error);
        showToast(`Command failed: ${error}`, 'error');
    }
}

// Join channel by name
async function joinChannelByName(channelName, password = null) {
    try {
        await invoke('join_channel', { channelName, password });
        
        // Add channel to sidebar
        addChannelToSidebar(channelName);
        
        // Switch to channel
        switchToChannel(channelName);
        
        showToast(`Joined channel: #${channelName}`, 'success');
        
    } catch (error) {
        console.error('Failed to join channel:', error);
        showToast(`Failed to join channel: ${error}`, 'error');
    }
}

// Add channel to sidebar
function addChannelToSidebar(channelName) {
    const existing = elements.channelList.querySelector(`[data-channel="${channelName}"]`);
    if (existing) {
        return; // Channel already exists
    }
    
    const div = document.createElement('div');
    div.className = 'channel-item';
    div.setAttribute('data-channel', channelName);
    
    const name = document.createElement('span');
    name.className = 'channel-name';
    name.textContent = `# ${channelName}`;
    
    const unread = document.createElement('span');
    unread.className = 'unread-count zero';
    unread.id = `${channelName}-unread`;
    unread.textContent = '0';
    
    div.appendChild(name);
    div.appendChild(unread);
    
    div.addEventListener('click', () => switchToChannel(channelName));
    
    elements.channelList.appendChild(div);
}

// Switch to a channel
function switchToChannel(channelName) {
    appState.currentChannel = channelName;
    
    // Update UI
    updateChannelSelection();
    updateChatTitle();
    loadMessageHistory();
}

// Update channel selection in sidebar
function updateChannelSelection() {
    elements.channelList.querySelectorAll('.channel-item').forEach(item => {
        item.classList.remove('active');
        if (item.getAttribute('data-channel') === appState.currentChannel) {
            item.classList.add('active');
        }
    });
}

// Update chat title
function updateChatTitle() {
    const titleElement = elements.chatTitle.querySelector('.channel-name');
    
    if (appState.currentChannel === 'public') {
        titleElement.textContent = '# Public';
    } else {
        titleElement.textContent = `# ${appState.currentChannel}`;
    }
}

// Show peer list in chat
function showPeerList() {
    if (appState.peers.length === 0) {
        addSystemMessage('No peers connected');
        return;
    }
    
    const peerNames = appState.peers.map(peer => `@${peer.nickname || 'Anonymous'}`);
    addSystemMessage(`Online peers: ${peerNames.join(', ')}`);
}

// Add system message to chat
function addSystemMessage(content) {
    const message = {
        id: generateMessageId(),
        sender: 'System',
        content: content,
        timestamp: new Date().toISOString(),
        type: 'System'
    };
    
    const messageElement = createMessageElement(message);
    elements.messagesList.appendChild(messageElement);
    scrollToBottom();
}

// Clear messages
function clearMessages() {
    elements.messagesList.innerHTML = '';
    appState.messages = [];
    addSystemMessage('Messages cleared');
}

// Show help
function showHelp() {
    const helpText = `
Available commands:
/join #channel - Join a channel
/msg @user message - Send private message
/who - List online peers
/clear - Clear messages
/help - Show this help
    `.trim();
    
    addSystemMessage(helpText);
}

// Start private message
function startPrivateMessage(username) {
    elements.messageInput.value = `/msg @${username} `;
    elements.messageInput.focus();
}

// Toggle sidebar
function toggleSidebar() {
    appState.sidebarVisible = !appState.sidebarVisible;
    
    if (appState.sidebarVisible) {
        elements.sidebar.classList.add('visible');
    } else {
        elements.sidebar.classList.remove('visible');
    }
}

// Modal functions
function showModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.add('visible');
        
        // Focus first input
        const firstInput = modal.querySelector('input, textarea, select');
        if (firstInput) {
            firstInput.focus();
        }
    }
}

function hideModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.remove('visible');
    }
}

// Join channel from modal
async function joinChannel() {
    const channelName = document.getElementById('channel-name-input').value.trim().replace('#', '');
    const password = document.getElementById('channel-password-input').value.trim() || null;
    
    if (!channelName) {
        showToast('Channel name is required', 'error');
        return;
    }
    
    await joinChannelByName(channelName, password);
    hideModal('join-channel-modal');
    
    // Clear form
    document.getElementById('channel-name-input').value = '';
    document.getElementById('channel-password-input').value = '';
}

// Save settings
async function saveSettings() {
    try {
        const preferences = {
            nickname: elements.nicknameInput.value.trim(),
            auto_connect: elements.autoConnectCheckbox.checked,
            save_message_history: elements.saveHistoryCheckbox.checked,
            encryption_enabled: elements.encryptionEnabledCheckbox.checked,
            enhanced_crypto_enabled: elements.enhancedCryptoCheckbox.checked,
            appearance: {
                theme: elements.themeSelect.value,
                font_size: parseInt(elements.fontSizeSlider.value)
            }
        };
        
        await invoke('update_preferences', { preferences });
        
        // Apply preferences immediately
        applyPreferences(preferences);
        appState.preferences = preferences;
        
        hideModal('settings-modal');
        showToast('Settings saved successfully', 'success');
        
    } catch (error) {
        console.error('Failed to save settings:', error);
        showToast(`Failed to save settings: ${error}`, 'error');
    }
}

// Switch settings tab
function switchTab(tabName) {
    // Update tab buttons
    document.querySelectorAll('.tab-button').forEach(button => {
        button.classList.remove('active');
        if (button.getAttribute('data-tab') === tabName) {
            button.classList.add('active');
        }
    });
    
    // Update tab panels
    document.querySelectorAll('.tab-panel').forEach(panel => {
        panel.classList.remove('active');
        if (panel.id === `${tabName}-tab`) {
            panel.classList.add('active');
        }
    });
}

// Execute search
async function executeSearch() {
    const query = document.getElementById('search-input').value.trim();
    
    if (!query) {
        showToast('Search query is required', 'error');
        return;
    }
    
    try {
        // TODO: Implement search API call
        showToast('Search functionality coming soon', 'info');
        
    } catch (error) {
        console.error('Search failed:', error);
        showToast(`Search failed: ${error}`, 'error');
    }
}

// Confirm emergency wipe
function confirmEmergencyWipe() {
    if (confirm('This will permanently delete ALL data including messages, settings, and peer information. This cannot be undone. Continue?')) {
        performEmergencyWipe();
    }
}

// Perform emergency wipe
async function performEmergencyWipe() {
    try {
        showLoading('Performing emergency wipe...');
        
        // TODO: Implement emergency wipe API call
        
        // Clear local state
        appState.messages = [];
        appState.peers = [];
        
        // Clear UI
        elements.messagesList.innerHTML = '';
        elements.peerList.innerHTML = '';
        elements.channelList.innerHTML = '';
        
        hideLoading();
        hideModal('settings-modal');
        
        showToast('Emergency wipe completed', 'success');
        
    } catch (error) {
        console.error('Emergency wipe failed:', error);
        hideLoading();
        showToast(`Emergency wipe failed: ${error}`, 'error');
    }
}

// Setup periodic updates
function setupPeriodicUpdates() {
    // Update message history every 10 seconds
    setInterval(async () => {
        if (appState.isConnected) {
            try {
                await loadMessageHistory();
            } catch (error) {
                console.error('Failed to update messages:', error);
            }
        }
    }, 10000);
}

// Utility functions
function generateMessageId() {
    return Date.now().toString(36) + Math.random().toString(36).substr(2);
}

function showLoading(text = 'Loading...') {
    elements.loadingOverlay.classList.add('visible');
    elements.loadingOverlay.querySelector('.loading-text').textContent = text;
}

function hideLoading() {
    elements.loadingOverlay.classList.remove('visible');
}

function showToast(message, type = 'info') {
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    toast.textContent = message;
    
    elements.toastContainer.appendChild(toast);
    
    // Auto-remove after 5 seconds
    setTimeout(() => {
        toast.remove();
    }, 5000);
}

// Export for debugging
window.BitChat = {
    appState,
    elements,
    invoke,
    showToast,
    switchToChannel,
    sendMessage
};