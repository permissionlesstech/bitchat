# MorpheusAI Integration FAQ

## BitChat + Morpheus AI Gateway Integration

This document explains how the MorpheusAI bot integrates with BitChat's decentralized Bluetooth mesh network, enabling AI conversations even for devices without internet connectivity.

---

## Quick Reference

### For Users (no setup required)

| Method | Command | Privacy |
|--------|---------|---------|
| **Public AI** | `@MorpheusAI What is Bitcoin?` | Visible to all in mesh |
| **Private AI** | `/msg @BridgeNick !ai What is Bitcoin?` | Encrypted (only you + bridge) |

### For Bridge Operators

```bash
# 1. Set your API key (get one at https://app.mor.org)
/ai-key YOUR_API_KEY_HERE

# 2. Activate the bot
/ai-bridge on

# Other commands
/ai-model glm-4.7:web    # Change AI model
/ai-help                  # Show help
/ai-bridge off            # Deactivate bot
```

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [How It Works](#how-it-works)
4. [Common Questions](#common-questions)
5. [Technical Details](#technical-details)
6. [Limitations](#limitations)
7. [Country Restrictions](#country-restrictions)
8. [Troubleshooting](#troubleshooting)
9. [Image Diagram Prompt](#image-diagram-prompt)

---

## Overview

### What is MorpheusAI?

MorpheusAI is a virtual bot peer that appears in BitChat's mesh network, allowing users to have AI-powered conversations. It connects to the [Morpheus AI Gateway](https://api.mor.org), a decentralized AI inference network.

### Key Features

| Feature | Description |
|---------|-------------|
| **Backward Compatible** | Works with unmodified BitChat clients |
| **Public @Mention** | Simply mention @MorpheusAI in public chat |
| **Private AI via DM** | Send `!ai <question>` in a DM to the bridge for encrypted responses |
| **Mesh Routable** | Reachable from anywhere in the mesh (up to 7 hops) |
| **Per-User Context** | Bot maintains conversation context per user |
| **Global Access** | Available worldwide (no country restrictions) |

---

## Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MORPHEUSAI ARCHITECTURE                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐            │
│  │   Standard   │     │   Standard   │     │   Standard   │            │
│  │   BitChat    │     │   BitChat    │     │   BitChat    │            │
│  │   Client A   │     │   Client B   │     │   Client C   │            │
│  └──────┬───────┘     └──────┬───────┘     └──────┬───────┘            │
│         │                    │                    │                     │
│         │    Bluetooth Mesh Network (encrypted)   │                     │
│         │                    │                    │                     │
│         └────────────────────┼────────────────────┘                     │
│                              │                                          │
│                              ▼                                          │
│                    ┌─────────────────┐                                  │
│                    │  Bridge Device  │                                  │
│                    │  ┌───────────┐  │                                  │
│                    │  │ BitChat   │  │                                  │
│                    │  │ (updated) │  │                                  │
│                    │  └─────┬─────┘  │                                  │
│                    │        │        │                                  │
│                    │  ┌─────▼─────┐  │     ┌─────────────────┐          │
│                    │  │MorpheusAI │  │     │                 │          │
│                    │  │   Bot     │──┼────▶│  api.mor.org    │          │
│                    │  │ (virtual) │  │     │  (Morpheus API) │          │
│                    │  └───────────┘  │     │                 │          │
│                    │                 │     └─────────────────┘          │
│                    │  Has Internet   │                                  │
│                    └─────────────────┘                                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Communication Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MESSAGE FLOW DIAGRAM                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User Device                              Bridge Device                 │
│  (no internet)                            (has internet)                │
│       │                                         │                       │
│       │  1. "@MorpheusAI What is Bitcoin?"      │                       │
│       │─────────────────────────────────────────▶                       │
│       │     (public chat message via mesh)      │                       │
│       │                                         │                       │
│       │                                   2. Bridge detects @mention    │
│       │                                      in public message          │
│       │                                         │                       │
│       │                                   3. HTTPS POST ──────▶ api.mor.org
│       │                                         │                       │
│       │                                   4. AI Response ◀──── api.mor.org
│       │                                         │                       │
│       │  5. "MorpheusAI: Bitcoin is..."         │                       │
│       │◀─────────────────────────────────────────                       │
│       │     (public chat response)              │                       │
│       │                                         │                       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## How It Works

### For Regular Users (Standard BitChat)

#### Public AI (visible to everyone)

1. **@Mention**: Simply type `@MorpheusAI` followed by your question in public chat
2. **Ask Questions**: e.g., `@MorpheusAI What is Bitcoin?`
3. **Receive Answers**: Bot responds in public chat with "MorpheusAI: [response]"
4. **Conversation Context**: Bot remembers recent messages from each user for continuity

#### Private AI (encrypted, only you and the bridge)

1. **Start a DM**: Open a private message with the bridge operator's nickname
2. **Use !ai prefix**: Type `!ai` followed by your question
   - Example: `!ai What is Bitcoin?`
3. **Receive encrypted response**: The AI response comes back as an encrypted DM
4. **End-to-end encrypted**: Only you and the bridge can see the conversation

```
┌─────────────────────────────────────────────────────────────┐
│              PRIVATE AI VIA DM                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [You] ──── DM: "!ai What is Bitcoin?" ────▶ [Bridge]       │
│         (encrypted via Noise Protocol)                       │
│                                                             │
│  [You] ◀──── DM: "Bitcoin is a..." ──────── [Bridge]        │
│         (encrypted response)                                 │
│                                                             │
│  ✅ Only you and bridge can see this conversation           │
│  ✅ Other mesh participants cannot read your queries        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### For Bridge Operators (Updated BitChat)

1. **Requirements**:
   - Device with internet connection
   - Updated BitChat with MorpheusAI integration
   - Morpheus API key from [app.mor.org](https://app.mor.org)
   - Location in an allowed country

2. **Setup**:
   ```
   /ai-key YOUR_API_KEY_HERE
   /ai-bridge on
   ```

3. **Operation**: The bridge automatically:
   - Announces "MorpheusAI" as a virtual peer
   - Handles incoming AI requests
   - Relays responses back to users

---

## Common Questions

### General Usage

#### Q: Do I need to update my BitChat app to talk to MorpheusAI?
**A: No.** Standard BitChat clients can chat with MorpheusAI using `@MorpheusAI` mentions in public chat. No app update required.

#### Q: How do I use MorpheusAI?
**A:** Simply type `@MorpheusAI` followed by your question in public chat. Example: "@MorpheusAI What is Bitcoin?"

#### Q: Are my conversations with MorpheusAI private?
**A: It depends on how you use it:**
- **Public (@mention)**: Questions via `@MorpheusAI` in public chat are visible to everyone
- **Private (DM with !ai)**: Questions via `!ai` in a DM to the bridge are end-to-end encrypted. Only you and the bridge operator can see them.

#### Q: Can multiple people talk to MorpheusAI at the same time?
**A: Yes.** The bridge handles multiple concurrent users. Each user's conversation context is tracked independently.

```
┌─────────────────────────────────────────────────────────────┐
│              MULTIPLE USERS SUPPORTED                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [Alice] ─── "@MorpheusAI hi" ──┐                           │
│                                 │                           │
│  [Bob] ──── "@MorpheusAI help" ─┼───▶ [Bot] ──▶ api.mor.org │
│                                 │                           │
│  [Carol] ── "@MorpheusAI ?" ────┘                           │
│                                                             │
│  Each user's context tracked independently                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Network & Connectivity

#### Q: Does my device need internet to use MorpheusAI?
**A: No.** Your device communicates with MorpheusAI over the Bluetooth mesh. Only the bridge device needs internet.

#### Q: How far can I be from the bridge and still reach MorpheusAI?
**A:** MorpheusAI is reachable via standard mesh routing, up to 7 hops away. This is the same as any peer in BitChat.

```
┌─────────────────────────────────────────────────────────────┐
│                    MESH ROUTING                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [You] ──▶ [Hop1] ──▶ [Hop2] ──▶ ... ──▶ [MorpheusAI]      │
│                                                             │
│  Maximum 7 hops (TTL), same as all BitChat messages         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### Q: What happens if the bridge device goes offline?
**A:** MorpheusAI will disappear from the `/who` list, just like any peer that leaves the network. Your conversation history remains on your device.

#### Q: Can there be multiple MorpheusAI bots in one mesh?
**A:** Each bridge creates one bot instance. If multiple bridges are active, users will see multiple bot peers (though typically named the same). Messages go to whichever bot you started a conversation with.

### Security & Privacy

#### Q: Are my conversations with MorpheusAI private?
**A: No.** MorpheusAI uses @mention detection in **public chat**. Your questions and the bot's answers are visible to all peers in the mesh network. This is a design tradeoff for backward compatibility.

#### Q: How can I have private AI conversations?
**A:** Send a DM to the bridge operator with the `!ai` prefix:
1. Find the bridge operator's nickname (e.g., `@BridgeNick`)
2. Send a private message: `/msg @BridgeNick !ai What is Bitcoin?`
3. The response comes back as an encrypted DM

This uses end-to-end encryption via Noise Protocol, so only you and the bridge can see the conversation.

#### Q: Can the bridge operator read my conversations?
**A: Yes.** Since conversations happen in public chat, everyone in the mesh (including the bridge operator) can see your questions and the AI's responses.

#### Q: Is my conversation history stored?
**A:**
- **On your device**: Yes, like any BitChat public message
- **On all mesh peers**: Public messages are visible to everyone connected
- **On Morpheus API**: Subject to Morpheus's privacy policy

### Bridge Operation

#### Q: How do I become a bridge operator?
**A:**
1. Install the updated BitChat with MorpheusAI support
2. **Get an API key:**
   - Visit [https://app.mor.org](https://app.mor.org)
   - Sign up for a Morpheus account
   - Navigate to API Keys section
   - Generate a new API key
   - Copy the key (starts with `sk-mor-` or similar)
3. Run `/ai-key YOUR_KEY` to configure
4. Run `/ai-bridge on` to start the bot

> **Note:** The Morpheus API key is required for the bridge to function. Without a valid key, the MorpheusAI bot will not activate. API usage may be subject to rate limits and costs depending on your Morpheus account tier.

#### Q: Does running a bridge drain my battery?
**A:** Yes, more than normal BitChat usage because:
- Constant internet connectivity
- Processing AI requests for other users
- Multiple concurrent Noise sessions

#### Q: Can I limit who can use my bridge?
**A:** Currently, anyone in the mesh can message the bot. Future versions may add:
- Whitelist/blacklist by fingerprint
- Rate limiting per user
- Usage quotas

---

## Technical Details

### Protocol Compatibility

| Component | Protocol Used | Backward Compatible? |
|-----------|--------------|---------------------|
| @Mention Detection | Standard public `MessageType.message` | ✅ Yes |
| Bot Responses | Standard public `MessageType.message` | ✅ Yes |
| Mesh Routing | Standard TTL-based routing | ✅ Yes |

### How @Mention Detection Works

The bridge detects `@MorpheusAI` mentions in public chat messages:

```
┌─────────────────────────────────────────────────────────────┐
│                  @MENTION DETECTION FLOW                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. User sends: "@MorpheusAI What is Bitcoin?"              │
│     → Standard public message via mesh                      │
│                                                             │
│  2. Bridge receives all public messages                     │
│     → Checks for "@MorpheusAI" pattern                      │
│     → If found: extracts query and sender info              │
│                                                             │
│  3. Bridge queries Morpheus API                             │
│     → POST /chat/completions with user's question           │
│                                                             │
│  4. Bridge posts response to public chat                    │
│     → "MorpheusAI: Bitcoin is a decentralized..."           │
│                                                             │
│  5. All peers see both question and answer                  │
│     → Full transparency, no private channels                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### API Integration

| Morpheus API Endpoint | Purpose |
|----------------------|---------|
| `POST /chat/completions` | Send user messages, receive AI responses |
| `GET /models` | List available AI models |

Default model: `glm-4.7:web`

---

## Limitations

| Limitation | Description | Workaround |
|------------|-------------|------------|
| Single bot per bridge | Each bridge device hosts one bot | Deploy multiple bridges |
| Bridge must stay online | Bot leaves when bridge disconnects | Use a dedicated device |
| No conversation memory across sessions | Bot doesn't remember previous chats | Include context in your messages |
| 7-hop maximum | Same as all BitChat messages | Position bridge centrally in mesh |

---

## API Key Setup (Bridge Operators)

### Getting Your Morpheus API Key

To operate a MorpheusAI bridge, you need an API key from the Morpheus network:

1. **Visit the Morpheus Portal**
   - Go to [https://app.mor.org](https://app.mor.org)

2. **Create an Account**
   - Sign up with your email or connect a Web3 wallet
   - Complete any verification steps required

3. **Generate API Key**
   - Navigate to the "API Keys" or "Developer" section
   - Click "Create New Key" or "Generate Key"
   - Give your key a descriptive name (e.g., "BitChat Bridge")
   - Copy the key immediately (it may only be shown once)

4. **Configure BitChat**
   ```
   /ai-key sk-mor-your-key-here
   ```

5. **Verify Setup**
   ```
   /ai-key
   ```
   Should show: "MorpheusAI API key: configured"

### API Key Security

| Do | Don't |
|----|-------|
| Store key in BitChat using `/ai-key` | Share your key with others |
| Use a dedicated key for BitChat | Post key in public channels |
| Rotate key if compromised | Use same key across many services |

### API Usage & Costs

- **Free Tier:** Morpheus may offer limited free usage
- **Rate Limits:** Requests may be throttled under heavy use
- **Costs:** Check [app.mor.org](https://app.mor.org) for current pricing

> **Tip:** Monitor your API usage in the Morpheus dashboard to avoid unexpected charges or rate limiting.

---

## Global Access

MorpheusAI is available worldwide with no country restrictions. Anyone can use the bot regardless of location.

---

## Troubleshooting

### "@MorpheusAI not responding"

| Possible Cause | Solution |
|---------------|----------|
| No bridge in your mesh | Find someone to run a bridge with `/ai-bridge on` |
| Bridge is offline | Wait for bridge to reconnect |
| Bridge has no API key | Bridge operator should run `/ai-key <key>` |
| Bot not activated | Bridge operator should run `/ai-bridge on` |


### "Slow responses from MorpheusAI"

| Possible Cause | Solution |
|---------------|----------|
| High mesh latency | Normal for multi-hop routes |
| API response time | Morpheus API processing time |
| Bridge overloaded | Too many concurrent users |

### "Private AI (!ai) not responding"

| Possible Cause | Solution |
|---------------|----------|
| Bot not activated | Bridge operator should run `/ai-bridge on` |
| Wrong syntax | Use `!ai <question>` (with space after !ai) |
| DM to wrong user | Make sure you're DMing the bridge operator, not another user |
| No Noise session | Try sending a regular DM first to establish encryption |

### "How do I know if a bridge is active?"

Currently, there's no direct way to know if a bridge is active. Try sending `@MorpheusAI hello` - if you get a response, a bridge is active in your mesh. Future versions may add a `/ai-status` command.

---

## Image Diagram Prompt

Use this prompt with nanobanana pro or similar AI image generators:

```
Create a technical diagram showing a decentralized mesh network architecture for an AI chat bot system. The image should include:

STYLE:
- Clean, modern technical illustration style
- Dark background (#1a1a2e) with bright accent colors
- Glowing connection lines between nodes
- Isometric or 2.5D perspective

ELEMENTS TO INCLUDE:

1. MESH NETWORK (left side):
   - 5-6 mobile phone icons representing "Standard BitChat Clients"
   - Connected by glowing blue lines representing Bluetooth mesh
   - Small lock icons on connections indicating encryption
   - Labels: "No Internet Required", "Bluetooth Mesh"

2. BRIDGE DEVICE (center):
   - Larger phone/tablet icon with a special glow
   - Split into two parts:
     a) Human icon labeled "User Identity"
     b) Robot/AI icon labeled "MorpheusAI Bot"
   - WiFi/internet signal icon above it
   - Label: "Bridge Device (Internet Connected)"

3. CLOUD/API (right side):
   - Cloud icon or server rack
   - "Morpheus AI Gateway" label
   - "api.mor.org" text
   - Brain or neural network icon inside

4. FLOW ARROWS:
   - Dotted lines from mesh clients to bridge (labeled "@MorpheusAI Mentions")
   - Solid line from bridge to cloud (labeled "HTTPS API Call")
   - Return arrows showing response flow (labeled "Public Chat Response")

5. INFO BOXES:
   - "@Mention Detection" badge
   - "Up to 7 Hops" indicator
   - "Public Chat Responses" indicator

6. COUNTRY FLAGS (small, in corner):
   - US, Bulgaria, Iran flags with "Available Regions" label

COLOR SCHEME:
- Blue (#4a9eff) for Bluetooth/mesh connections
- Green (#00ff88) for successful/encrypted status
- Purple (#9d4edd) for AI/bot elements
- Orange (#ff6b35) for internet/API connections
- White text on dark background

TEXT:
- Title: "MorpheusAI: Decentralized AI Chat over Bluetooth Mesh"
- Subtitle: "Backward-compatible integration with BitChat"

The overall composition should clearly show that offline devices can reach AI through the mesh network via a bridge device that detects @mentions in public chat. Emphasize the decentralized nature and backward compatibility with standard BitChat clients.
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.1 | 2026-01-29 | Added private AI via DM (`!ai` prefix), updated default model to glm-4.7:web, removed country restrictions |
| 1.0 | 2026-01-28 | Initial documentation |

---

## See Also

- [BitChat Whitepaper](../WHITEPAPER.md)
- [Morpheus API Documentation](https://apidocs.mor.org/)
- [Noise Protocol Framework](http://noiseprotocol.org/)
