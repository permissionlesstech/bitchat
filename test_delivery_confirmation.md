# Delivery Confirmation Test Plan

## Test Setup
1. Build and run the bitchat app on two devices (or two instances on one device)
2. Connect the devices and exchange nicknames

## Test Cases

### 1. Basic Delivery Confirmation
- Send a private message from Device A to Device B
- Expected: 
  - Device A shows single gray checkmark (sent)
  - When Device B receives, Device A shows double green checkmarks (delivered)
  - Message IDs should match in logs

### 2. Read Receipts
- Device B opens/views the chat with Device A
- Expected:
  - Device A shows double blue checkmarks (read)
  - Console logs show "Generating read receipt" and "Received READ receipt"

### 3. Timeout Handling
- Send a message to an offline peer
- Expected:
  - After 30 seconds, status changes to "Failed: Message not delivered"

### 4. Message ID Consistency
- Monitor console logs when sending messages
- Expected:
  - Message ID in "Tracking message" log matches ID in "Processing ACK" log
  - No UUID mismatches

## Debug Commands
```bash
# Filter delivery-related logs
log stream --predicate 'processImagePath contains "bitchat"' | grep -E "(DeliveryTracker|Delivery|ACK|receipt)"

# Check for message ID issues
log stream --predicate 'processImagePath contains "bitchat"' | grep -E "(Tracking message|Processing ACK|message ID)"
```

## Known Working Flow
1. Alice sends message to Bob (ID: abc123)
2. Bob receives message and generates ACK
3. Bob sends encrypted ACK back to Alice
4. Alice receives and processes ACK, updates UI to "delivered"
5. When Bob views chat, read receipt is sent
6. Alice receives read receipt, updates UI to blue checkmarks