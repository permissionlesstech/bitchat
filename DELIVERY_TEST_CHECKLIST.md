# Test Checklist for Delivery Confirmation

## Quick Test
1. **Rick sends to Jack** (while Jack is not in the chat)
   - ✓ Rick sees gray circle → gray check → green double checks
   
2. **Jack opens chat with Rick**
   - ✓ Jack should see Rick's message
   - ✓ Rick should see blue double checks (this is what we fixed!)

3. **Jack sends reply to Rick** (while Rick is viewing)
   - ✓ Jack sees gray circle → gray check → green double checks → blue double checks

## Debug Logs to Watch For

**On Jack's device when opening chat:**
```
[UI] Selected private chat peer changed to [peer-id]
[UI] Triggering markPrivateMessagesAsRead for peer [peer-id]
[Delivery] Checking N messages in chat with peer [peer-id] (rick) for read receipts
[Delivery] Message [id] from rick, senderPeerID: [old-id], currentPeerID: [new-id], myNickname: jack, status: Delivered to jack
[Delivery] Sending read receipt for message [id] from rick to current peer [peer-id]
[DeliveryTracker] Broadcasting read receipt packet to [peer-id]
```

**On Rick's device when receiving read receipt:**
```
[Delivery] Received READ receipt for message [id] from jack
[Delivery] Updating message [id] to status: read(by: "jack", at: [timestamp])
[UI] Showing BLUE checkmarks for read status by jack
```

## What to Check
- Messages sent before opening chat should turn blue when chat is opened
- Peer ID changes between sessions shouldn't break read receipts
- No race conditions - blue checkmarks should stay blue
- Read receipts work for both real-time and delayed chat opening